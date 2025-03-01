import std/[strutils, algorithm]
import chronos, chronos/apps, chronos/unittest2/asynctests, stew/byteutils,
       metrics
import helpers, ../presto/route, ../presto/segpath, ../presto/server

when defined(nimHasUsed): {.used.}

type
  ClientResponse = object
    status*: int
    data*: string
    headers*: HttpTable

proc cmpNoHeaders(a, b: ClientResponse): bool =
  (a.status == b.status) and (a.data == b.data)

proc cmpWithHeaders(a, b: ClientResponse): bool =
  if (a.status != b.status) or (a.data != b.data):
    return false
  for header in b.headers.items():
    if header.key notin a.headers:
      return false
    let checkItems = a.headers.getList(header.key).sorted()
    let expectItems = header.value.sorted()
    if checkItems != expectItems:
      return false
  true

proc cmpNoContent(a, b: ClientResponse): bool =
  if (a.status != b.status):
    return false
  for header in b.headers.items():
    if header.key notin a.headers:
      return false
    let checkItems = a.headers.getList(header.key).sorted()
    let expectItems = header.value.sorted()
    if checkItems != expectItems:
      return false
  true

proc init(t: typedesc[ClientResponse], status: int): ClientResponse =
  ClientResponse(status: status)

proc init(t: typedesc[ClientResponse], status: int,
          headers: openArray[tuple[key, value: string]]): ClientResponse =
  let table = HttpTable.init(headers)
  ClientResponse(status: status, headers: table)

proc init(t: typedesc[ClientResponse], status: int,
          data: string): ClientResponse =
  ClientResponse(status: status, data: data)

proc init(t: typedesc[ClientResponse], status: int, data: string,
          headers: HttpTable): ClientResponse =
  ClientResponse(status: status, data: data, headers: headers)

proc init(t: typedesc[ClientResponse], status: int, data: string,
          headers: openArray[tuple[key, value: string]]): ClientResponse =
  let table = HttpTable.init(headers)
  ClientResponse(status: status, data: data, headers: table)

proc httpClient(server: TransportAddress, meth: HttpMethod, url: string,
                body: string, ctype = "",
                accept = "", encoding = "",
                length = -1): Future[ClientResponse] {.async.} =
  var request = $meth & " " & $parseUri(url) & " HTTP/1.1\r\n"
  request.add("Host: " & $server & "\r\n")
  if len(encoding) == 0:
    if length >= 0:
      request.add("Content-Length: " & $length & "\r\n")
    else:
      request.add("Content-Length: " & $len(body) & "\r\n")
  if len(ctype) > 0:
    request.add("Content-Type: " & ctype & "\r\n")
  if len(accept) > 0:
    request.add("Accept: " & accept & "\r\n")
  if len(encoding) > 0:
    request.add("Transfer-Encoding: " & encoding & "\r\n")
  request.add("\r\n")

  if len(body) > 0:
    request.add(body)

  var headersBuf = newSeq[byte](4096)
  let transp = await connect(server)
  let wres {.used.} = await transp.write(request)
  let rlen = await transp.readUntil(addr headersBuf[0], len(headersBuf),
                                    HeadersMark)
  headersBuf.setLen(rlen)
  let resp = parseResponse(headersBuf, true)
  doAssert(resp.success())

  let headers =
    block:
      var res = HttpTable.init()
      for key, value in resp.headers(headersBuf):
        res.add(key, value)
      res

  let length = resp.contentLength()
  doAssert(length >= 0)
  let cresp =
    if length > 0:
      var dataBuf = newString(length)
      await transp.readExactly(addr dataBuf[0], len(dataBuf))
      ClientResponse.init(resp.code, dataBuf, headers)
    else:
      ClientResponse.init(resp.code, "", headers)
  await transp.closeWait()
  return cresp

template asyncTest*(name: string, body: untyped): untyped =
  test name:
    waitFor((
      proc() {.async, gcsafe.} =
        body
    )())

suite "REST API server test suite":
  let serverAddress = initTAddress("127.0.0.1:30180")
  asyncTest "Responses test":
    var router = RestRouter.init(testValidate)
    router.api(MethodGet, "/test/simple/1") do () -> RestApiResponse:
      discard

    router.api(MethodGet, "/test/simple/2") do () -> RestApiResponse:
      return RestApiResponse.response("ok-1")

    router.api(MethodGet, "/test/simple/3") do () -> RestApiResponse:
      return RestApiResponse.error(Http505, "Some error", "text/error")

    router.api(MethodGet, "/test/simple/4") do () -> RestApiResponse:
      if true:
        raise newException(ValueError, "Some exception")

    var sres = RestServerRef.new(router, serverAddress)
    let server = sres.get()
    server.start()
    try:
      # Handler returned empty response.
      let res1 = await httpClient(serverAddress, MethodGet, "/test/simple/1",
                                  "")
      # Handler returned good response.
      let res2 = await httpClient(serverAddress, MethodGet, "/test/simple/2",
                                  "")
      # Handler returned via RestApiResponse.
      let res3 = await httpClient(serverAddress, MethodGet, "/test/simple/3",
                                  "")
      # Exception generated by handler.
      let res4 = await httpClient(serverAddress, MethodGet, "/test/simple/4",
                                  "")
      # Missing handler response
      let res5 = await httpClient(serverAddress, MethodGet, "/test/simple/5",
                                  "")
      # URI with more than 64 segments response
      let res6 = await httpClient(serverAddress, MethodGet,
                                  "//////////////////////////////////////////" &
                                  "//////////////////////////test", "")
      check:
        cmpNoHeaders(res1, ClientResponse.init(410))
        cmpNoHeaders(res2, ClientResponse.init(200, "ok-1"))
        cmpNoHeaders(res3, ClientResponse.init(505, "Some error"))
        cmpNoHeaders(res4, ClientResponse.init(503))
        cmpNoHeaders(res5, ClientResponse.init(404))
        cmpNoHeaders(res6, ClientResponse.init(400))
    finally:
      await server.closeWait()

  asyncTest "Requests [path] arguments test":
    var router = RestRouter.init(testValidate)
    router.api(MethodGet, "/test/{smp1}") do (
        smp1: int) -> RestApiResponse:
      if smp1.isErr():
        return RestApiResponse.error(Http411, $smp1.error())
      return RestApiResponse.response($smp1.get())

    router.api(MethodGet, "/test/{smp1}/{smp2}") do (
        smp1: int, smp2: string) -> RestApiResponse:
      if smp1.isErr():
        return RestApiResponse.error(Http411, $smp1.error())
      if smp2.isErr():
        return RestApiResponse.error(Http412, $smp2.error())
      return RestApiResponse.response($smp1.get() & ":" &
                                         smp2.get())

    router.api(MethodGet, "/test/{smp1}/{smp2}/{smp3}") do (
        smp1: int, smp2: string, smp3: seq[byte]) -> RestApiResponse:
      if smp1.isErr():
        return RestApiResponse.error(Http411, $smp1.error())
      if smp2.isErr():
        return RestApiResponse.error(Http412, $smp2.error())
      if smp3.isErr():
        return RestApiResponse.error(Http413, $smp3.error())
      return RestApiResponse.response($smp1.get() & ":" & smp2.get() & ":" &
                                      toHex(smp3.get()))

    const TestVectors = [
      ("/test/1234", ClientResponse.init(200, "1234")),
      ("/test/12345678", ClientResponse.init(200, "12345678")),
      ("/test/00000001", ClientResponse.init(200, "1")),
      ("/test/0000000", ClientResponse.init(200, "0")),
      ("/test/99999999999999999999999", ClientResponse.init(411)),
      ("/test/nondec", ClientResponse.init(404)),

      ("/test/1234/text1", ClientResponse.init(200, "1234:text1")),
      ("/test/12345678/texttext2",
       ClientResponse.init(200, "12345678:texttext2")),
      ("/test/00000001/texttexttext3",
       ClientResponse.init(200, "1:texttexttext3")),
      ("/test/0000000/texttexttexttext4",
       ClientResponse.init(200, "0:texttexttexttext4")),
      ("/test/nondec/texttexttexttexttext5", ClientResponse.init(404)),
      ("/test/99999999999999999999999/texttexttexttexttext5",
       ClientResponse.init(411)),

      ("/test/1234/text1/0xCAFE",
       ClientResponse.init(200, "1234:text1:cafe")),
      ("/test/12345678/text2text2/0xdeadbeaf",
       ClientResponse.init(200, "12345678:text2text2:deadbeaf")),
      ("/test/00000001/text3text3text3/0xabcdef012345",
       ClientResponse.init(200, "1:text3text3text3:abcdef012345")),
      ("/test/00000000/text4text4text4text4/0xaa",
       ClientResponse.init(200, "0:text4text4text4text4:aa")),
      ("/test/nondec/text5/0xbb", ClientResponse.init(404)),
      ("/test/99999999999999999999999/text6/0xcc", ClientResponse.init(411)),
      ("/test/1234/text7/0xxx", ClientResponse.init(413))
    ]

    var sres = RestServerRef.new(router, serverAddress)
    let server = sres.get()
    server.start()
    try:
      for item in TestVectors:
        let res = await httpClient(serverAddress, MethodGet,
                                   item[0], "")
        check res.status == item[1].status
        if len(item[1].data) > 0:
          check res.data == item[1].data
    finally:
      await server.closeWait()

  asyncTest "Requests [path + query] arguments test":
    var router = RestRouter.init(testValidate)
    router.api(MethodGet, "/test/{smp1}/{smp2}/{smp3}") do (
        smp1: int, smp2: string, smp3: seq[byte],
        opt1: Option[int], opt2: Option[string], opt3: Option[seq[byte]],
        opt4: seq[int], opt5: seq[string],
        opt6: seq[seq[byte]]) -> RestApiResponse:

      if smp1.isErr():
        return RestApiResponse.error(Http411, $smp1.error())
      if smp2.isErr():
        return RestApiResponse.error(Http412, $smp2.error())
      if smp3.isErr():
        return RestApiResponse.error(Http413, $smp3.error())

      let o1 =
        if opt1.isSome():
          let res = opt1.get()
          if res.isErr():
            return RestApiResponse.error(Http414, $res.error())
          $res.get()
        else:
          ""
      let o2 =
        if opt2.isSome():
          let res = opt2.get()
          if res.isErr():
            return RestApiResponse.error(Http415, $res.error())
          res.get()
        else:
          ""
      let o3 =
        if opt3.isSome():
          let res = opt3.get()
          if res.isErr():
            return RestApiResponse.error(Http416, $res.error())
          toHex(res.get())
        else:
          ""
      let o4 =
        if opt4.isErr():
          return RestApiResponse.error(Http417, $opt4.error())
        else:
          opt4.get().join(",")
      let o5 =
        if opt5.isErr():
          return RestApiResponse.error(Http418, $opt5.error())
        else:
          opt5.get().join(",")
      let o6 =
        if opt6.isErr():
          return RestApiResponse.error(Http421, $opt6.error())
        else:
          let binres = opt6.get()
          var res = newSeq[string]()
          for item in binres:
            res.add(toHex(item))
          res.join(",")

      let body = $smp1.get() & ":" & smp2.get() & ":" & toHex(smp3.get()) &
                 ":" & o1 & ":" & o2 & ":" & o3 &
                 ":" & o4 & ":" & o5 & ":" & o6
      return RestApiResponse.response(body)

    const TestVectors = [
      ("/test/1/2/0xaa?opt1=1&opt2=2&opt3=0xbb&opt4=2&opt4=3&opt4=4&opt5=t&" &
        "opt5=e&opt5=s&opt5=t&opt6=0xCA&opt6=0xFE",
        ClientResponse.init(200, "1:2:aa:1:2:bb:2,3,4:t,e,s,t:ca,fe")),
      # Optional argument will not pass decoding procedure `opt1=a`.
      ("/test/1/2/0xaa?opt1=a&opt2=2&opt3=0xbb&opt4=2&opt4=3&opt4=4&opt5=t&" &
        "opt5=e&opt5=s&opt5=t&opt6=0xCA&opt6=0xFE",
        ClientResponse.init(414)),
      # Sequence argument will not pass decoding procedure `opt4=a`.
      ("/test/1/2/0xaa?opt1=1&opt2=2&opt3=0xbb&opt4=2&opt4=3&opt4=a&opt5=t&" &
        "opt5=e&opt5=s&opt5=t&opt6=0xCA&opt6=0xFE",
        ClientResponse.init(417)),
      # Optional argument will not pass decoding procedure `opt3=0xxx`.
      ("/test/1/2/0xaa?opt1=1&opt2=2&opt3=0xxx&opt4=2&opt4=3&opt4=4&opt5=t&" &
        "opt5=e&opt5=s&opt5=t&opt6=0xCA&opt6=0xFE",
        ClientResponse.init(416)),
      # Sequence argument will not pass decoding procedure `opt6=0xxx`.
      ("/test/1/2/0xaa?opt1=1&opt2=2&opt3=0xbb&opt4=2&opt4=3&opt4=5&opt5=t&" &
        "opt5=e&opt5=s&opt5=t&opt6=0xCA&opt6=0xxx",
        ClientResponse.init(421)),
      # All optional arguments are missing
      ("/test/1/2/0xaa", ClientResponse.init(200, "1:2:aa::::::"))
    ]

    var sres = RestServerRef.new(router, serverAddress)
    let server = sres.get()
    server.start()
    try:
      for item in TestVectors:
        let res = await httpClient(serverAddress, MethodGet,
                                   item[0], "")
        check res.status == item[1].status
        if len(item[1].data) > 0:
          check res.data == item[1].data
    finally:
      await server.closeWait()

  asyncTest "Requests [path + query + request body] test":
    var router = RestRouter.init(testValidate)
    router.api(MethodPost, "/test/{smp1}/{smp2}/{smp3}") do (
        smp1: int, smp2: string, smp3: seq[byte],
        opt1: Option[int], opt2: Option[string], opt3: Option[seq[byte]],
        opt4: seq[int], opt5: seq[string],
        opt6: seq[seq[byte]],
        contentBody: Option[ContentBody]) -> RestApiResponse:

      if smp1.isErr():
        return RestApiResponse.error(Http411, $smp1.error())
      if smp2.isErr():
        return RestApiResponse.error(Http412, $smp2.error())
      if smp3.isErr():
        return RestApiResponse.error(Http413, $smp3.error())

      let o1 =
        if opt1.isSome():
          let res = opt1.get()
          if res.isErr():
            return RestApiResponse.error(Http414, $res.error())
          $res.get()
        else:
          ""
      let o2 =
        if opt2.isSome():
          let res = opt2.get()
          if res.isErr():
            return RestApiResponse.error(Http415, $res.error())
          res.get()
        else:
          ""
      let o3 =
        if opt3.isSome():
          let res = opt3.get()
          if res.isErr():
            return RestApiResponse.error(Http416, $res.error())
          toHex(res.get())
        else:
          ""
      let o4 =
        if opt4.isErr():
          return RestApiResponse.error(Http417, $opt4.error())
        else:
          opt4.get().join(",")
      let o5 =
        if opt5.isErr():
          return RestApiResponse.error(Http418, $opt5.error())
        else:
          opt5.get().join(",")
      let o6 =
        if opt6.isErr():
          return RestApiResponse.error(Http421, $opt6.error())
        else:
          let binres = opt6.get()
          var res = newSeq[string]()
          for item in binres:
            res.add(toHex(item))
          res.join(",")

      let obody =
        if contentBody.isSome():
          let body = contentBody.get()
          $body.contentType & "," & bytesToString(body.data)
        else:
          "nobody"

      let body = $smp1.get() & ":" & smp2.get() & ":" & toHex(smp3.get()) &
                 ":" & o1 & ":" & o2 & ":" & o3 &
                 ":" & o4 & ":" & o5 & ":" & o6 &
                 ":" & obody

      return RestApiResponse.response(body)

    const PostVectors = [
      (
        ("/test/1/2/0xaa", "text/plain", "textbody"),
        ClientResponse.init(200, "1:2:aa:::::::text/plain,textbody")
      ),
      (
        ("/test/1/2/0xaa", "", ""),
        ClientResponse.init(200)
      ),
      (
        ("/test/1/2/0xaa", "text/plain", ""),
        ClientResponse.init(200, "1:2:aa:::::::nobody")
      ),
      (
        ("/test/1/2/0xaa?opt1=1&opt2=2&opt3=0xbb&opt4=2&opt4=3&opt4=4&opt5=t&" &
         "opt5=e&opt5=s&opt5=t&opt6=0xCA&opt6=0xFE", "text/plain", "textbody"),
        ClientResponse.init(200,
                        "1:2:aa:1:2:bb:2,3,4:t,e,s,t:ca,fe:text/plain,textbody")
      )
    ]

    var sres = RestServerRef.new(router, serverAddress)
    let server = sres.get()
    server.start()
    try:
      for item in PostVectors:
        let req = item[0]
        let res = await httpClient(serverAddress, MethodPost,
                                   req[0], req[2], req[1])
        check res.status == item[1].status
        if len(item[1].data) > 0:
          check res.data == item[1].data

      block:
        let res = await httpClient(serverAddress, MethodPost,
                                   url = "/test/1/2/0xaa",
                                   body = "4\r\nWiki\r\n5\r\npedia\r\nE\r\n " &
                                     "in\r\n\r\nchunks.\r\n0\r\n\r\n",
                                   ctype = "application/octet-stream",
                                   accept = "*/*",
                                   encoding = "chunked")
        check:
          res.status == 200
          res.data == "1:2:aa:::::::application/octet-stream,Wikipedia " &
                      "in\r\n\r\nchunks."
    finally:
      await server.closeWait()

  asyncTest "Direct response manipulation test":
    var router = RestRouter.init(testValidate)
    router.api(MethodGet, "/test/{smp1}") do (
      smp1: int, opt1: Option[int], opt4: seq[int],
      resp: HttpResponseRef) -> RestApiResponse:

      if smp1.isErr():
        return RestApiResponse.error(Http411, $smp1.error())

      let o1 =
        if opt1.isSome():
          let res = opt1.get()
          if res.isErr():
            return RestApiResponse.error(Http414, $res.error())
          $res.get()
        else:
          ""
      let o4 =
        if opt4.isErr():
          return RestApiResponse.error(Http417, $opt4.error())
        else:
          opt4.get().join(",")

      let path = smp1.get()
      let restResp = $smp1.get() & ":" & o1 & ":" & o4
      case path
      of 1:
        await resp.sendBody(restResp)
      of 2:
        await resp.sendBody(restResp)
        return RestApiResponse.response("")
      of 3:
        await resp.sendBody(restResp)
        return RestApiResponse.error(Http422, "error")
      else:
        return RestApiResponse.error(Http426, "error")

    router.api(MethodPost, "/test/{smp1}") do (
      smp1: int, opt1: Option[int], opt4: seq[int],
      body: Option[ContentBody],
      resp: HttpResponseRef) -> RestApiResponse:

      if smp1.isErr():
        return RestApiResponse.error(Http411, $smp1.error())
      let o1 =
        if opt1.isSome():
          let res = opt1.get()
          if res.isErr():
            return RestApiResponse.error(Http414, $res.error())
          $res.get()
        else:
          ""
      let o4 =
        if opt4.isErr():
          return RestApiResponse.error(Http417, $opt4.error())
        else:
          opt4.get().join(",")

      let obody =
        if body.isSome():
          let b = body.get()
          $b.contentType & "," & bytesToString(b.data)
        else:
          "nobody"

      let path = smp1.get()
      let restResp = $smp1.get() & ":" & o1 & ":" & o4 & ":" & obody

      case path
      of 1:
        await resp.sendBody(restResp)
      of 2:
        await resp.sendBody(restResp)
        return RestApiResponse.response("some result")
      of 3:
        await resp.sendBody(restResp)
        return RestApiResponse.error(Http422, "error")
      else:
        return RestApiResponse.error(Http426, "error")

    const PostVectors = [
      (
        # Empty result with response sent via `resp`.
        ("/test/1?opt1=2345&opt4=3456&opt4=4567&opt4=5678&opt4=6789",
         "text/plain", "somebody"),
         ClientResponse.init(200,
                             "1:2345:3456,4567,5678,6789:text/plain,somebody")
      ),
      (
        # Result with response sent via `resp`.
        ("/test/2?opt1=2345&opt4=3456&opt4=4567&opt4=5678&opt4=6789",
         "text/plain", "somebody"),
        ClientResponse.init(200,
                            "2:2345:3456,4567,5678,6789:text/plain,somebody")
      ),
      (
        # Error with response sent via `resp`.
        ("/test/3?opt1=2345&opt4=3456&opt4=4567&opt4=5678&opt4=6789",
         "text/plain", "somebody"),
         ClientResponse.init(200,
                             "3:2345:3456,4567,5678,6789:text/plain,somebody")
      )
    ]

    const GetVectors = [
      (
        # Empty result with response sent via `resp`.
        "/test/1?opt1=2345&opt4=3456&opt4=4567&opt4=5678&opt4=6789",
        ClientResponse.init(200, "1:2345:3456,4567,5678,6789")
      ),
      (
        # Result with response sent via `resp`.
        "/test/2?opt1=2345&opt4=3456&opt4=4567&opt4=5678&opt4=6789",
        ClientResponse.init(200, "2:2345:3456,4567,5678,6789")
      ),
      (
        # Error with response sent via `resp`.
        "/test/3?opt1=2345&opt4=3456&opt4=4567&opt4=5678&opt4=6789",
        ClientResponse.init(200, "3:2345:3456,4567,5678,6789")
      )
    ]

    var sres = RestServerRef.new(router, serverAddress)
    let server = sres.get()
    server.start()
    try:
      for item in GetVectors:
        let res = await httpClient(serverAddress, MethodGet, item[0], "")
        check res.status == item[1].status
        if len(item[1].data) > 0:
          check res.data == item[1].data

      for item in PostVectors:
        let req = item[0]
        let res = await httpClient(serverAddress, MethodPost,
                                   req[0], req[2], req[1])
        check res.status == item[1].status
        if len(item[1].data) > 0:
          check res.data == item[1].data

    finally:
      await server.closeWait()

  asyncTest "Responses with headers test":
    var router = RestRouter.init(testValidate)

    router.api(MethodGet, "/test/get/success") do (
      param: Option[string]) -> RestApiResponse:
      let test = param.get().get()
      case test
      of "test1":
        let headers = [
          ("test-header", "SUCCESS"), ("test-header", "TEST"),
          ("test-header", "1")
        ]
        return RestApiResponse.response("TEST1:OK", Http200, headers = headers)
      of "test2":
        let headers = HttpTable.init([
          ("test-header", "SUCCESS"), ("test-header", "TEST"),
          ("test-header", "2")
        ])
        return RestApiResponse.response("TEST2:OK", Http200, headers = headers)
      of "test3":
        let headers = HttpTable.init([
          ("test-header", "SUCCESS"), ("test-header", "TEST"),
          ("test-header", "3"), ("content-type", "application/success")
        ])
        return RestApiResponse.response("TEST3:OK", Http200,
                                        contentType = "text/success",
                                        headers = headers)
      else:
        return RestApiResponse.error(Http400)

    router.api(MethodGet, "/test/get/error") do (
      param: Option[string]) -> RestApiResponse:
      let testName = param.get().get()
      case testName
      of "test1":
        let headers = [
          ("test-header", "ERROR"), ("test-header", "TEST"),
          ("test-header", "1")
        ]
        return RestApiResponse.error(Http404, "ERROR1:OK", headers = headers)
      of "test2":
        let headers = HttpTable.init([
          ("test-header", "ERROR"), ("test-header", "TEST"),
          ("test-header", "2")
        ])
        return RestApiResponse.error(Http404, "ERROR2:OK", headers = headers)
      of "test3":
        let headers = HttpTable.init([
          ("test-header", "ERROR"), ("test-header", "TEST"),
          ("test-header", "3"), ("content-type", "application/error")
        ])
        return RestApiResponse.error(Http404, "ERROR3:OK",
                                     contentType = "text/error",
                                     headers = headers)
      else:
        return RestApiResponse.error(Http400)

    router.api(MethodGet, "/test/get/redirect") do (
      param: Option[string]) -> RestApiResponse:
      let testName = param.get().get()
      case testName
      of "test1":
        let headers = [
          ("test-header", "REDIRECT"), ("test-header", "TEST"),
          ("test-header", "1")
        ]
        return RestApiResponse.redirect(Http307, "/test/get/redirect1",
                                        preserveQuery = true, headers = headers)
      of "test2":
        let headers = HttpTable.init([
          ("test-header", "REDIRECT"), ("test-header", "TEST"),
          ("test-header", "2")
        ])
        return RestApiResponse.redirect(Http307, "/test/get/redirect2",
                                        preserveQuery = false,
                                        headers = headers)
      of "test3":
        let headers = HttpTable.init([
          ("test-header", "REDIRECT"), ("test-header", "TEST"),
          ("test-header", "3"), ("location", "/test/get/wrong_redirect")
        ])
        return RestApiResponse.redirect(Http307, "/test/get/redirect3",
                                        preserveQuery = true,
                                        headers = headers)
      else:
        return RestApiResponse.error(Http400)

    const HttpHeadersVectors = [
      ("/test/get/success?param=test1",
       ClientResponse.init(200, "TEST1:OK",
         [("test-header", "SUCCESS"), ("test-header", "TEST"),
          ("test-header", "1")])),
      ("/test/get/success?param=test2",
       ClientResponse.init(200, "TEST2:OK",
         [("test-header", "SUCCESS"), ("test-header", "TEST"),
          ("test-header", "2")])),
      ("/test/get/success?param=test3",
       ClientResponse.init(200, "TEST3:OK",
         [("test-header", "SUCCESS"), ("test-header", "TEST"),
          ("test-header", "3"), ("content-type", "text/success")])),

      ("/test/get/error?param=test1",
       ClientResponse.init(404, "ERROR1:OK",
         [("test-header", "ERROR"), ("test-header", "TEST"),
          ("test-header", "1")])),
      ("/test/get/error?param=test2",
       ClientResponse.init(404, "ERROR2:OK",
         [("test-header", "ERROR"), ("test-header", "TEST"),
          ("test-header", "2")])),
      ("/test/get/error?param=test3",
       ClientResponse.init(404, "ERROR3:OK",
         [("test-header", "ERROR"), ("test-header", "TEST"),
          ("test-header", "3"), ("content-type", "text/error")])),

      ("/test/get/redirect?param=test1",
       ClientResponse.init(307, "",
         [("test-header", "REDIRECT"), ("test-header", "TEST"),
          ("test-header", "1"),
          ("location", "/test/get/redirect1?param=test1")])),
      ("/test/get/redirect?param=test2",
       ClientResponse.init(307, "",
         [("test-header", "REDIRECT"), ("test-header", "TEST"),
          ("test-header", "2"),
          ("location", "/test/get/redirect2")])),
      ("/test/get/redirect?param=test3",
       ClientResponse.init(307, "",
         [("test-header", "REDIRECT"), ("test-header", "TEST"),
          ("test-header", "3"),
          ("location", "/test/get/redirect3?param=test3")])),
    ]
    var sres = RestServerRef.new(router, serverAddress)
    let server = sres.get()
    server.start()
    try:
      for item in HttpHeadersVectors:
        let res = await httpClient(serverAddress, MethodGet, item[0], "")
        check cmpWithHeaders(res, item[1])
    finally:
      await server.closeWait()

  asyncTest "Responses without content test":
    var router = RestRouter.init(testValidate)

    router.api(MethodGet, "/test/get/nocontent") do (
      param: Option[string]) -> RestApiResponse:
      let testName = param.get().get()
      case testName
      of "test1":
        return RestApiResponse.response()
      of "test2":
        let headers = HttpTable.init([("test-header", "NORESPONSE2"),
                                      ("test-header", "2")])
        return RestApiResponse.response(Http202, headers)
      of "test3":
        let headers = [("test-header", "NORESPONSE3"),
                       ("test-header", "3")]
        return RestApiResponse.response(Http203, headers)
      else:
        return RestApiResponse.error(Http400)

    router.api(MethodPost, "/test/post/nocontent") do (
      param: Option[string]) -> RestApiResponse:
      let testName = param.get().get()
      case testName
      of "test1":
        return RestApiResponse.response()
      of "test2":
        let headers = HttpTable.init([("test-header", "NORESPONSE2"),
                                      ("test-header", "2")])
        return RestApiResponse.response(Http202, headers)
      of "test3":
        let headers = [("test-header", "NORESPONSE3"),
                       ("test-header", "3")]
        return RestApiResponse.response(Http203, headers)
      else:
        return RestApiResponse.error(Http400)

    const HttpGetHeadersVectors = [
      ("/test/get/nocontent?param=test1",
       ClientResponse.init(200, [])),
      ("/test/get/nocontent?param=test2",
       ClientResponse.init(202,
         [("test-header", "NORESPONSE2"), ("test-header", "2")])),
      ("/test/get/nocontent?param=test3",
       ClientResponse.init(203,
         [("test-header", "NORESPONSE3"), ("test-header", "3")]))
    ]

    const HttpPostHeadersVectors = [
      ("/test/post/nocontent?param=test1",
       ClientResponse.init(200, [])),
      ("/test/post/nocontent?param=test2",
       ClientResponse.init(202,
         [("test-header", "NORESPONSE2"), ("test-header", "2")])),
      ("/test/post/nocontent?param=test3",
       ClientResponse.init(203,
         [("test-header", "NORESPONSE3"), ("test-header", "3")]))
    ]

    var sres = RestServerRef.new(router, serverAddress)
    let server = sres.get()
    server.start()
    try:
      for item in HttpGetHeadersVectors:
        let res = await httpClient(serverAddress, MethodGet, item[0], "")
        check:
          cmpNoContent(res, item[1])
          len(res.data) == 0
          res.headers.getString("content-type") == ""
      for item in HttpPostHeadersVectors:
        let res = await httpClient(serverAddress, MethodPost, item[0], "")
        check:
          cmpNoContent(res, item[1])
          len(res.data) == 0
          res.headers.getString("content-type") == ""
    finally:
      await server.closeWait()

  asyncTest "preferredContentType() test":
    const PostVectors = [
      (
        ("/test/post", "somebody0908", "text/html",
        "app/type1;q=0.9,app/type2;q=0.8"),
        ClientResponse.init(200, "type1[text/html,somebody0908]")
      ),
      (
        ("/test/post", "somebody0908", "text/html",
        "app/type2;q=0.8,app/type1;q=0.9"),
        ClientResponse.init(200, "type1[text/html,somebody0908]")
      ),
      (
        ("/test/post", "somebody09", "text/html",
         "app/type2,app/type1;q=0.9"),
        ClientResponse.init(200, "type2[text/html,somebody09]")
      ),
      (
        ("/test/post", "somebody09", "text/html", "app/type1;q=0.9,app/type2"),
        ClientResponse.init(200, "type2[text/html,somebody09]")
      ),
      (
        ("/test/post", "somebody", "text/html", "*/*"),
        ClientResponse.init(200, "type1[text/html,somebody]")
      ),
      (
        ("/test/post", "somebody", "text/html", ""),
        ClientResponse.init(200, "type1[text/html,somebody]")
      ),
      (
        ("/test/post", "somebody", "text/html", "app/type2"),
        ClientResponse.init(200, "type2[text/html,somebody]")
      ),
      (
        ("/test/post", "somebody", "text/html", "app/type3"),
        ClientResponse.init(406, "")
      )
    ]
    var router = RestRouter.init(testValidate)
    router.api(MethodPost, "/test/post") do (
      body: Option[ContentBody],
      resp: HttpResponseRef) -> RestApiResponse:
      let obody =
        if body.isSome():
          let b = body.get()
          $b.contentType & "," & bytesToString(b.data)
        else:
          "nobody"

      let preferred = preferredContentType(testMediaType1, testMediaType2)
      return
        if preferred.isOk():
          if preferred.get() == testMediaType1:
            RestApiResponse.response("type1[" & obody & "]")
          elif preferred.get() == testMediaType2:
            RestApiResponse.response("type2[" & obody & "]")
          else:
            # This MUST not be happened.
            RestApiResponse.error(Http407, "")
        else:
          RestApiResponse.error(Http406, "")

    var sres = RestServerRef.new(router, serverAddress)
    let server = sres.get()
    server.start()
    try:
      for item in PostVectors:
        let res = await httpClient(serverAddress, MethodPost, item[0][0],
                                   item[0][1], item[0][2], item[0][3])
        check:
          res.status == item[1].status
          res.data == item[1].data
    finally:
      await server.closeWait()

  asyncTest "Handle raw requests inside api handler test":
    var router = RestRouter.init(testValidate)
    router.rawApi(MethodPost, "/test/post") do () -> RestApiResponse:
      let contentType = request.headers.getString(ContentTypeHeader)
      let body = await request.getBody()
      return
        RestApiResponse.response(
          "type[" & contentType & ":" & body.toHex() & "]")

    var sres = RestServerRef.new(router, serverAddress)
    let server = sres.get()
    server.start()
    try:
      let res = await httpClient(serverAddress, MethodPost, "/test/post",
                                 "0123456789", "application/octet-stream")
      check:
        res.status == 200
        res.data == "type[application/octet-stream:30313233343536373839]"
    finally:
      await server.closeWait()

  asyncTest "API endpoints with metrics enabled test":
    var router = RestRouter.init(testValidate)
    router.metricsApi(MethodGet, "/test/get/1", {}) do () -> RestApiResponse:
      return RestApiResponse.response("ok-1", Http200, "test/test")
    router.metricsApi(MethodGet, "/test/get/2",
                      {RestServerMetricsType.Status}) do () -> RestApiResponse:
      return RestApiResponse.response("ok-2", Http200, "test/test")
    router.metricsApi(MethodGet, "/test/get/3",
                      {Response}) do () -> RestApiResponse:
      return RestApiResponse.response("ok-3", Http200, "test/test")
    router.metricsApi(MethodGet, "/test/get/4",
                      {RestServerMetricsType.Status,
                       Response}) do () -> RestApiResponse:
      return RestApiResponse.response("ok-4", Http200, "test/test")
    router.metricsApi(MethodGet, "/test/get/5",
                      RestServerMetrics) do () -> RestApiResponse:
      return RestApiResponse.response("ok-5", Http200, "test/test")
    router.rawMetricsApi(MethodGet, "/test/get/6", {}) do () -> RestApiResponse:
      return RestApiResponse.response("ok-6", Http200, "test/test")
    router.rawMetricsApi(MethodGet, "/test/get/7",
                       {RestServerMetricsType.Status}) do () -> RestApiResponse:
      return RestApiResponse.response("ok-7", Http200, "test/test")
    router.rawMetricsApi(MethodGet, "/test/get/8",
                         {Response}) do () -> RestApiResponse:
      return RestApiResponse.response("ok-8", Http200, "test/test")
    router.rawMetricsApi(MethodGet, "/test/get/9",
                         {RestServerMetricsType.Status,
                          Response}) do () -> RestApiResponse:
      return RestApiResponse.response("ok-9", Http200, "test/test")
    router.rawMetricsApi(MethodGet, "/test/get/10",
                         RestServerMetrics) do () -> RestApiResponse:
      return RestApiResponse.response("ok-10", Http200, "test/test")

  asyncTest "Custom error handlers test":
    const
      InvalidRequest = "////////////////////////////////////////////////////////////////////test"

    var router = RestRouter.init(testValidate)
    router.api(MethodGet, "/test") do () -> RestApiResponse:
      return RestApiResponse.response("test", Http200)
    router.api(MethodPost, "/post") do () -> RestApiResponse:
      return RestApiResponse.response("post", Http200)

    proc processError(
      kind: RestRequestError,
      request: HttpRequestRef
    ): Future[HttpResponseRef] {.async.} =
      case kind
      of RestRequestError.Invalid:
        return await request.respond(Http201, "INVALID", HttpTable.init())
      of RestRequestError.NotFound:
        return await request.respond(Http202, "NOT FOUND", HttpTable.init())
      of RestRequestError.InvalidContentBody:
        # This type of error is tough to emulate for test, its only possible
        # with chunked encoding with incorrect encoding headers.
        return await request.respond(Http203, "CONTENT BODY", HttpTable.init())
      of RestRequestError.InvalidContentType:
        return await request.respond(Http204, "CONTENT TYPE", HttpTable.init())
      of RestRequestError.Unexpected:
        # This type of error should not be happened at all
        return defaultResponse()

    var sres = RestServerRef.new(router, serverAddress,
                                 requestErrorHandler = processError)
    let server = sres.get()
    server.start()
    let address = server.server.instance.localAddress()

    block:
      let res = await httpClient(address, MethodGet, InvalidRequest, "")
      check:
        res.status == 201
        res.data == "INVALID"
    block:
      let res1 = await httpClient(address, MethodPost, "/test", "")
      let res2 = await httpClient(address, MethodGet, "/tes", "")
      check:
        res1.status == 202
        res2.status == 202
        res1.data == "NOT FOUND"
        res2.data == "NOT FOUND"
    block:
      # Invalid content body
      let res = await httpClient(address, MethodPost, "/post", "z\r\n1",
                                 ctype = "application/octet-stream",
                                 encoding = "chunked")
      check:
        res.status == 203
        res.data == "CONTENT BODY"
    block:
      # Missing `Content-Type` header for requests which has body.
      let res = await httpClient(address, MethodPost, "/post", "data")
      check:
        res.status == 204
        res.data == "CONTENT TYPE"

    await server.stop()
    await server.closeWait()

  asyncTest "Server error types test":
    var router = RestRouter.init(testValidate)
    router.api(MethodGet, "/test") do () -> RestApiResponse:
      return RestApiResponse.response("test", Http200)

    block:
      let sres = RestServerRef.new(router, initTAddress("127.0.0.1:0"))
      check sres.isOk()
      let server = sres.get()
      server.start()
      await server.stop()
      await server.closeWait()

    block:
      let sres = RestServerRef.new(router, initTAddress("127.0.0.1:0"),
                                   errorType = cstring)
      check sres.isOk()
      let server = sres.get()
      server.start()
      await server.stop()
      await server.closeWait()

    block:
      let sres = RestServerRef.new(router, initTAddress("127.0.0.1:0"),
                                   errorType = string)
      check sres.isOk()
      let server = sres.get()
      server.start()
      await server.stop()
      await server.closeWait()

  test "Leaks test":
    checkLeaks()

#
#         REST API framework implementation
#             (c) Copyright 2021-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import std/options
import chronos, chronos/apps/http/httpserver
import chronicles
import common
export chronicles, options

chronicles.formatIt(HttpTable):
  var res = newSeq[string]()
  for k, v in it.stringItems():
    let item = "(" & k & ", " & v & ")"
    res.add(item)
  "[" & res.join(", ") & "]"

chronicles.formatIt(Option[ContentBody]):
  if it.isSome():
    let body = it.get()
    "(" & $body.contentType & ", " & $len(body.data) & " bytes)"
  else:
    "(None)"

chronicles.expandIt(RestApiError):
  error_status = $it.status
  error_content_type = it.contentType
  error_message = it.message

type
  RestServerState* {.pure.} = enum
    Closed, Stopped, Running

  RestRequestError* {.pure.} = enum
    Invalid, NotFound, InvalidContentBody, InvalidContentType, Unexpected

  RestRequestErrorHandler* = proc(
    error: RestRequestError,
    request: HttpRequestRef): Future[HttpResponseRef] {.async.}

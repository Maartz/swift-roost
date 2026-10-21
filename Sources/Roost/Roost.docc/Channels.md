# Channels

Exchange messages with browsers over a WebSocket, as Phoenix channels do.

## Overview

A ``Channel`` handles the topics that match a pattern, such as every
`room:` topic. Clients join a topic, push events to it, and receive the
events that the server broadcasts to it:

```swift
struct RoomChannel: Channel {
    func join(topic: String, payload: ChannelPayload, socket: ChannelSocket) async throws -> ChannelPayload {
        guard socket.assigns["userID"] != nil else { throw ChannelError.unauthorized("sign in first") }
        return [:]
    }

    func handle(event: String, payload: ChannelPayload, socket: ChannelSocket) async throws {
        if event == "new_msg" {
            try await socket.broadcast(event: "new_msg", payload: ["body": payload["body"] ?? ""])
        }
    }

    func leave(topic: String, payload: ChannelPayload, socket: ChannelSocket) async {}
}
```

Route topics to channels from ``RoostApp/channels``:

```swift
var channels: ChannelRouter {
    ChannelRouter {
        on("room:*", RoomChannel.self)
    }
}
```

A channel keeps no state between calls: Roost creates one for each join,
event, and leave. Each payload travels as JSON, so its values are strings,
numbers, booleans, `nil` optionals, and arrays or dictionaries of them. A
broadcast or push of any other value throws `EncodingError`.

## Connect from the browser

Roost speaks the protocol of Phoenix's JavaScript client, so the `phoenix`
package from npm connects to it unchanged:

```js
import { Socket } from "phoenix"

const socket = new Socket("/socket", { params: { token: window.userToken } })
socket.connect()

const room = socket.channel("room:lobby")
room.on("new_msg", ({ body }) => console.log(body))
room.join().receive("ok", () => room.push("new_msg", { body: "Hello" }))
```

The socket is at ``ChannelRouter/path``, `/socket` by default, and its
WebSocket at that path followed by `/websocket`. The server upgrades these
requests before routing, so they need no route.

An upgrade request runs the app's ``RoostApp/plugs`` and loads its session, as
other requests do before the router. Then ``RoostApp/authenticateSocket(_:)``
returns the assigns that every channel of the socket reads from
``ChannelSocket/assigns``. The client's `params` arrive as query parameters:

```swift
func authenticateSocket(_ conn: Connection) async throws -> SocketAssigns {
    guard let userID = conn.sessionValue("user_id") else { throw ChannelError.unauthorized("sign in first") }
    return ["userID": userID]
}
```

A socket that `authenticateSocket(_:)` or a plug refuses gets a 400 response,
and phoenix.js tries again later. So does a socket from a page on another site:
when the browser names the page's origin, its host must be the one the request
was sent to.

## Replies

Every message the client sends gets a reply. A join replies with the payload
``Channel/join(topic:payload:socket:)`` returns. A pushed event replies once
``Channel/handle(event:payload:socket:)`` returns, without a payload. A
``ChannelError/unauthorized(_:)`` error replies `error` with its reason, which
phoenix.js passes to `receive("error", …)`. Other errors reply `error` with the
reason `internal error`, and are logged.

When a client leaves a topic, or its socket closes, Roost calls
``Channel/leave(topic:payload:socket:)``.

## Deploy

A server with channels serves HTTPS over HTTP/1.1 only: a WebSocket upgrades an
HTTP/1.1 connection. A reverse proxy must pass the `Upgrade` and `Connection`
headers on, and the original `Host`, which the origin check compares.

When the app stops, the server closes each socket, and phoenix.js reconnects to
a server that's still running. Each server keeps its own sockets, so a
broadcast reaches the clients of the server that sends it.

## Test channels

`TestApp.connectSocket(_:)` joins topics and pushes events in process, without a
WebSocket. Its sockets carry the assigns passed to `TestApp`, instead of calling
``RoostApp/authenticateSocket(_:)``.

## Topics

- ``Channel``
- ``ChannelRouter``
- ``ChannelSocket``
- ``ChannelError``
- ``ChannelRegistry``
- ``Presence``

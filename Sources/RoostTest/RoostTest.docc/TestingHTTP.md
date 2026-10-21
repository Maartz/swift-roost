# Testing HTTP requests

Send requests through an application and inspect its finalized responses.

## Overview

Add the `RoostTest` product to the test target. Generated application manifests
already include it.

### Test a response

This test assumes the `HelloApp` from Roost's getting-started guide:

```swift
import Testing
import RoostTest
@testable import HelloApp

@Test func greetingResponds() async throws {
    let app = try await TestApp(HelloApp.self, database: .some(nil))
    let response = try await app.get("/hello/Ada")
    #expect(response.status == .ok)
    #expect(response.json["hello"] as? String == "Ada")
    await app.shutdown()
}
```

The `database` argument has three states: omit it to use the app's configuration,
pass `.some(nil)` to disable the database, or supply another configuration.
The harness applies the test environment through a task-local override.

### Send a body

``TestApp`` supplies JSON `post` and `put` methods, URL-encoded form submission,
and a general `request` method for a specific method, body, and headers:

```swift
let response = try await app.post(
    "/api/bookmarks",
    json: ["title": "Swift guide", "url": "https://www.swift.org"]
)
```

This is a request-construction example, not an authentication bypass. Protected
routes still need valid credentials, and cookie-authenticated mutations still
need CSRF tokens. Use <doc:BrowserWorkflows> for the complete browser sequence.

### Inspect the result

| Response API | Use |
| --- | --- |
| `status` | Assert the HTTP status. |
| `text` | Read a UTF-8 response body. |
| `json` | Read a JSON dictionary; invalid or non-object JSON yields an empty dictionary. |
| `decode(as:)` | Decode a specific `Decodable` type; decoding failures throw. |
| `header(_:)` | Inspect one response header. |
| `cookies` | Inspect cookie names and values from `Set-Cookie` fields. |

Cookies in a single ``TestResponse`` are not a browser jar.
``TestBrowser`` retains cookies across requests.

### Close owned resources

If an application or test step can throw after opening a client, close the
harness on both paths:

```swift
let app = try await TestApp(ReadingRoom.self)
do {
    let response = try await app.get("/health")
    #expect(response.status == .ok)
    await app.shutdown()
} catch {
    await app.shutdown()
    throw error
}
```

An injected repository is caller-owned. Calling `shutdown()` does not close it.

### Keep the test boundary clear

The harness builds the real Roost request pipeline, including session
finalization and response hooks, but skips listener startup. It does not
execute browser JavaScript or validate socket upgrades over the network.

`connectSocket` creates an in-process channel socket; it does not open a
WebSocket or call `authenticateSocket(_:)`. `collectSSE` subscribes before running its action and
can collect a bounded number of events with a timeout. Network transport needs
separate acceptance checks.

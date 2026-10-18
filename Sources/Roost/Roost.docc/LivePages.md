# Live pages

Render HTML on the server, then update it through ESW's SSE stream and POST events.

## Define a page and its route

A ``LivePage`` is an ESW `Interactive` page whose mount and event methods receive
the current ``Nexus/Connection``. The connection contains the same authenticated
scope and repository as a controller, including repositories injected by tests.

```swift
import Roost

struct Counter: LivePage {
    func mount(_ conn: Connection, context: LiveContext) async throws -> Int { 0 }

    func handleEvent(_ event: LiveEvent, state: Int, conn: Connection) async throws -> Int {
        guard event.name == "increment" else { throw LiveError.invalidEvent }
        return state + 1
    }

    func render(_ count: Int) -> ESWLiveRender {
        #live("<button esw-click=\"increment\">Count: {count}</button>")
    }
}

@main
struct CounterApp: RoostApp {
    static let counter = LiveRoute(Counter(), path: "/_live/counter")
    let sessionStore: (any SessionStore)? = MemorySessionStore()
    var services: [any Service] { [Self.counter] }
    var plugs: [Plug] { browserPlugs() }

    @RouteBuilder var routes: [Route] {
        GET("/") { conn in try await Self.counter.render(conn, title: "Counter") }
        Self.counter.routes
    }
}
```

Keep the route instance stable. `render` applies the application's normal layout,
creates a session-owned instance, and serves the ESW client from local bundled
assets. `routes` supplies the asset, stream, and event endpoints under `path`.
Give each route a distinct root-relative path and include its transport routes
at the router's top level. Ordinary ESW `Interactive` views also work when
they don't need a connection.

Include each live route in ``RoostApp/services``. These services stop before the
HTTP server drains connections, closing open streams and pending live sessions.
A standalone adapter or test can call `await live.shutdown()` explicitly; a
closed route cannot be restarted. `TestApp` does not run application services.

## Reuse domain actions

In the reading-list example, the event handler calls
`try await conn.bookmarks().setRead(id: id, read: read)`, exactly like the ordinary
POST controller. It then reloads the list and renders its new state. The reader
scope still constrains the database update; a browser-supplied ID grants no
access by itself.

`LiveRoute`'s `authorize` closure runs for the initial page and every stream/event
request. Use it to require the appropriate authenticated scope. Handlers should
also apply domain authorization when they perform writes. The connection passed
to a handler belongs to that event's request, including after it waits behind
another event. Store page data in `State`; don't retain a connection, transaction,
or request-scoped repository in that state.

Mount runs for initial HTTP rendering and once more for the first connected
stream. `context.isConnected` distinguishes these calls. Keep mount read-only;
use event handlers for mutations. Pass selected route/query parameters explicitly
with `LiveContext(parameters: ...)`. Reconnection to an existing instance reuses
its state and sends a complete snapshot, without calling mount again.

Session changes, redirects, and response headers belong in ordinary controller
responses. Live handlers return new page state, not a modified connection.

## Templates and browser behavior

A `.live.hesw` template returns `ESWLiveRender`. It supports typed views,
components, and keyed lists:

```html
<li :for={bookmark in bookmarks} :key={bookmark.id} id={"bookmark-\(bookmark.id)"}>
    {bookmark.title}
</li>
```

Use both a stable `:key` for render diffs and a stable HTML `id` for DOM identity.
`<.form>` and field components receive Roost's rendering context during mount and
all event renders. For native form fallback, give the form a normal action and
add `attributes={["esw-submit": "save"]}`. ESW intercepts it when connected;
without JavaScript it submits through the normal controller. Include any IDs the
handler needs as hidden fields. `esw-click`, `esw-value-*`, and `esw-change` are
also available; live file uploads and live navigation are not implemented.

The client exposes `data-esw-state` and `aria-busy` on the live root. Listen on
that root for `esw:status`, `esw:update`, and `esw:error` to present loading,
reconnection, and failure states. These events don't bubble. The example keeps
an error visible through a reconnect and clears it after a successful event.

## Sessions, failures, and deployment

A real Roost session store is required. Instances belong to a random owner token
in that session, bound additionally to its authentication token. Event endpoints
validate CSRF themselves, even if outer middleware skips JSON validation. Other
sessions cannot subscribe or send events to an instance. Responses are private
and not cacheable.

Call `await live.invalidate(conn)` **before** login, logout, or session identity
changes. This closes existing streams and cancels pending work. For several live
routes, invalidate each one. Revoking a database permission should similarly
invalidate affected owners when open views must close immediately; middleware
is not rerun for every update on an already-open stream.

ESW serializes events and remembers up to 128 admitted outcomes per instance.
A lost response is retried with the same ID and gets the original result. This
protection lasts only within that live instance; it is not durable idempotency
for external effects. Use domain transactions and idempotency where necessary.
Application errors are returned as a generic `eventFailed` code, never exception
text. Invalid events do not run handlers. Expired or removed streams return 204,
which stops EventSource; the UI should offer a reload.

State and retry history are **process-local**, with a default fixed lifetime of
one hour and capacity of 1,000 instances per route. They don't survive a server
restart. A multi-process deployment needs affinity for live requests; putting
ordinary sessions in Valkey does not distribute live state. This integration
uses ESW's protocol, with bounded queues and heartbeat writes, and does not
implement Phoenix wire compatibility or cross-tab data synchronization.

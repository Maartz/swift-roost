import Foundation
import NexusTest
import Testing
@testable import Roost

@Suite("Live routes")
struct LiveRouteTests {
    private actor Calls {
        var requests: [String] = []
        func record(_ value: String) { requests.append(value) }
    }

    private struct Page: LivePage {
        let calls: Calls
        var pause: Pause? = nil
        struct State: Sendable { var count = 0; var request = "" }
        func mount(_ conn: Connection, context: LiveContext) async throws -> State {
            await calls.record(context.isConnected ? "connected" : "initial")
            return State(request: conn.getReqHeader("X-Probe") ?? "mount")
        }
        func handleEvent(_ event: LiveEvent, state: State, conn: Connection) async throws -> State {
            let probe = conn.getReqHeader("X-Probe") ?? "event"
            await calls.record(probe)
            if event.name == "hold" { await pause?.wait() }
            if event.name == "fail" { throw NexusHTTPError(.unprocessableContent, message: "secret diagnostic") }
            // Suspension exercises inheritance across ESW's queued task.
            await Task.yield()
            var next = state
            next.count += 1
            next.request = probe
            return next
        }
        func render(_ state: State) -> ESWLiveRender {
            #live(#"<p>{state.count}: {state.request}</p><.form action="/save"><button>Save</button></.form>"#)
        }
    }

    private actor Pause {
        let entered = AsyncStream<Void>.makeStream()
        private var release: CheckedContinuation<Void, Never>?
        func wait() async {
            await withCheckedContinuation { continuation in
                release = continuation
                entered.continuation.yield(())
            }
        }
        func resume() { release?.resume(); release = nil }
    }

    private func request(_ path: String = "/", method: HTTPRequest.Method = .get,
                         session: [String: String]? = [:], headers: [String: String] = [:], body: Data? = nil) -> Connection {
        var fields = HTTPFields()
        for (name, value) in headers { fields[HTTPField.Name(name)!] = value }
        return TestConnection.build(method: method, path: path, body: body.map { .buffered($0) } ?? .empty, headers: fields)
            .assign(RoostSessionKey.self, value: MemorySessionStore())
            .assign(key: Connection.sessionKey, value: session ?? [:])
    }

    private func text(_ conn: Connection) -> String {
        guard case .buffered(let data) = conn.responseBody else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func instance(_ conn: Connection) throws -> String {
        String(try #require(text(conn).firstMatch(of: #/data-esw-id="([^"]+)"/#)).output.1)
    }

    @Test func pageStreamEventsRetryAndReconnectUseTheCurrentRequest() async throws {
        let calls = Calls()
        let live = LiveRoute(Page(calls: calls))
        let router = Router { live.routes }
        let page = try await live.render(request().assign(HTMLLayoutKey.self, value: { _, title, html in
            "<title>\(title)</title>" + html
        }), title: "Queue")
        let id = try instance(page)
        #expect(text(page).contains("<title>Queue</title>"))
        #expect(text(page).contains("name=\"_csrf_token\" value=\"\(page.csrfToken)\""))
        #expect(page.response.headerFields[.cacheControl] == "private, no-store")
        let stream = try await router(request("/_live/\(id)/stream", session: page.session, headers: ["X-Probe": "stream"]))
        #expect(stream.response.status == .ok)
        #expect(stream.response.headerFields[.contentType]?.hasPrefix("text/event-stream") == true)
        guard case .producer = stream.responseBody else { Issue.record("Expected backpressured producer"); return }
        let event = LiveEvent(id: "once", name: "increment", baseRevision: 1)
        let post = request("/_live/\(id)/event", method: .post, session: page.session,
                           headers: ["Content-Type": "application/json", "X-CSRF-Token": page.csrfToken, "X-Probe": "fresh-event"],
                           body: try JSONEncoder().encode(event))
        let result = try await router(post)
        #expect(result.response.status == .ok)
        #expect(text(result).contains("fresh-event"))
        #expect(text(result).contains("\"revision\":2"))
        let retry = try await router(post)
        let original = try JSONDecoder().decode(LiveUpdate.self, from: Data(text(result).utf8))
        let repeated = try JSONDecoder().decode(LiveUpdate.self, from: Data(text(retry).utf8))
        #expect(repeated.revision == original.revision && repeated.eventID == original.eventID)
        #expect(repeated.render == original.render)
        let reconnected = try await router(request("/_live/\(id)/stream", session: page.session))
        #expect(reconnected.response.status == .ok)
        #expect(await calls.requests == ["initial", "connected", "fresh-event"])
        let stale = LiveEvent(id: "stale", name: "increment", baseRevision: 1)
        let rejected = try await router(request("/_live/\(id)/event", method: .post, session: page.session,
            headers: ["Content-Type": "application/json", "X-CSRF-Token": page.csrfToken], body: try JSONEncoder().encode(stale)))
        #expect(rejected.response.status == .conflict)
        await live.shutdown()
    }

    @Test func ownershipAuthorizationAndCSRFAreCheckedWithoutBrowserMiddleware() async throws {
        let calls = Calls()
        let live = LiveRoute(Page(calls: calls)) { conn in
            guard conn.getSession("allowed") == "yes" else { throw LiveError.unauthorized }
        }
        let router = Router { live.routes }
        let page = try await live.render(request(session: ["allowed": "yes", "_roost_auth_token": "alice"]))
        let id = try instance(page)
        let event = try JSONEncoder().encode(LiveEvent(name: "increment", baseRevision: 1))
        let other = try await live.render(request(session: ["allowed": "yes"]))
        let foreign = try await router(request("/_live/\(id)/stream", session: other.session))
        #expect(foreign.response.status == .forbidden)
        var changed = page.session ?? [:]
        changed["_roost_auth_token"] = "bob"
        #expect(try await router(request("/_live/\(id)/stream", session: changed)).response.status == .forbidden)
        changed = page.session ?? [:]
        changed["allowed"] = "no"
        #expect(try await router(request("/_live/\(id)/stream", session: changed)).response.status == .forbidden)
        #expect(try await router(request("/_live/\(id)/stream", session: page.session,
            headers: ["Sec-Fetch-Site": "cross-site"])).response.status == .forbidden)
        #expect(try await router(request("/_live/\(id)/event", method: .post, session: page.session,
            headers: ["Content-Type": "application/json"], body: event)).response.status == .forbidden)
        #expect(await calls.requests == ["initial", "initial"])
        await live.shutdown()
    }

    @Test func invalidationClosesTheStreamAndPreventsFurtherEvents() async throws {
        let live = LiveRoute(Page(calls: Calls()))
        let router = Router { live.routes }
        let page = try await live.render(request())
        let id = try instance(page)
        let stream = try await router(request("/_live/\(id)/stream", session: page.session))
        await live.invalidate(page)
        #expect(await live.host.count == 0)
        #expect(try await router(request("/_live/\(id)/stream", session: page.session)).response.status == .noContent)
        if case .producer(let produce) = stream.responseBody {
            var writer: any ResponseBodyWriter = RecordingWriter()
            try await produce(&writer) // Must finish, not wait for a heartbeat.
        } else { Issue.record("Expected stream producer") }
        await live.shutdown()
    }

    private struct RecordingWriter: ResponseBodyWriter {
        mutating func write(_ data: Data) async throws {}
    }

    private struct ForwardingWriter: ResponseBodyWriter {
        let packets: AsyncStream<String>.Continuation
        mutating func write(_ data: Data) async throws { packets.yield(String(decoding: data, as: UTF8.self)) }
    }

    private final class RoomRoute: @unchecked Sendable {
        var live: LiveRoute<Room>?
    }

    private struct Room: LivePage {
        enum Info: Sendable, Codable { case said(String) }
        var route = RoomRoute()
        func mount(_ conn: Connection, context: LiveContext) async throws -> [String] { [] }
        func handleEvent(_ event: LiveEvent, state: [String], conn: Connection) async throws -> [String] {
            if event.name == "say", let text = event.value("text") { route.live?.broadcast(.said(text), to: "room:lobby") }
            return state
        }
        func topics(_ conn: Connection, context: LiveContext) throws -> [String] {
            ["room:\(context.parameters["room"] ?? "")"]
        }
        func handleInfo(_ info: Info, state: [String], conn: Connection) async throws -> [String] {
            guard case .said(let text) = info else { return state }
            return state + ["\(text) via \(conn.getReqHeader("X-Probe") ?? "no request")"]
        }
        func render(_ state: [String]) -> ESWLiveRender {
            #live("<p>{state.joined(separator: \", \")}</p>")
        }
    }

    /// Renders a lobby page and opens its stream, past the initial snapshot.
    private func lobby(_ live: LiveRoute<Room>, probe: String) async throws
        -> (page: Connection, packets: AsyncStream<String>.Iterator, streaming: Task<Void, any Error>) {
        let page = try await live.render(request(), context: LiveContext(parameters: ["room": "lobby"]))
        let stream = try await Router { live.routes }(request("/_live/\(try instance(page))/stream",
                                                              session: page.session, headers: ["X-Probe": probe]))
        guard case .producer(let produce) = stream.responseBody else { throw LiveError.notConnected }
        let (packets, continuation) = AsyncStream<String>.makeStream()
        let streaming = Task {
            var writer: any ResponseBodyWriter = ForwardingWriter(packets: continuation)
            try await produce(&writer)
        }
        var received = packets.makeAsyncIterator()
        _ = await received.next() // The snapshot: the page now listens.
        return (page, received, streaming)
    }

    private func next(_ packets: inout AsyncStream<String>.Iterator, containing text: String) async -> String {
        var packet = ""
        while !packet.contains(text), let next = await packets.next() { packet = next }
        return packet
    }

    @Test(.timeLimit(.minutes(1)))
    func broadcastsUpdateOpenPagesOnTheTopicWithTheirStreamRequest() async throws {
        let live = LiveRoute(Room())
        var (_, packets, streaming) = try await lobby(live, probe: "stream")

        live.broadcast(.said("ignored"), to: "room:kitchen")
        live.broadcast(.said("hello"), to: "room:lobby")
        let update = await next(&packets, containing: "hello")
        #expect(update.contains("hello via stream"))
        #expect(!update.contains("ignored"))

        await live.shutdown()
        try await streaming.value
    }

    @Test(.timeLimit(.minutes(1)))
    func pubSubCarriesBroadcastsToThePagesOfAnotherServer() async throws {
        let pubSub = PubSub.inMemory()
        let first = LiveRoute(Room(), pubSub: pubSub)
        let second = LiveRoute(Room(), pubSub: pubSub)
        var (_, packets, streaming) = try await lobby(second, probe: "second server")

        first.broadcast(.said("hello"), to: "room:lobby")
        #expect(await next(&packets, containing: "hello").contains("hello via second server"))

        await first.shutdown()
        await second.shutdown()
        try await streaming.value
    }

    #if Valkey
    @Test(.timeLimit(.minutes(1)), .enabled(if: StoreBackend.valkeyURL != nil))
    func valkeyCarriesBroadcastsToThePagesOfAnotherServer() async throws {
        guard let url = StoreBackend.valkeyURL else { return }
        let channel = "roost-test:\(UUID().uuidString)"
        let servers = [PubSub.valkey(url: url, channel: channel), PubSub.valkey(url: url, channel: channel)]
        let first = LiveRoute(Room(), pubSub: servers[0])
        let second = LiveRoute(Room(), pubSub: servers[1])
        try await withThrowingTaskGroup(of: Void.self) { group in
            for server in servers { group.addTask { try await server.run() } }
            defer { group.cancelAll() }
            var (_, packets, streaming) = try await lobby(second, probe: "second server")
            // Broadcasts until the second server has subscribed.
            let broadcasting = Task {
                while !Task.isCancelled {
                    first.broadcast(.said("hello"), to: "room:lobby")
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            defer { broadcasting.cancel() }
            #expect(await next(&packets, containing: "hello").contains("hello via second server"))
            await first.shutdown()
            await second.shutdown()
            try await streaming.value
        }
    }
    #endif

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func aPageThatBroadcastsDoesNotReceiveItsOwnMessage(throughPubSub: Bool) async throws {
        let room = Room()
        let live = throughPubSub ? LiveRoute(room, pubSub: PubSub.inMemory()) : LiveRoute(room)
        room.route.live = live
        var speaker = try await lobby(live, probe: "speaker")
        var listener = try await lobby(live, probe: "listener")

        let said = try await Router { live.routes }(request("/_live/\(try instance(speaker.page))/event", method: .post,
            session: speaker.page.session,
            headers: ["Content-Type": "application/json", "X-CSRF-Token": speaker.page.csrfToken],
            body: try JSONEncoder().encode(LiveEvent(name: "say", values: ["text": ["hi"]], baseRevision: 1))))
        #expect(said.response.status == .ok)
        #expect(await next(&listener.packets, containing: "hi").contains("hi via listener"))
        live.broadcast(.said("done"), to: "room:lobby")
        #expect(!(await next(&speaker.packets, containing: "done")).contains("hi"))

        await live.shutdown()
        try await speaker.streaming.value
        try await listener.streaming.value
    }

    @Test func browsersCannotSendServerMessages() async throws {
        let live = LiveRoute(Room())
        let router = Router { live.routes }
        let page = try await live.render(request())
        let id = try instance(page)
        _ = try await router(request("/_live/\(id)/stream", session: page.session))
        let forged = try await router(request("/_live/\(id)/event", method: .post, session: page.session,
            headers: ["Content-Type": "application/json", "X-CSRF-Token": page.csrfToken],
            body: try JSONEncoder().encode(LiveEvent(name: LiveRequest.infoEvent, baseRevision: 1))))
        #expect(forged.response.status == .unprocessableContent)
        await live.shutdown()
    }

    @Test func malformedEventsAndFailuresDoNotExposeDiagnostics() async throws {
        let live = LiveRoute(Page(calls: Calls()))
        let router = Router { live.routes }
        let page = try await live.render(request())
        let id = try instance(page)
        _ = try await router(request("/_live/\(id)/stream", session: page.session))
        for (mime, data) in [
            ("application/json-extra", try JSONEncoder().encode(LiveEvent(name: "increment", baseRevision: 1))),
            ("application/json", try JSONEncoder().encode(LiveEvent(name: "increment"))),
            ("application/json", Data(repeating: 32, count: 65_537)),
        ] {
            let result = try await router(request("/_live/\(id)/event", method: .post, session: page.session,
                headers: ["Content-Type": mime, "X-CSRF-Token": page.csrfToken], body: data))
            #expect(result.response.status == .unprocessableContent)
        }
        let failure = try await router(request("/_live/\(id)/event", method: .post, session: page.session,
            headers: ["Content-Type": "application/json", "X-CSRF-Token": page.csrfToken],
            body: try JSONEncoder().encode(LiveEvent(name: "fail", baseRevision: 1))))
        #expect(failure.response.status == .unprocessableContent)
        #expect(!text(failure).contains("secret diagnostic"))
        #expect(text(failure).contains("eventFailed"))
        await live.shutdown()
    }

    @Test func missingSessionFailsAndAssetsAreWhitelisted() async throws {
        let live = LiveRoute(Page(calls: Calls()))
        await #expect(throws: LiveError.self) { try await live.render(TestConnection.build()) }
        let router = Router { live.routes }
        let js = try await router(TestConnection.build(path: "/_live/assets/esw-live.js"))
        #expect(js.response.status == .ok && text(js).contains("LiveClient"))
        #expect(try await router(TestConnection.build(path: "/_live/assets/unknown.js")).response.status == .notFound)
        await live.shutdown()
    }

    @Test func serviceCancellationClosesHosts() async throws {
        let live = LiveRoute(Page(calls: Calls()))
        _ = try await live.render(request())
        let running = Task { try await live.run() }
        running.cancel()
        _ = try? await running.value
        #expect(await live.host.count == 0)
        await #expect(throws: LiveError.self) { try await live.render(request()) }
    }
    @Test func queuedEventsKeepSeparateRequestContexts() async throws {
        let calls = Calls()
        let pause = Pause()
        let live = LiveRoute(Page(calls: calls, pause: pause))
        let router = Router { live.routes }
        let page = try await live.render(request())
        let id = try instance(page)
        _ = try await router(request("/_live/\(id)/stream", session: page.session))
        let first = request("/_live/\(id)/event", method: .post, session: page.session,
            headers: ["Content-Type": "application/json", "X-CSRF-Token": page.csrfToken, "X-Probe": "first"],
            body: try JSONEncoder().encode(LiveEvent(name: "hold", baseRevision: 1)))
        let second = request("/_live/\(id)/event", method: .post, session: page.session,
            headers: ["Content-Type": "application/json", "X-CSRF-Token": page.csrfToken, "X-Probe": "second"],
            body: try JSONEncoder().encode(LiveEvent(name: "increment", baseRevision: 2)))
        let firstTask = Task { try await router(first) }
        var entered = pause.entered.stream.makeAsyncIterator()
        _ = await entered.next()
        let secondTask = Task { try await router(second) }
        await Task.yield()
        await pause.resume()
        let firstResult = try await firstTask.value
        let secondResult = try await secondTask.value
        #expect(firstResult.response.status == .ok && secondResult.response.status == .ok)
        #expect(text(firstResult).contains("first") && text(secondResult).contains("second"))
        #expect(await calls.requests == ["initial", "connected", "first", "second"])
        await live.shutdown()
    }

    @Test func invalidInitialRenderingDoesNotConsumeCapacity() async throws {
        struct InvalidPage: Interactive {
            func mount(_ context: LiveContext) async throws -> Int { 0 }
            func handleEvent(_ event: LiveEvent, state: Int) async throws -> Int { state }
            func render(_ state: Int) -> ESWLiveRender {
                #live(#"<.form action="javascript:alert(1)"><button>Save</button></.form>"#)
            }
        }
        let live = LiveRoute(InvalidPage(), capacity: 1)
        for _ in 0..<2 {
            await #expect(throws: ViewRenderingError.self) { try await live.render(request()) }
            #expect(await live.host.count == 0)
        }
        await live.shutdown()
    }

}

import ESWLive
import Foundation
import Logging
import Nexus
import NexusRouter
import ServiceLifecycle

/// One stable live endpoint. Include `routes` in the router and this value in
/// `RoostApp.services`. Render its initial page from a normal GET/controller.
/// `authorize` runs on the page and every stream/event request.
public struct LiveRoute<View: Interactive>: Sendable, Service {
    let host: LiveHost<View>
    public let path: String
    private let view: View
    private let lifetime: Duration
    private let listeners = LiveListeners()
    /// Publishes a broadcast through the PubSub the route was created with.
    private let relay: (@Sendable (_ info: any Sendable, _ topic: String, _ sender: String?) async throws -> Void)?
    private let authorize: @Sendable (Connection) async throws -> Void
    private static var ownerKey: String { "_roost_live_owner" }

    public init(_ view: View, path: String = "/_live", capacity: Int = 1_000,
                lifetime: Duration = .seconds(3_600),
                authorize: @escaping @Sendable (Connection) async throws -> Void = { _ in }) {
        self.init(view, path: path, capacity: capacity, lifetime: lifetime, relay: nil, authorize: authorize)
    }

    private init(_ view: View, path: String, capacity: Int, lifetime: Duration,
                 relay: (@Sendable (any Sendable, String, String?) async throws -> Void)?,
                 authorize: @escaping @Sendable (Connection) async throws -> Void) {
        precondition(path.hasPrefix("/") && !path.hasPrefix("//") && !path.hasSuffix("/")
            && !path.contains(where: { $0.isWhitespace || "?#\\:%".contains($0) }))
        self.host = LiveHost(view, capacity: capacity, lifetime: lifetime)
        self.path = path
        self.view = view
        self.lifetime = lifetime
        self.relay = relay
        self.authorize = authorize
    }

    public func render(_ connection: Connection, title: String = "", context: LiveContext = .init()) async throws -> Connection {
        try await authorize(connection)
        guard connection[RoostSessionKey.self] != nil else { throw LiveError.unauthorized }
        var conn = try await roost_csrfProtection()(connection)
        guard !conn.isHalted else { throw LiveError.unauthorized }
        if conn.getSession(Self.ownerKey) == nil {
            conn = conn.putSession(key: Self.ownerKey, value: Auth.generateToken())
        }
        let owner = try owner(conn)
        var mounted: LiveMount?
        do {
            let mount = try await LiveRequest.withConnection(conn) {
                let value = try await host.mount(owner: owner, context: context)
                mounted = value
                return value
            }
            if let page = view as? any LivePage {
                listeners.register(mount.id, topics: try page.topics(conn, context: context), lifetime: lifetime)
            }
            let fragment = """
            <div id="esw-live-\(mount.id)" data-esw-live data-esw-id="\(mount.id)" data-esw-state="connecting" data-esw-stream="\(ESW.escape(path))/\(mount.id)/stream" data-esw-event="\(ESW.escape(path))/\(mount.id)/event" data-esw-csrf="\(ESW.escape(conn.csrfToken))">\(mount.render.html)</div>
            <script type="module" src="\(ESW.escape(path))/assets/esw-live.js"></script>
            """
            return try conn.render(LiveHTML(html: fragment), title: title).putRespHeader(.cacheControl, "private, no-store")
        } catch {
            if let mounted { try? await host.remove(mounted.id, owner: owner) }
            throw error
        }
    }

    @RouteBuilder public var routes: [Route] {
        GET("\(path)/assets/:name") { conn in
            guard let name = conn.params["name"], let source = LiveAssets.javascript(named: name) else {
                return conn.respond(status: .notFound, body: .empty)
            }
            return conn.respond(status: .ok, body: .string(source))
                .putRespHeader(.contentType, "text/javascript; charset=utf-8")
                .putRespHeader(.cacheControl, "no-cache")
        }
        GET("\(path)/:id/stream") { conn in
            do {
                try await authorize(conn)
                try checkFetchOrigin(conn)
                let prepared = try await roost_csrfProtection()(conn)
                let id = conn.params["id"] ?? ""
                let updates = try await LiveRequest.withConnection(prepared) {
                    try await host.subscribe(id, owner: owner(prepared))
                }
                return prepared.sseEvent { writer in
                    // Broadcasts reach the page through this request while it streams.
                    let listening = listeners.open(id, conn: prepared)
                    defer { if let listening { listeners.close(id, token: listening) } }
                    let packets = livePackets(updates)
                    defer { packets.cancel() }
                    for await packet in packets.stream { try await writer.write(packet) }
                }.putRespHeader(.cacheControl, "private, no-store, no-transform")
            } catch LiveError.notFound, LiveError.closed {
                return conn.respond(status: .noContent, body: .empty).putRespHeader(.cacheControl, "no-store")
            } catch { return failure(error, conn: conn) }
        }
        POST("\(path)/:id/event") { conn in
            do {
                try await authorize(conn)
                try checkFetchOrigin(conn)
                // Enforce CSRF even when the application's browser middleware opts out of JSON.
                let checked = try await roost_csrfProtection()(conn)
                guard !checked.isHalted else { throw LiveError.unauthorized }
                guard conn.getReqHeader(.contentType)?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json",
                      case .buffered(let data) = conn.requestBody, data.count <= 65_536,
                      let event = try? JSONDecoder().decode(LiveEvent.self, from: data),
                      let revision = event.baseRevision, revision >= 0 else { throw LiveError.invalidEvent }
                let id = conn.params["id"] ?? ""
                let update = try await LiveRequest.$instance.withValue(id) {
                    try await LiveRequest.withConnection(checked) {
                        try await host.handle(id, owner: owner(conn), event: event)
                    }
                }
                return try conn.json(value: update).putRespHeader(.cacheControl, "no-store")
            } catch { return failure(error, conn: conn) }
        }
    }

    /// Call before login/logout changes session identity, including revoking open streams.
    public func invalidate(_ conn: Connection) async {
        if let owner = try? owner(conn) { await host.invalidate(owner: owner) }
    }

    public func shutdown() async { await host.shutdown() }

    public func run() async throws {
        do { try await gracefulShutdown() }
        catch { await shutdown(); throw error }
        await shutdown()
    }

    private func owner(_ conn: Connection) throws -> String {
        guard conn[RoostSessionKey.self] != nil,
              let owner = conn.getSession(Self.ownerKey), !owner.isEmpty else { throw LiveError.unauthorized }
        // Renewing authentication must not let another identity reuse the old page.
        return owner + ":" + Auth.sha256Hex(conn.authSessionToken ?? "")
    }

    private func checkFetchOrigin(_ conn: Connection) throws {
        if conn.getReqHeader("Sec-Fetch-Site")?.lowercased() == "cross-site" { throw LiveError.unauthorized }
    }

    private func failure(_ error: any Error, conn: Connection) -> Connection {
        let code = (error as? LiveError)?.rawValue ?? "eventFailed"
        let status: HTTPResponse.Status
        switch error as? LiveError {
        case .unauthorized: status = .forbidden
        case .notFound, .closed: status = .notFound
        case .stale, .reusedEventID, .notConnected: status = .conflict
        case .busy, .capacity: status = .serviceUnavailable
        case .invalidEvent: status = .unprocessableContent
        default: status = (error as? NexusHTTPError)?.status ?? .internalServerError
        }
        return conn.respond(status: status, body: .string("{\"error\":\"\(code)\"}"))
            .putRespHeader(.contentType, "application/json")
            .putRespHeader(.cacheControl, "no-store")
    }
}

extension LiveRoute where View: LivePage {
    /// Sends `info` to ``LivePage/handleInfo(_:state:conn:)`` of every open page
    /// of this route that listens to `topic`, and streams each new render to its browser.
    ///
    /// ```swift
    /// RoostExample.readingQueue.broadcast(.changed, to: "bookmarks:\(reader.userID)")
    /// ```
    ///
    /// The page whose handler broadcasts doesn't receive the message: its handler
    /// already returns its new state. Returns without waiting for the other pages.
    /// Delivery stays within this process, unless the route was created with a
    /// `pubSub`. A page whose stream is closed misses the message and keeps its
    /// state when it reconnects.
    public func broadcast(_ info: View.Info, to topic: String) {
        let sender = LiveRequest.instance
        guard let relay else { return deliver(info, to: topic, except: sender) }
        Task {
            do { try await relay(info, topic, sender) }
            catch {
                Logger(label: "roost.live").error("Live page couldn't publish a broadcast", metadata: [
                    "topic": .string(topic), "error": .string(String(describing: error)),
                ])
            }
        }
    }

    fileprivate func deliver(_ info: View.Info, to topic: String, except sender: String?) {
        for (id, conn) in listeners.streams(listeningTo: topic) where id != sender {
            Task {
                do {
                    try await LiveRequest.$info.withValue(info) {
                        try await LiveRequest.$instance.withValue(id) {
                            try await LiveRequest.withConnection(conn) {
                                _ = try await host.send(id, event: LiveEvent(name: LiveRequest.infoEvent))
                            }
                        }
                    }
                } catch LiveError.notFound, LiveError.closed {
                    listeners.remove(id)
                } catch {
                    // As for a browser event, the page keeps its state and render.
                    Logger(label: "roost.live").error("Live page failed to handle a broadcast", metadata: [
                        "topic": .string(topic), "error": .string(String(describing: error)),
                    ])
                }
            }
        }
    }
}

extension LiveRoute where View: LivePage, View.Info: Codable {
    /// A route whose broadcasts go through `pubSub`, so they reach the pages
    /// open on every server that shares it, such as servers sharing a
    /// ``ValkeyPubSub``. Return the same instance from ``RoostApp/pubSub``, so
    /// the app runs it.
    ///
    /// ```swift
    /// static let pubSub = PubSub.valkey(url: "valkey://cache.internal:6379")
    /// static let readingQueue = LiveRoute(BookmarksLive(), pubSub: pubSub)
    /// ```
    ///
    /// Each message is JSON-encoded, so servers running different versions of
    /// `Info` drop the messages they can't decode.
    public init(_ view: View, path: String = "/_live", capacity: Int = 1_000,
                lifetime: Duration = .seconds(3_600), pubSub: any RoostPubSub,
                authorize: @escaping @Sendable (Connection) async throws -> Void = { _ in }) {
        let channel = "roost.live:\(path)"
        self.init(view, path: path, capacity: capacity, lifetime: lifetime, relay: { info, topic, sender in
            let json = try JSONEncoder().encode(info as! View.Info)
            try await pubSub.broadcast(channel, event: "info", payload: [
                "topic": topic, "info": String(decoding: json, as: UTF8.self), "sender": sender ?? "",
            ])
        }, authorize: authorize)
        pubSub.subscribe(channel) { [self] message in
            guard let topic = message.payload["topic"] as? String,
                  let json = message.payload["info"] as? String,
                  let sender = message.payload["sender"] as? String,
                  let info = try? JSONDecoder().decode(View.Info.self, from: Data(json.utf8)) else {
                Logger(label: "roost.live").error("Live page couldn't decode a broadcast", metadata: ["channel": .string(channel)])
                return
            }
            deliver(info, to: topic, except: sender)
        }
    }
}

/// The topics each live instance listens to, and the request of its open stream.
final class LiveListeners: @unchecked Sendable {
    private struct Listener {
        let topics: Set<String>
        let expiry: ContinuousClock.Instant
        var stream: (token: UUID, conn: Connection)?
    }

    private let lock = NSLock()
    private var listeners: [String: Listener] = [:]

    /// Instances expire after their ESW lifetime, so registering drops expired ones.
    func register(_ id: String, topics: [String], lifetime: Duration) {
        guard !topics.isEmpty else { return }
        let now = ContinuousClock.now
        lock.withLock {
            listeners = listeners.filter { $0.value.expiry > now }
            listeners[id] = Listener(topics: Set(topics), expiry: now + lifetime)
        }
    }

    /// Records the request of an instance's new stream. ESW keeps one stream per
    /// instance, so it replaces the previous one.
    func open(_ id: String, conn: Connection) -> UUID? {
        lock.withLock {
            guard listeners[id] != nil else { return nil }
            let token = UUID()
            listeners[id]?.stream = (token, conn)
            return token
        }
    }

    func close(_ id: String, token: UUID) {
        lock.withLock { if listeners[id]?.stream?.token == token { listeners[id]?.stream = nil } }
    }

    func remove(_ id: String) {
        lock.withLock { listeners[id] = nil }
    }

    func streams(listeningTo topic: String) -> [(id: String, conn: Connection)] {
        lock.withLock {
            listeners.compactMap { id, listener in
                guard listener.topics.contains(topic), let stream = listener.stream else { return nil }
                return (id, stream.conn)
            }
        }
    }
}

private struct LiveHTML: ESWView {
    let html: String
    func render() -> String { html }
}

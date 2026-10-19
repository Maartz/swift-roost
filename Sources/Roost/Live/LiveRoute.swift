import ESWLive
import Foundation
import Nexus
import NexusRouter
import ServiceLifecycle

/// One stable live endpoint. Include `routes` in the router and this value in
/// `RoostApp.services`. Render its initial page from a normal GET/controller.
/// `authorize` runs on the page and every stream/event request.
public struct LiveRoute<View: Interactive>: Sendable, Service {
    let host: LiveHost<View>
    public let path: String
    private let authorize: @Sendable (Connection) async throws -> Void
    private static var ownerKey: String { "_roost_live_owner" }

    public init(_ view: View, path: String = "/_live", capacity: Int = 1_000,
                lifetime: Duration = .seconds(3_600),
                authorize: @escaping @Sendable (Connection) async throws -> Void = { _ in }) {
        precondition(path.hasPrefix("/") && !path.hasPrefix("//") && !path.hasSuffix("/")
            && !path.contains(where: { $0.isWhitespace || "?#\\:%".contains($0) }))
        self.host = LiveHost(view, capacity: capacity, lifetime: lifetime)
        self.path = path
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
                let updates = try await LiveRequest.withConnection(prepared) {
                    try await host.subscribe(conn.params["id"] ?? "", owner: owner(prepared))
                }
                return prepared.sseEvent { writer in
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
                let update = try await LiveRequest.withConnection(checked) {
                    try await host.handle(conn.params["id"] ?? "", owner: owner(conn), event: event)
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

private struct LiveHTML: ESWView {
    let html: String
    func render() -> String { html }
}

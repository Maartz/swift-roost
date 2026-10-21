import Foundation
import Hummingbird
import HummingbirdTesting
import HummingbirdWSClient
import HummingbirdWSTesting
import Logging
import NIOSSL
import Testing

@testable import Roost

/// The users whose sockets left a topic, by `leave`.
private final class Departures: @unchecked Sendable {
    static let shared = Departures()
    private let lock = NSLock()
    private var users: [String] = []

    func record(_ user: String) { lock.withLock { users.append(user) } }

    func wait(for user: String) async throws {
        while !lock.withLock({ users.contains(user) }) { try await Task.sleep(for: .milliseconds(20)) }
    }
}

private struct LobbyChannel: Channel {
    func join(topic: String, payload: ChannelPayload, socket: ChannelSocket) async throws -> ChannelPayload {
        if topic == "room:locked" { throw ChannelError.unauthorized("locked") }
        return ["user": socket.assigns["user"] as? String ?? "", "greeting": socket.assigns["greeting"] as? String ?? ""]
    }

    func handle(event: String, payload: ChannelPayload, socket: ChannelSocket) async throws {
        switch event {
        case "shout":
            try await socket.broadcast(event: "shout", payload: ["body": payload["body"] ?? "", "from": socket.assigns["user"] ?? ""])
        case "ping":
            try await socket.push(event: "pong", payload: ["count": payload["count"] ?? 0])
        case "fail":
            throw ChannelError.unauthorized("no failing here")
        default:
            break
        }
    }

    func leave(topic: String, payload: ChannelPayload, socket: ChannelSocket) async {
        Departures.shared.record(socket.assigns["user"] as? String ?? "")
    }
}

private struct SocketApp: RoostApp {
    var channels: ChannelRouter {
        ChannelRouter { on("room:*", LobbyChannel.self) }
    }

    var plugs: [Plug] { [{ conn in conn.assign(key: "greeting", value: "hello") }] }

    func authenticateSocket(_ conn: Connection) async throws -> SocketAssigns {
        guard let user = conn.queryParams["user"] else { throw ChannelError.unauthorized("Who are you?") }
        return ["user": user, "greeting": conn.assigns["greeting"] ?? ""]
    }

    @RouteBuilder var routes: [Route] {
        GET("/") { conn in conn.text("ok") }
    }
}

/// A frame of Phoenix's V2 protocol: `[join_ref, ref, topic, event, payload]`.
private struct Frame {
    let joinRef: String?
    let ref: String?
    let topic: String
    let event: String
    let payload: [String: Any]

    var status: String? { payload["status"] as? String }
    var response: [String: Any] { payload["response"] as? [String: Any] ?? [:] }
}

/// Speaks Phoenix's V2 protocol to the server, as phoenix.js does.
private struct PhoenixClient {
    let outbound: WebSocketOutboundWriter
    var messages: WebSocketInboundMessageStream.AsyncIterator

    init(_ inbound: WebSocketInboundStream, _ outbound: WebSocketOutboundWriter) {
        self.outbound = outbound
        self.messages = inbound.messages(maxSize: 1 << 20).makeAsyncIterator()
    }

    func send(_ joinRef: String?, _ ref: String?, _ topic: String, _ event: String, _ payload: [String: Any] = [:])
        async throws
    {
        try await Self.send(on: outbound, joinRef, ref, topic, event, payload)
    }

    static func send(
        on outbound: WebSocketOutboundWriter, _ joinRef: String?, _ ref: String?, _ topic: String, _ event: String,
        _ payload: [String: Any] = [:]
    ) async throws {
        let frame: [Any] = [joinRef ?? NSNull(), ref ?? NSNull(), topic, event, payload]
        try await outbound.write(.text(String(decoding: try JSONSerialization.data(withJSONObject: frame), as: UTF8.self)))
    }

    /// The next frame from the server.
    mutating func receive() async throws -> Frame {
        guard case .text(let text) = try await messages.next() else { throw CancellationError() }
        let fields = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any])
        try #require(fields.count == 5)
        return Frame(joinRef: fields[0] as? String, ref: fields[1] as? String, topic: try #require(fields[2] as? String),
                     event: try #require(fields[3] as? String), payload: try #require(fields[4] as? [String: Any]))
    }

    /// Joins `topic` and returns the server's reply.
    mutating func join(_ topic: String, ref: String) async throws -> Frame {
        try await send(ref, ref, topic, "phx_join")
        return try await receive()
    }
}

@Suite("Channel sockets", .timeLimit(.minutes(1)))
struct ChannelSocketTests {
    /// Serves `SocketApp`'s channels, as `main()` does.
    private func serve(
        tls: ServerConfig.TLSConfig? = nil,
        _ body: @Sendable (any TestClientProtocol) async throws -> Void
    ) async throws {
        let app = SocketApp()
        let sockets = try #require(roost_channelSockets(
            app, spectro: nil, store: MemoryKeyValueStore(), channels: ChannelRegistry(router: app.channels),
            jobs: nil, pubSub: nil))
        let config = ServerConfig(host: "127.0.0.1", port: 0, tls: tls)
        let server = Application(
            responder: NexusHummingbirdAdapter(plug: { conn in conn.text("ok") }),
            server: try config.serverBuilder(channels: sockets),
            configuration: .init(address: .hostname(config.host, port: config.port))
        )
        try await server.test(.live) { client in try await body(client) }
    }

    @Test func joiningATopicRepliesWithTheChannelsPayload() async throws {
        try await serve { client in
            try await client.ws("/socket/websocket?vsn=2.0.0&user=ada") { inbound, outbound, _ in
                var phoenix = PhoenixClient(inbound, outbound)
                let reply = try await phoenix.join("room:lobby", ref: "1")
                #expect(reply.joinRef == "1" && reply.ref == "1" && reply.topic == "room:lobby")
                #expect(reply.event == "phx_reply" && reply.status == "ok")
                // The assigns come from the app's plugs and authenticateSocket(_:).
                #expect(reply.response["user"] as? String == "ada")
                #expect(reply.response["greeting"] as? String == "hello")
            }
        }
    }

    @Test func aRejectedJoinRepliesWithItsReason() async throws {
        try await serve { client in
            try await client.ws("/socket/websocket?user=ada") { inbound, outbound, _ in
                var phoenix = PhoenixClient(inbound, outbound)
                let locked = try await phoenix.join("room:locked", ref: "1")
                #expect(locked.status == "error" && locked.response["reason"] as? String == "locked")
                let unknown = try await phoenix.join("kitchen:sink", ref: "2")
                #expect(unknown.status == "error" && unknown.response["reason"] as? String == "unmatched topic")
            }
        }
    }

    @Test func heartbeatsGetAReply() async throws {
        try await serve { client in
            try await client.ws("/socket/websocket?user=ada") { inbound, outbound, _ in
                var phoenix = PhoenixClient(inbound, outbound)
                try await phoenix.send(nil, "7", "phoenix", "heartbeat")
                let reply = try await phoenix.receive()
                #expect(reply.joinRef == nil && reply.ref == "7" && reply.topic == "phoenix")
                #expect(reply.event == "phx_reply" && reply.status == "ok")
            }
        }
    }

    @Test func aPushRepliesAndBroadcastsToTheTopic() async throws {
        try await serve { client in
            try await client.ws("/socket/websocket?user=ada") { inbound, outbound, _ in
                var ada = PhoenixClient(inbound, outbound)
                _ = try await ada.join("room:lobby", ref: "1")
                try await client.ws("/socket/websocket?user=bob") { inbound, bobOutbound, _ in
                    var bob = PhoenixClient(inbound, bobOutbound)
                    _ = try await bob.join("room:lobby", ref: "10")

                    try await PhoenixClient.send(on: outbound, "1", "2", "room:lobby", "shout", ["body": "hi"])
                    let shout = try await bob.receive()
                    #expect(shout.joinRef == "10" && shout.ref == nil && shout.event == "shout")
                    #expect(shout.payload["body"] as? String == "hi" && shout.payload["from"] as? String == "ada")
                }
                let echo = try await ada.receive()
                #expect(echo.event == "shout")
                let reply = try await ada.receive()
                #expect(reply.ref == "2" && reply.event == "phx_reply" && reply.status == "ok")
            }
        }
    }

    @Test func aChannelPushesToItsOwnClient() async throws {
        try await serve { client in
            try await client.ws("/socket/websocket?user=ada") { inbound, outbound, _ in
                var phoenix = PhoenixClient(inbound, outbound)
                _ = try await phoenix.join("room:lobby", ref: "1")
                try await phoenix.send("1", "2", "room:lobby", "ping", ["count": 3])
                let pong = try await phoenix.receive()
                #expect(pong.joinRef == "1" && pong.topic == "room:lobby" && pong.event == "pong")
                #expect(pong.payload["count"] as? Int == 3)
            }
        }
    }

    @Test func aPushTheChannelRejectsRepliesWithAnError() async throws {
        try await serve { client in
            try await client.ws("/socket/websocket?user=ada") { inbound, outbound, _ in
                var phoenix = PhoenixClient(inbound, outbound)
                _ = try await phoenix.join("room:lobby", ref: "1")
                try await phoenix.send("1", "2", "room:lobby", "fail")
                let failed = try await phoenix.receive()
                #expect(failed.ref == "2" && failed.status == "error")
                #expect(failed.response["reason"] as? String == "no failing here")
                try await phoenix.send("1", "3", "room:elsewhere", "shout")
                let unjoined = try await phoenix.receive()
                #expect(unjoined.ref == "3" && unjoined.status == "error")
                #expect(unjoined.response["reason"] as? String == "unmatched topic")
            }
        }
    }

    @Test func leavingATopicRunsTheChannelsLeave() async throws {
        let user = UUID().uuidString
        try await serve { client in
            try await client.ws("/socket/websocket?user=\(user)") { inbound, outbound, _ in
                var phoenix = PhoenixClient(inbound, outbound)
                _ = try await phoenix.join("room:lobby", ref: "1")
                try await phoenix.send("1", "2", "room:lobby", "phx_leave")
                let reply = try await phoenix.receive()
                #expect(reply.ref == "2" && reply.status == "ok")
                try await Departures.shared.wait(for: user)
                try await phoenix.send("1", "3", "room:lobby", "shout")
                let rejected = try await phoenix.receive()
                #expect(rejected.status == "error")
            }
        }
    }

    @Test func closingTheSocketLeavesItsTopics() async throws {
        let user = UUID().uuidString
        try await serve { client in
            try await client.ws("/socket/websocket?user=\(user)") { inbound, outbound, _ in
                var phoenix = PhoenixClient(inbound, outbound)
                _ = try await phoenix.join("room:lobby", ref: "1")
            }
            try await Departures.shared.wait(for: user)
        }
    }

    @Test func aSocketTheAppRejectsDoesntConnect() async throws {
        try await serve { client in
            await #expect(throws: WebSocketClientError.webSocketUpgradeFailed) {
                try await client.ws("/socket/websocket") { _, _, _ in }
            }
        }
    }

    @Test func aPageFromAnotherSiteCantConnect() async throws {
        try await serve { client in
            let port = try #require(client.port)
            let other = WebSocketClientConfiguration(additionalHeaders: [.origin: "https://evil.example"])
            await #expect(throws: WebSocketClientError.webSocketUpgradeFailed) {
                try await client.ws("/socket/websocket?user=ada", configuration: other) { _, _, _ in }
            }
            let same = WebSocketClientConfiguration(additionalHeaders: [.origin: "http://localhost:\(port)"])
            try await client.ws("/socket/websocket?user=ada", configuration: same) { inbound, outbound, _ in
                var phoenix = PhoenixClient(inbound, outbound)
                let joined = try await phoenix.join("room:lobby", ref: "1")
                #expect(joined.status == "ok")
            }
        }
    }

    @Test func channelsServeOverTLS() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let certificatePath = directory.appendingPathComponent("cert.pem").path
        let keyPath = directory.appendingPathComponent("key.pem").path
        try localhostCertificate.write(toFile: certificatePath, atomically: true, encoding: .utf8)
        try localhostKey.write(toFile: keyPath, atomically: true, encoding: .utf8)
        var client = TLSConfiguration.makeClientConfiguration()
        client.trustRoots = .certificates(try NIOSSLCertificate.fromPEMBytes(Array(localhostCertificate.utf8)))
        let trust = client

        // Stopping can take 5 seconds: NIOSSL waits that long for a TLS close_notify the test client may not send.
        try await serve(tls: .init(certificatePath: certificatePath, keyPath: keyPath)) { client in
            let port = try #require(client.port)
            try await WebSocketClient.connect(
                url: "wss://localhost:\(port)/socket/websocket?user=ada", tlsConfiguration: trust,
                logger: Logger(label: "test")
            ) { inbound, outbound, _ in
                var phoenix = PhoenixClient(inbound, outbound)
                let joined = try await phoenix.join("room:lobby", ref: "1")
                #expect(joined.status == "ok")
            }
        }
    }
}

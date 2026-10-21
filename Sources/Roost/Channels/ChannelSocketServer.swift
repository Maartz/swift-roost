import Foundation
import HTTPTypes
import HummingbirdWebSocket
import Logging
import Nexus
import NIOCore

/// Serves the app's channels over WebSocket in Phoenix's V2 JSON protocol, so
/// phoenix.js connects to Roost as it does to Phoenix.
///
/// Each frame is a JSON array, `[join_ref, ref, topic, event, payload]`. A
/// client joins topics with `phx_join`, leaves them with `phx_leave`, and sends
/// a `heartbeat` to the `phoenix` topic. Each of these messages, and each event
/// the client pushes, gets a `phx_reply` with the same `ref`.
package struct ChannelSocketServer: Sendable {
    /// The largest message a client may send, in bytes.
    static let maxMessageSize = 1 << 20

    /// The WebSocket's path, such as `/socket/websocket`.
    let path: String
    let registry: ChannelRegistry
    /// The socket's assigns for an upgrade request. Throws to refuse it.
    let connect: @Sendable (Connection) async throws -> SocketAssigns

    /// Whether to upgrade `request` to a channel socket. A refused socket gets
    /// a 400 response.
    func shouldUpgrade(
        _ request: HTTPRequest, channel: any NIOCore.Channel, logger: Logger
    ) async throws -> ShouldUpgradeResult<WebSocketDataHandler<HTTP1WebSocketUpgradeChannel.Context>> {
        guard request.path?.split(separator: "?", maxSplits: 1).first.map(String.init) == path else {
            return .dontUpgrade
        }
        guard Self.isSameOrigin(request) else {
            logger.notice("Refused a channel socket from another site", metadata: [
                "origin": .string(request.headerFields[.origin] ?? ""),
            ])
            throw ChannelError.unauthorized("cross-origin socket")
        }
        var conn = Connection(request: request)
        if let ip = channel.remoteAddress?.ipAddress {
            conn = conn.assign(key: Connection.remoteIPKey, value: ip)
        }
        let assigns = try await connect(conn)
        let registry = registry
        return .upgrade([:]) { inbound, outbound, context in
            await ChannelClient.run(assigns: assigns, registry: registry, inbound: inbound, outbound: outbound,
                                    logger: context.logger)
        }
    }

    /// Whether the request's `Origin` names the host it was sent to, as
    /// Phoenix checks by default, so a page on another site can't open a socket
    /// with the user's cookies. A client that sends no `Origin` isn't a browser.
    // ponytail: same host only; add a list of allowed origins when an app serves pages from another one.
    static func isSameOrigin(_ request: HTTPRequest) -> Bool {
        let requested = request.authority.flatMap { URLComponents(string: "http://\($0)")?.host?.lowercased() }
        return request.headerFields[values: .origin].allSatisfy { origin in
            URLComponents(string: origin)?.host?.lowercased() == requested && requested != nil
        }
    }
}

/// One client socket: the topics it joined, and the frames waiting for it.
private struct ChannelClient {
    private struct Membership {
        let joinRef: String?
        let socket: ChannelSocket
    }

    private let assigns: SocketAssigns
    private let registry: ChannelRegistry
    private let frames: AsyncStream<String>.Continuation
    private let logger: Logger
    /// The joined topics. Only the socket's inbound loop reads and changes them.
    private var memberships: [String: Membership] = [:]

    static func run(
        assigns: SocketAssigns, registry: ChannelRegistry, inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter, logger: Logger
    ) async {
        // Broadcasts from other sockets' tasks queue here, so one writer sends frames in order.
        // ponytail: unbounded; a client that stops reading grows it until its ping times out.
        let (frames, continuation) = AsyncStream.makeStream(of: String.self)
        var client = ChannelClient(assigns: assigns, registry: registry, frames: continuation, logger: logger)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await frame in frames {
                    // A write fails once the socket closes; the reader below notices and leaves.
                    try? await outbound.write(.text(frame))
                }
            }
            do {
                // ponytail: one message at a time; a slow handler delays the socket's other topics and heartbeats.
                for try await message in inbound.messages(maxSize: ChannelSocketServer.maxMessageSize) {
                    guard case .text(let text) = message else { continue }
                    await client.receive(text)
                }
            } catch {
                logger.debug("Channel socket closed", metadata: ["error": .string(String(describing: error))])
            }
            await client.leaveAll()
            continuation.finish()
        }
    }

    private init(assigns: SocketAssigns, registry: ChannelRegistry, frames: AsyncStream<String>.Continuation,
                 logger: Logger) {
        self.assigns = assigns
        self.registry = registry
        self.frames = frames
        self.logger = logger
    }

    // MARK: - Messages

    private struct Message {
        let joinRef: String?
        let ref: String?
        let topic: String
        let event: String
        let payload: ChannelPayload
    }

    private mutating func receive(_ text: String) async {
        guard case .array(let fields)? = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
              fields.count == 5, case .string(let topic) = fields[2], case .string(let event) = fields[3]
        else {
            logger.debug("Ignored a frame that isn't Phoenix's V2 protocol")
            return
        }
        let message = Message(joinRef: fields[0].value as? String, ref: fields[1].value as? String, topic: topic,
                              event: event, payload: fields[4].value as? ChannelPayload ?? [:])
        switch (message.topic, message.event) {
        case ("phoenix", "heartbeat"): reply(to: message, status: "ok")
        case (_, "phx_join"): await join(message)
        case (_, "phx_leave"): await leave(message)
        default: await handle(message)
        }
    }

    private mutating func join(_ message: Message) async {
        // A client joins again after a lost reply, under a new join_ref.
        if let membership = memberships.removeValue(forKey: message.topic) {
            await leave(message.topic, membership)
        }
        guard let channel = registry.router.handler(for: message.topic) else {
            return reply(to: message, status: "error", ["reason": "unmatched topic"])
        }
        let socket = ChannelSocket(assigns: assigns, registry: registry)
        socket.deliverHandler = { [frames, logger, joinRef = message.joinRef, topic = message.topic] event, payload in
            // `ChannelSocket.reply(ref:payload:)` names the ref in the payload.
            let ref = event == "phx_reply" ? payload["ref"] as? String : nil
            var payload = payload
            if ref != nil { payload["ref"] = nil }
            Self.send(Frame(joinRef: joinRef, ref: ref, topic: topic, event: event, payload: payload), to: frames,
                      logger: logger)
        }
        registry.register(socket, topic: message.topic)
        do {
            let response = try await channel.join(topic: message.topic, payload: message.payload, socket: socket)
            memberships[message.topic] = Membership(joinRef: message.joinRef, socket: socket)
            reply(to: message, status: "ok", response)
        } catch {
            await Presence.untrackAll(socket, topic: message.topic)
            registry.unregister(socket, topic: message.topic)
            reply(to: message, status: "error", reason(error))
        }
    }

    private mutating func leave(_ message: Message) async {
        guard let membership = memberships.removeValue(forKey: message.topic) else {
            return reply(to: message, status: "error", ["reason": "unmatched topic"])
        }
        await leave(message.topic, membership, payload: message.payload)
        reply(to: message, status: "ok")
    }

    private func handle(_ message: Message) async {
        guard let membership = memberships[message.topic], let channel = registry.router.handler(for: message.topic)
        else {
            return reply(to: message, status: "error", ["reason": "unmatched topic"])
        }
        do {
            try await channel.handle(event: message.event, payload: message.payload, socket: membership.socket)
            reply(to: message, status: "ok")
        } catch {
            reply(to: message, status: "error", reason(error))
        }
    }

    /// Leaves every joined topic, when the socket closes.
    mutating func leaveAll() async {
        for (topic, membership) in memberships { await leave(topic, membership) }
        memberships = [:]
    }

    private func leave(_ topic: String, _ membership: Membership, payload: ChannelPayload = [:]) async {
        await registry.router.handler(for: topic)?.leave(topic: topic, payload: payload, socket: membership.socket)
        await Presence.untrackAll(membership.socket, topic: topic)
        registry.unregister(membership.socket, topic: topic)
    }

    // MARK: - Frames

    private struct Frame {
        let joinRef: String?
        let ref: String?
        let topic: String
        let event: String
        let payload: ChannelPayload
    }

    /// The reason a client sees for `error`. Only a `ChannelError` explains
    /// itself, so other errors don't reveal the server's internals.
    private func reason(_ error: any Error) -> ChannelPayload {
        if case ChannelError.unauthorized(let reason) = error { return ["reason": reason] }
        logger.error("Channel handler failed", metadata: ["error": .string(String(describing: error))])
        return ["reason": "internal error"]
    }

    private func reply(to message: Message, status: String, _ response: ChannelPayload = [:]) {
        func frame(_ status: String, _ response: ChannelPayload) -> Frame {
            Frame(joinRef: message.joinRef, ref: message.ref, topic: message.topic, event: "phx_reply",
                  payload: ["status": status, "response": response])
        }
        // The client waits for a reply, even to a response that isn't JSON.
        if !Self.send(frame(status, response), to: frames, logger: logger) {
            Self.send(frame("error", ["reason": "internal error"]), to: frames, logger: logger)
        }
    }

    /// Queues `frame` for the client. Returns `false`, and logs, when its payload isn't JSON.
    @discardableResult
    private static func send(_ frame: Frame, to frames: AsyncStream<String>.Continuation, logger: Logger) -> Bool {
        do {
            let json = try JSONEncoder().encode(JSONValue.array([
                frame.joinRef.map(JSONValue.string) ?? .null, frame.ref.map(JSONValue.string) ?? .null,
                .string(frame.topic), .string(frame.event), JSONValue(frame.payload),
            ]))
            frames.yield(String(decoding: json, as: UTF8.self))
            return true
        } catch {
            logger.error("Dropped a channel event whose payload isn't JSON", metadata: [
                "topic": .string(frame.topic), "event": .string(frame.event), "error": .string(String(describing: error)),
            ])
            return false
        }
    }
}

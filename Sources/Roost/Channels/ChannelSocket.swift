import Foundation

/// Represents one live connection to the channel system.
///
/// Passed to every `Channel` method. Use it to push events to this client,
/// broadcast to all topic subscribers, or read authentication assigns.
///
/// Uses `@unchecked Sendable` with an `NSLock` so `assigns` is safe to read
/// from concurrent channel handlers without requiring `await`.
public final class ChannelSocket: @unchecked Sendable {

    // MARK: - Public properties

    /// Unique identifier for this socket connection.
    public let id: UUID = UUID()

    /// Assigns set during socket authentication (e.g. `userID`, `userName`).
    public var assigns: SocketAssigns

    /// The topic this socket has joined (e.g. `"room:lobby"`).
    public internal(set) var topic: String = ""

    // MARK: - Internal

    var registry: ChannelRegistry?

    /// Called by the registry when an event is delivered to this socket.
    /// Set by `TestChannelSocket` to buffer events for test assertions.
    public var deliverHandler: @Sendable (String, ChannelPayload) -> Void = { _, _ in }

    // MARK: - Init

    public init(assigns: SocketAssigns, registry: ChannelRegistry?) {
        self.assigns = assigns
        self.registry = registry
    }

    // MARK: - Send to this client only

    /// Pushes an event to this connected client only.
    ///
    /// - Throws: `EncodingError` for a payload that JSON can't hold.
    public func push(event: String, payload: ChannelPayload) async throws {
        _ = try JSONValue(payload)
        deliverHandler(event, payload)
    }

    /// Sends an acknowledgement for a specific client message ref.
    public func reply(ref: String, payload: ChannelPayload) async throws {
        deliverHandler("phx_reply", ["ref": ref, "response": payload as any Sendable, "status": "ok"])
    }

    // MARK: - Broadcast

    /// Broadcasts an event to **all** subscribers on this socket's topic, including the sender.
    ///
    /// - Throws: `EncodingError` for a payload that JSON can't hold.
    public func broadcast(event: String, payload: ChannelPayload) async throws {
        _ = try JSONValue(payload)
        try await registry?.deliver(topic: topic, event: event, payload: payload, from: self, excludeSender: false)
    }

    /// Broadcasts an event to all subscribers on this socket's topic, **excluding** the sender.
    ///
    /// - Throws: `EncodingError` for a payload that JSON can't hold.
    public func broadcastFrom(event: String, payload: ChannelPayload) async throws {
        _ = try JSONValue(payload)
        try await registry?.deliver(topic: topic, event: event, payload: payload, from: self, excludeSender: true)
    }
}

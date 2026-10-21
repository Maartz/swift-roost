import Foundation
import Roost

// MARK: - ChannelReply

/// The reply returned by `join` and `leave` operations.
public struct ChannelReply: Sendable {
    /// `"ok"` or `"error"`.
    public let status: String
    /// The payload returned by the channel handler.
    public let payload: ChannelPayload
}

// MARK: - TestChannelSocket

/// An in-process channel client for use in tests.
///
/// Speaks the Phoenix Channel lifecycle without a real WebSocket connection.
/// Buffers received events so they can be inspected with `receive(event:)`
/// (async, suspends until event arrives) or `receivedEvents(named:)` (sync snapshot).
///
/// Uses `@unchecked Sendable` with an `NSLock` to allow synchronous
/// `receivedEvents(named:)` without requiring `await`.
public final class TestChannelSocket: @unchecked Sendable {

    // MARK: - Properties

    /// The underlying channel socket (holds assigns, topic, registry reference).
    public let socket: ChannelSocket
    private let registry: ChannelRegistry
    private let router: ChannelRouter

    // MARK: - Event buffer

    private let lock = NSLock()
    private var buffer: [(event: String, payload: ChannelPayload)] = []
    private var waiters: [(event: String, continuation: CheckedContinuation<ChannelPayload, Error>)] = []
    private var joinedTopics: [String] = []

    // MARK: - Init

    init(socket: ChannelSocket, registry: ChannelRegistry, router: ChannelRouter) {
        self.socket = socket
        self.registry = registry
        self.router = router

        // Wire delivery: all events sent to this socket land in the buffer
        socket.deliverHandler = { [weak self] event, payload in
            self?.deliver(event: event, payload: payload)
        }
    }

    // MARK: - Lifecycle cleanup

    deinit {
        // Synchronous cleanup — ChannelRegistry uses NSLock, not an actor
        for topic in joinedTopics {
            registry.unregister(socket, topic: topic)
            registry.untrackAllPresence(socketID: socket.id, topic: topic)
        }
    }

    // MARK: - Channel lifecycle

    /// Joins a topic. Calls the channel handler's `join` and registers the socket.
    /// - Returns: `ChannelReply(status: "ok", payload: ...)` on success.
    /// - Throws: `ChannelError.unauthorized` if the handler rejects.
    public func join(_ topic: String, payload: ChannelPayload = [:]) async throws -> ChannelReply {
        guard let handler = router.handler(for: topic) else {
            throw ChannelError.unauthorized("No channel registered for topic: \(topic)")
        }
        registry.register(socket, topic: topic)
        lock.withLock { joinedTopics.append(topic) }
        do {
            let replyPayload = try await handler.join(topic: topic, payload: payload, socket: socket)
            return ChannelReply(status: "ok", payload: replyPayload)
        } catch {
            await Presence.untrackAll(socket, topic: topic)
            registry.unregister(socket, topic: topic)
            lock.withLock { joinedTopics.removeAll { $0 == topic } }
            throw error
        }
    }

    /// Leaves a topic. Calls the channel handler's `leave` and unregisters the socket.
    public func leave(_ topic: String) async throws -> ChannelReply {
        if let handler = router.handler(for: topic) {
            await handler.leave(topic: topic, payload: [:], socket: socket)
        }
        await Presence.untrackAll(socket, topic: topic)
        registry.unregister(socket, topic: topic)
        lock.withLock { joinedTopics.removeAll { $0 == topic } }
        return ChannelReply(status: "ok", payload: [:])
    }

    // MARK: - Sending events

    /// Pushes a client event to the channel handler.
    /// The handler may broadcast events back, which will appear in `receive(event:)`.
    public func push(event: String, payload: ChannelPayload = [:]) async throws {
        guard let handler = router.handler(for: socket.topic) else { return }
        try await handler.handle(event: event, payload: payload, socket: socket)
    }

    // MARK: - Receiving events

    /// Suspends until the named event arrives in this socket's buffer.
    public func receive(event: String) async throws -> ChannelPayload {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if let idx = buffer.firstIndex(where: { $0.event == event }) {
                    let item = buffer.remove(at: idx)
                    continuation.resume(returning: item.payload)
                } else {
                    waiters.append((event: event, continuation: continuation))
                }
            }
        }
    }

    /// Returns a synchronous snapshot of all buffered events with the given name.
    /// Does not consume them from the buffer.
    public func receivedEvents(named event: String) -> [ChannelPayload] {
        lock.withLock {
            buffer.filter { $0.event == event }.map { $0.payload }
        }
    }

    // MARK: - Internal delivery

    private func deliver(event: String, payload: ChannelPayload) {
        lock.withLock {
            if let idx = waiters.firstIndex(where: { $0.event == event }) {
                let waiter = waiters.remove(at: idx)
                waiter.continuation.resume(returning: payload)
            } else {
                buffer.append((event: event, payload: payload))
            }
        }
    }
}

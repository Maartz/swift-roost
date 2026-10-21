import Foundation

/// The shared hub that tracks live sockets per topic and fans out broadcasts.
///
/// Uses `@unchecked Sendable` with an `NSLock` so registration and unregistration
/// are synchronous — allowing `TestChannelSocket.deinit` to clean up without `await`.
public final class ChannelRegistry: @unchecked Sendable {

    // MARK: - Types

    private struct PresenceMeta {
        let socketID: UUID
        let meta: ChannelPayload
    }

    // MARK: - State

    public var router: ChannelRouter
    private let lock = NSLock()
    private var sockets: [String: [UUID: ChannelSocket]] = [:]
    /// topic → key → [PresenceMeta] — supports multiple metas per key (multi-tab)
    private var presenceState: [String: [String: [PresenceMeta]]] = [:]

    // MARK: - Init

    public init(router: ChannelRouter = ChannelRouter()) {
        self.router = router
    }

    // MARK: - Registration (synchronous)

    /// Registers a socket as a subscriber for `topic`.
    public func register(_ socket: ChannelSocket, topic: String) {
        lock.withLock {
            socket.topic = topic
            if sockets[topic] == nil { sockets[topic] = [:] }
            sockets[topic]![socket.id] = socket
        }
    }

    /// Removes a socket from `topic` subscriptions.
    public func unregister(_ socket: ChannelSocket, topic: String) {
        _ = lock.withLock {
            sockets[topic]?.removeValue(forKey: socket.id)
        }
    }

    // MARK: - Presence (synchronous)

    /// Adds a meta entry for `key` under `topic` (multi-tab: appends if key already exists).
    public func trackPresence(socketID: UUID, topic: String, key: String, meta: ChannelPayload) {
        lock.withLock {
            if presenceState[topic] == nil { presenceState[topic] = [:] }
            if presenceState[topic]![key] == nil { presenceState[topic]![key] = [] }
            presenceState[topic]![key]!.append(PresenceMeta(socketID: socketID, meta: meta))
        }
    }

    /// Removes the specific socketID's meta for `key` under `topic`.
    /// Removes the key entirely when all metas are gone.
    public func untrackPresence(socketID: UUID, topic: String, key: String) {
        lock.withLock {
            presenceState[topic]?[key]?.removeAll { $0.socketID == socketID }
            if presenceState[topic]?[key]?.isEmpty == true {
                presenceState[topic]?.removeValue(forKey: key)
            }
        }
    }

    /// Removes ALL presence entries for `socketID` across all keys in `topic`.
    /// Used by `TestChannelSocket.deinit` for connection-drop cleanup.
    public func untrackAllPresence(socketID: UUID, topic: String) {
        lock.withLock {
            for key in presenceState[topic]?.keys ?? [:].keys {
                presenceState[topic]?[key]?.removeAll { $0.socketID == socketID }
            }
            // Remove empty keys
            presenceState[topic]?.keys.forEach { key in
                if presenceState[topic]?[key]?.isEmpty == true {
                    presenceState[topic]?.removeValue(forKey: key)
                }
            }
        }
    }

    /// Returns the meta for a specific socketID+key (used by Presence.untrack for diff payload).
    public func presenceMeta(socketID: UUID, topic: String, key: String) -> ChannelPayload? {
        lock.withLock {
            presenceState[topic]?[key]?.first { $0.socketID == socketID }?.meta
        }
    }

    /// Returns the sorted presence list for a topic.
    public func listPresence(topic: String) -> [PresenceEntry] {
        let state = lock.withLock { presenceState[topic] ?? [:] }
        let entries = state.map { (key, metas) in
            PresenceEntry(key: key, metas: metas.map { $0.meta })
        }
        // Sort by earliest online_at across all metas for stable ordering
        return entries.sorted { a, b in
            let aTime = a.metas.compactMap { $0["online_at"] as? Double }.min() ?? 0
            let bTime = b.metas.compactMap { $0["online_at"] as? Double }.min() ?? 0
            return aTime < bTime
        }
    }

    // MARK: - Broadcast (internal — from ChannelSocket)

    /// Delivers an event to all sockets on `topic`, optionally excluding the sender.
    /// Runs the channel's `intercept` hook if the event is registered for interception.
    func deliver(
        topic: String,
        event: String,
        payload: ChannelPayload,
        from sender: ChannelSocket,
        excludeSender: Bool
    ) async throws {
        var deliveryPayload = payload

        // Run intercept if the channel type wants to intercept this event
        if let handlerType = router.handlerType(for: topic),
           handlerType.intercepts.contains(event) {
            let handler = handlerType.init()
            deliveryPayload = try await handler.intercept(event: event, payload: payload, socket: sender)
        }

        let targets = lock.withLock {
            sockets[topic].map { Array($0.values) } ?? []
        }
        for socket in targets {
            if excludeSender && socket.id == sender.id { continue }
            socket.deliverHandler(event, deliveryPayload)
        }
    }

    // MARK: - Broadcast (public — server push, no sender)

    /// Broadcasts an event to all sockets on `topic` from outside a handler (e.g. background job).
    /// Does not run intercept hooks.
    ///
    /// - Throws: `EncodingError` for a payload that JSON can't hold.
    public func broadcast(topic: String, event: String, payload: ChannelPayload) async throws {
        _ = try JSONValue(payload)
        let targets = lock.withLock {
            sockets[topic].map { Array($0.values) } ?? []
        }
        for socket in targets {
            socket.deliverHandler(event, payload)
        }
    }
}

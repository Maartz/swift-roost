import Foundation
import Logging

/// The shared hub that tracks live sockets per topic and fans out broadcasts.
///
/// With a PubSub, broadcasts reach the sockets of every server that shares it.
/// Presence stays with each server's own sockets.
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
    private let pubSub: (any RoostPubSub)?
    /// The PubSub topic that carries the app's channel broadcasts between servers.
    private let pubSubTopic: String
    private var subscription: SubscriptionToken?
    private let lock = NSLock()
    private var sockets: [String: [UUID: ChannelSocket]] = [:]
    /// topic → key → [PresenceMeta] — supports multiple metas per key (multi-tab)
    private var presenceState: [String: [String: [PresenceMeta]]] = [:]

    // MARK: - Init

    /// - Parameters:
    ///   - router: The channels, by topic pattern.
    ///   - pubSub: Carries broadcasts between servers. `main()` passes
    ///     ``RoostApp/pubSub``. Without one, broadcasts reach this process only.
    public init(router: ChannelRouter = ChannelRouter(), pubSub: (any RoostPubSub)? = nil) {
        self.router = router
        self.pubSub = pubSub
        self.pubSubTopic = "roost.channels:\(router.path)"
        subscription = pubSub?.subscribe(pubSubTopic) { [weak self] message in await self?.receive(message) }
    }

    deinit {
        if let subscription { pubSub?.unsubscribe(subscription) }
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
    ///
    /// - Returns: The metas it removed.
    @discardableResult
    public func untrackPresence(socketID: UUID, topic: String, key: String) -> [ChannelPayload] {
        lock.withLock {
            let removed = presenceState[topic]?[key]?.filter { $0.socketID == socketID }.map(\.meta) ?? []
            presenceState[topic]?[key]?.removeAll { $0.socketID == socketID }
            if presenceState[topic]?[key]?.isEmpty == true {
                presenceState[topic]?.removeValue(forKey: key)
            }
            return removed
        }
    }

    /// Removes ALL presence entries for `socketID` across all keys in `topic`,
    /// when the socket leaves the topic.
    ///
    /// - Returns: The metas it removed, by key.
    @discardableResult
    public func untrackAllPresence(socketID: UUID, topic: String) -> [String: [ChannelPayload]] {
        lock.withLock {
            var removed: [String: [ChannelPayload]] = [:]
            for (key, metas) in presenceState[topic] ?? [:] {
                let left = metas.filter { $0.socketID == socketID }
                guard !left.isEmpty else { continue }
                removed[key] = left.map(\.meta)
                let staying = metas.filter { $0.socketID != socketID }
                presenceState[topic]?[key] = staying.isEmpty ? nil : staying
            }
            return removed
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

    /// Delivers an event to all sockets on `topic`, through the PubSub when
    /// there is one, optionally excluding the sender.
    func deliver(
        topic: String,
        event: String,
        payload: ChannelPayload,
        from sender: ChannelSocket,
        excludeSender: Bool
    ) async throws {
        try await publish(topic: topic, event: event, payload: payload, except: excludeSender ? sender.id : nil)
    }

    // MARK: - Broadcast (public — server push, no sender)

    /// Broadcasts an event to all sockets on `topic` from outside a handler (e.g. background job).
    ///
    /// - Throws: `EncodingError` for a payload that JSON can't hold, or the
    ///   PubSub's error.
    public func broadcast(topic: String, event: String, payload: ChannelPayload) async throws {
        _ = try JSONValue(payload)
        try await publish(topic: topic, event: event, payload: payload, except: nil)
    }

    private func publish(topic: String, event: String, payload: ChannelPayload, except: UUID?) async throws {
        guard let pubSub else {
            return await deliverLocally(topic: topic, event: event, payload: payload, except: except)
        }
        try await pubSub.broadcast(pubSubTopic, event: event, payload: [
            "topic": topic, "payload": payload, "except": except?.uuidString,
        ])
    }

    private func receive(_ message: PubSubMessage) async {
        guard let topic = message.payload["topic"] as? String, let payload = message.payload["payload"] as? ChannelPayload
        else {
            return Logger(label: "roost.channels").error("Dropped a channel broadcast that isn't Roost's", metadata: [
                "event": .string(message.event),
            ])
        }
        let except = (message.payload["except"] as? String).flatMap(UUID.init(uuidString:))
        await deliverLocally(topic: topic, event: message.event, payload: payload, except: except)
    }

    /// Delivers an event to this process's sockets on `topic`. Each socket
    /// gets the payload the channel's `intercept` returns for it, when the
    /// channel intercepts `event`.
    func deliverLocally(topic: String, event: String, payload: ChannelPayload, except: UUID?) async {
        let targets = lock.withLock { sockets[topic].map { Array($0.values) } ?? [] }
        let handlerType = router.handlerType(for: topic).flatMap { $0.intercepts.contains(event) ? $0 : nil }
        for socket in targets where socket.id != except {
            guard let handlerType else {
                socket.deliverHandler(event, payload)
                continue
            }
            do {
                socket.deliverHandler(event, try await handlerType.init().intercept(event: event, payload: payload,
                                                                                    socket: socket))
            } catch ChannelError.halt {
                continue
            } catch {
                Logger(label: "roost.channels").error("Channel intercept failed", metadata: [
                    "topic": .string(topic), "event": .string(event), "error": .string(String(describing: error)),
                ])
            }
        }
    }
}

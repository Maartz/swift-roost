import Foundation

// MARK: - PresenceEntry

/// One entry in the presence list — a single user/key with one or more metas.
///
/// Multiple metas occur when the same user joins from multiple browser tabs.
public struct PresenceEntry: Sendable {
    /// Typically the user's UUID string — uniquely identifies who is present.
    public let key: String
    /// One metadata dict per joined socket for this key.
    public let metas: [[String: any Sendable]]
}

// MARK: - Presence

/// Tracks which sockets are currently online per topic.
///
/// Backed by `ChannelRegistry`'s in-memory presence state. Payloads follow
/// Phoenix's format, so phoenix.js's `Presence` reads them: tracking a socket
/// pushes it a `presence_state` event with everyone present, and the other
/// subscribers get a `presence_diff` event as sockets come and go. Each meta
/// carries a `phx_ref` that tells a key's metas apart.
///
/// ```swift
/// // In Channel.join:
/// try await Presence.track(socket, topic: topic, key: userID.uuidString, meta: [
///     "name": userName, "online_at": Date().timeIntervalSince1970
/// ])
/// ```
///
/// A socket that leaves the topic, or closes, leaves its presence too.
public enum Presence {

    // MARK: - Track

    /// Registers a socket's presence on a topic with the given key and metadata.
    /// Pushes `presence_state` to the socket, and a `presence_diff` with the
    /// join to all **other** subscribers.
    ///
    /// - Throws: `EncodingError` for metadata that JSON can't hold.
    public static func track(
        _ socket: ChannelSocket,
        topic: String,
        key: String,
        meta: ChannelPayload
    ) async throws {
        guard let registry = socket.registry else { return }
        var meta = meta
        meta["phx_ref"] = UUID().uuidString
        _ = try JSONValue(meta)
        registry.trackPresence(socketID: socket.id, topic: topic, key: key, meta: meta)
        try await registry.deliver(
            topic: topic, event: "presence_diff", payload: diff(joins: [key: [meta]]), from: socket,
            excludeSender: true
        )
        let state = registry.listPresence(topic: topic).map { ($0.key, ["metas": $0.metas] as ChannelPayload) }
        try await socket.push(event: "presence_state", payload: Dictionary(state) { first, _ in first })
    }

    // MARK: - Untrack

    /// Removes a socket's presence entry for the given key on a topic.
    /// Broadcasts a `presence_diff` leaves event to all remaining subscribers.
    public static func untrack(
        _ socket: ChannelSocket,
        topic: String,
        key: String
    ) async {
        guard let registry = socket.registry else { return }
        await announce(leaves: [key: registry.untrackPresence(socketID: socket.id, topic: topic, key: key)],
                       topic: topic, from: socket)
    }

    /// Removes every presence `socket` tracked on `topic`, when it leaves.
    package static func untrackAll(_ socket: ChannelSocket, topic: String) async {
        guard let registry = socket.registry else { return }
        await announce(leaves: registry.untrackAllPresence(socketID: socket.id, topic: topic), topic: topic,
                       from: socket)
    }

    private static func announce(leaves: [String: [ChannelPayload]], topic: String, from socket: ChannelSocket) async {
        let leaves = leaves.filter { !$0.value.isEmpty }
        guard !leaves.isEmpty else { return }
        try? await socket.registry?.deliver(
            topic: topic, event: "presence_diff", payload: diff(leaves: leaves), from: socket, excludeSender: true
        )
    }

    /// A `presence_diff` payload: `{"joins": {key: {"metas": […]}}, "leaves": {…}}`.
    private static func diff(
        joins: [String: [ChannelPayload]] = [:], leaves: [String: [ChannelPayload]] = [:]
    ) -> ChannelPayload {
        func entries(_ metas: [String: [ChannelPayload]]) -> ChannelPayload {
            metas.mapValues { ["metas": $0] as ChannelPayload }
        }
        return ["joins": entries(joins), "leaves": entries(leaves)]
    }

    // MARK: - List

    /// Returns the current presence list for a topic.
    /// Entries are sorted by the earliest `online_at` value across all metas.
    public static func list(_ topic: String, socket: ChannelSocket) async -> [PresenceEntry] {
        socket.registry?.listPresence(topic: topic) ?? []
    }

    /// Returns the current presence list for a topic using a registry directly.
    public static func list(_ topic: String, registry: ChannelRegistry) -> [PresenceEntry] {
        registry.listPresence(topic: topic)
    }
}

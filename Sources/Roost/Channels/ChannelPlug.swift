import Nexus

// MARK: - AssignKey

/// Typed assign key for injecting the `ChannelRegistry` into the connection pipeline.
public enum ChannelRegistryKey: AssignKey {
    public typealias Value = ChannelRegistry
}

// MARK: - Connection extension

extension Connection {
    /// The `ChannelRegistry` injected by Roost's bootstrap.
    /// Available in route handlers when `channels` is configured on the app.
    public var channels: ChannelRegistry {
        guard let registry = self[ChannelRegistryKey.self] else {
            fatalError("No ChannelRegistry configured. Set `channels` in your RoostApp.")
        }
        return registry
    }
}

// MARK: - channel(_:) route function

/// Registers a WebSocket upgrade endpoint for channel connections.
///
/// All channel topics are multiplexed over a single WebSocket connection
/// to this path (e.g. `GET /socket/websocket` for `channel("/socket")`).
///
/// - Note: In the current release, this registers a stub HTTP route.
///   Full WebSocket upgrade support will be added in a future sprint.
@available(*, deprecated, message: "channel(_:) serves a placeholder text response instead of upgrading to a WebSocket. Test channels with TestApp.connectSocket(_:). Roost 3.0 removes it from the stable API until it is implemented.")
public func channel(_ path: String) -> Route {
    let wsPath = path.hasSuffix("/websocket") ? path : "\(path)/websocket"
    return GET(wsPath) { conn in
        // Placeholder: real WebSocket upgrade implemented in a future sprint
        conn.text("WebSocket upgrade required")
    }
}

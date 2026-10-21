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

/// A route that answers requests to a channel socket's path that aren't
/// WebSocket upgrades.
///
/// The server upgrades requests to ``ChannelRouter/path`` before routing, so
/// channels don't need this route.
@available(*, deprecated, message: "The server upgrades channel sockets at ChannelRouter's path before routing: remove channel(_:) from the app's routes. Roost 3.0 removes it.")
public func channel(_ path: String) -> Route {
    let wsPath = path.hasSuffix("/websocket") ? path : "\(path)/websocket"
    return GET(wsPath) { conn in
        conn.text("WebSocket upgrade required")
    }
}

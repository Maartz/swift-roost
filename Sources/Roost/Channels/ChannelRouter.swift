import Foundation

// MARK: - ChannelRoute

/// A single routing rule: maps a topic pattern to a `Channel` handler type.
public struct ChannelRoute: Sendable {
    let pattern: String
    let channelType: any Channel.Type

    /// Returns true if `topic` matches this route's pattern.
    /// Supports trailing wildcard `*` (e.g. `"room:*"` matches `"room:lobby"`).
    func matches(_ topic: String) -> Bool {
        if pattern == topic { return true }
        if pattern.hasSuffix(":*") {
            let prefix = String(pattern.dropLast(2)) + ":"
            return topic.hasPrefix(prefix)
        }
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast(1))
            return topic.hasPrefix(prefix)
        }
        return false
    }
}

// MARK: - DSL function

/// Registers a `Channel` handler for a topic pattern inside a `ChannelRouter`.
///
///     ChannelRouter {
///         on("room:*", RoomChannel.self)
///         on("system:*", SystemChannel.self)
///     }
public func on(_ pattern: String, _ type: (some Channel).Type) -> ChannelRoute {
    ChannelRoute(pattern: pattern, channelType: type)
}

// MARK: - Result builder

@resultBuilder
public struct ChannelRouteBuilder {
    public static func buildBlock(_ routes: ChannelRoute...) -> [ChannelRoute] { routes }
    public static func buildArray(_ components: [[ChannelRoute]]) -> [ChannelRoute] { components.flatMap { $0 } }
}

// MARK: - ChannelRouter

/// Maps topic patterns to `Channel` handler types.
///
/// Configure this on `RoostApp.channels`:
/// ```swift
/// var channels: ChannelRouter {
///     ChannelRouter {
///         on("room:*", RoomChannel.self)
///     }
/// }
/// ```
public struct ChannelRouter: Sendable {
    /// Where clients connect, as with phoenix.js's `new Socket("/socket")`. The
    /// WebSocket itself is at `path` followed by `/websocket`.
    public let path: String
    let routes: [ChannelRoute]

    public init(path: String = "/socket", @ChannelRouteBuilder _ build: () -> [ChannelRoute]) {
        self.path = path
        self.routes = build()
    }

    /// Empty router — used as default when no channels are configured.
    public init() {
        self.path = "/socket"
        self.routes = []
    }

    /// Returns a fresh handler instance for the given topic, or `nil` if no route matches.
    public func handler(for topic: String) -> (any Channel)? {
        for route in routes where route.matches(topic) {
            return route.channelType.init()
        }
        return nil
    }

    /// Returns the handler type for a topic (used to check `static var intercepts`).
    public func handlerType(for topic: String) -> (any Channel.Type)? {
        routes.first { $0.matches(topic) }?.channelType
    }
}

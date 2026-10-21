import Foundation

// MARK: - Type aliases

/// The payload type for all channel events. Clients receive it as JSON, so its
/// values are strings, numbers, booleans, `nil` optionals, and arrays or
/// string-keyed dictionaries of them.
public typealias ChannelPayload = [String: any Sendable]

/// Assigns attached to a socket at authentication time.
public typealias SocketAssigns = [String: any Sendable]

// MARK: - ChannelError

/// Errors thrown by channel handlers.
public enum ChannelError: Error, Equatable {
    /// Thrown from `join` to reject an unauthorized connection.
    case unauthorized(String)
    /// Thrown from `intercept` to drop a message without delivering it.
    case halt
}

// MARK: - Channel protocol

/// A stateless handler for a named topic pattern (e.g. `"room:*"`).
///
/// Conform to this protocol to handle channel lifecycle and events.
/// Instances are created fresh for every call — store shared state in `ChannelRegistry` or PubSub.
public protocol Channel: Sendable {
    init()

    /// Called when a client sends `phx_join` for a matching topic.
    /// Return a payload to send back to the client. Throw `ChannelError.unauthorized` to reject.
    func join(topic: String, payload: ChannelPayload, socket: ChannelSocket) async throws -> ChannelPayload

    /// Called for every custom event the client pushes (anything other than `phx_join`/`phx_leave`).
    func handle(event: String, payload: ChannelPayload, socket: ChannelSocket) async throws

    /// Called when the client leaves or the connection drops.
    func leave(topic: String, payload: ChannelPayload, socket: ChannelSocket) async

    /// Events to intercept before fan-out. Override to return event names this handler intercepts.
    static var intercepts: [String] { get }

    /// Called for each intercepted event. Mutate and return the payload, or throw `ChannelError.halt`.
    func intercept(event: String, payload: ChannelPayload, socket: ChannelSocket) async throws -> ChannelPayload
}

// MARK: - Default implementations

extension Channel {
    public static var intercepts: [String] { [] }

    public func intercept(event: String, payload: ChannelPayload, socket: ChannelSocket) async throws -> ChannelPayload {
        payload
    }
}

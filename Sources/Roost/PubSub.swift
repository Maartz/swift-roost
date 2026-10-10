import Foundation

// MARK: - SubscriptionToken

/// An opaque token returned by `subscribe`. Pass to `unsubscribe` to stop delivery.
public struct SubscriptionToken: Hashable, Sendable {
    private let id: UUID
    public init() { id = UUID() }
}

// MARK: - PubSubMessage

/// A message delivered to topic subscribers.
public struct PubSubMessage: Sendable {
    public let topic: String
    public let event: String
    public let payload: [String: any Sendable]
}

// MARK: - RoostPubSub

/// The interface implemented by all PubSub adapters.
public protocol RoostPubSub: Sendable {
    /// Subscribes to a topic. Returns a token for use with `unsubscribe`.
    @discardableResult
    func subscribe(
        _ topic: String,
        handler: @escaping @Sendable (PubSubMessage) async -> Void
    ) -> SubscriptionToken

    /// Broadcasts a message to all subscribers on the given topic.
    func broadcast(_ topic: String, event: String, payload: [String: any Sendable]) async throws

    /// Stops delivering messages to the subscriber identified by `token`.
    func unsubscribe(_ token: SubscriptionToken)
}

// MARK: - InMemoryPubSub

/// Actor-free, lock-based in-process PubSub adapter. Suitable for dev and test.
///
/// Uses `@unchecked Sendable` with an `NSLock` so `subscribe` and `unsubscribe`
/// remain synchronous — callers do not need `await`.
public final class InMemoryPubSub: RoostPubSub, @unchecked Sendable {

    private let lock = NSLock()
    private var subscribers: [String: [SubscriptionToken: @Sendable (PubSubMessage) async -> Void]] = [:]

    public init() {}

    @discardableResult
    public func subscribe(
        _ topic: String,
        handler: @escaping @Sendable (PubSubMessage) async -> Void
    ) -> SubscriptionToken {
        let token = SubscriptionToken()
        lock.withLock {
            if subscribers[topic] == nil { subscribers[topic] = [:] }
            subscribers[topic]![token] = handler
        }
        return token
    }

    public func broadcast(_ topic: String, event: String, payload: [String: any Sendable]) async throws {
        let handlers: [@Sendable (PubSubMessage) async -> Void] = lock.withLock {
            subscribers[topic].map { Array($0.values) } ?? []
        }
        let message = PubSubMessage(topic: topic, event: event, payload: payload)
        for handler in handlers {
            await handler(message)
        }
    }

    public func unsubscribe(_ token: SubscriptionToken) {
        lock.withLock {
            for key in subscribers.keys {
                subscribers[key]?.removeValue(forKey: token)
            }
        }
    }
}

// MARK: - ValkeyPubSub (stub)

/// Distributed PubSub adapter backed by Valkey PUBLISH/SUBSCRIBE.
///
/// - Note: Not yet implemented. Add a valkey-swift client to `Package.swift` first.
@available(*, deprecated, message: "ValkeyPubSub isn't implemented: each method stops the process. Use PubSub.inMemory(). Roost 3.0 removes it from the stable API until it is implemented.")
public final class ValkeyPubSub: RoostPubSub, @unchecked Sendable {

    private let url: String

    public init(url: String) {
        self.url = url
    }

    @discardableResult
    public func subscribe(
        _ topic: String,
        handler: @escaping @Sendable (PubSubMessage) async -> Void
    ) -> SubscriptionToken {
        fatalError("ValkeyPubSub is not yet implemented. Add valkey-swift to Package.swift.")
    }

    public func broadcast(_ topic: String, event: String, payload: [String: any Sendable]) async throws {
        fatalError("ValkeyPubSub is not yet implemented. Add valkey-swift to Package.swift.")
    }

    public func unsubscribe(_ token: SubscriptionToken) {
        fatalError("ValkeyPubSub is not yet implemented. Add valkey-swift to Package.swift.")
    }
}

// MARK: - PubSub factory

/// Factory for PubSub adapters.
///
/// ```swift
/// // Dev / test
/// PubSub.inMemory()
///
/// ```
///
/// Only the in-memory adapter is implemented, so subscribers must run in the
/// same process as the broadcaster.
public enum PubSub {
    public static func inMemory() -> InMemoryPubSub {
        InMemoryPubSub()
    }

    @available(*, deprecated, message: "ValkeyPubSub isn't implemented: each method stops the process. Use PubSub.inMemory(). Roost 3.0 removes it from the stable API until it is implemented.")
    public static func valkey(url: String) -> ValkeyPubSub {
        ValkeyPubSub(url: url)
    }
}

import Foundation
import Logging
import ServiceLifecycle
#if Valkey
import Valkey
#endif

/// PubSub between servers through a Valkey or Redis server.
///
/// Every server publishes to one Valkey channel and subscribes to it, then
/// delivers each message to its own subscribers of the message's topic, as
/// Phoenix.PubSub's Redis adapter does. Return it from ``RoostApp/pubSub``,
/// so the app runs it:
///
/// ```swift
/// static let pubSub = PubSub.valkey(url: "valkey://cache.internal:6379")
/// var pubSub: (any RoostPubSub)? { Self.pubSub }
/// ```
///
/// It needs Roost's `Valkey` trait. Without it, the app stops at startup.
///
/// Payloads travel as JSON: their values are strings, numbers, booleans, or
/// arrays and string-keyed dictionaries of them, and a whole `Double` arrives
/// as an `Int`. Messages reach this server's subscribers through Valkey too.
/// A server receives the messages published while it's subscribed, so one
/// that is disconnected from Valkey misses them.
public final class ValkeyPubSub: RoostPubSub, Service, @unchecked Sendable {
    #if Valkey
    private let client: Result<ValkeyClient, any Error>
    #else
    private let client: Result<Never, any Error>
    #endif
    private let channel: String
    private let logger: Logger
    private let local = InMemoryPubSub()
    private let lock = NSLock()
    private var running = false

    /// - Parameters:
    ///   - url: `valkey://[user[:password]@]host[:port][/database]`, or `valkeys://` for TLS.
    ///   - channel: The Valkey channel. Servers that use the same one share
    ///     messages. Default: the executable name and environment, such as `ReadingRoom:prod:pubsub`.
    ///   - logger: Logs lost subscriptions and messages that can't be decoded.
    public init(url: String, channel: String? = nil, logger: Logger = Logger(label: "roost.pubsub")) {
        #if Valkey
        // The same connection settings as the key-value store.
        client = Result { try ValkeyKeyValueStore(url: ValkeyURL(url), logger: logger).client }
        #else
        client = .failure(KeyValueStoreError(.misconfigured, """
            ValkeyPubSub needs Roost's Valkey trait. Add it to the swift-roost dependency: \
            traits: [.defaults, "Valkey"]
            """))
        #endif
        self.channel = channel ?? "\(ProcessInfo.processInfo.processName):\(Roost.env.rawValue):pubsub"
        self.logger = logger
    }

    @discardableResult
    public func subscribe(
        _ topic: String,
        handler: @escaping @Sendable (PubSubMessage) async -> Void
    ) -> SubscriptionToken {
        local.subscribe(topic, handler: handler)
    }

    public func unsubscribe(_ token: SubscriptionToken) {
        local.unsubscribe(token)
    }

    public func broadcast(_ topic: String, event: String, payload: [String: any Sendable]) async throws {
        let message = try PubSubMessage(topic: topic, event: event, payload: payload).json()
        #if Valkey
        let client = try client.get()
        // A client that isn't running would wait for a connection forever.
        guard lock.withLock({ running }) else {
            throw KeyValueStoreError(.misconfigured, "ValkeyPubSub isn't running: return it from RoostApp.pubSub")
        }
        try await client.publish(channel: channel, message: String(decoding: message, as: UTF8.self))
        #else
        _ = (message, try client.get())
        #endif
    }

    public func run() async throws {
        #if Valkey
        let client = try client.get()
        lock.withLock { running = true }
        defer { lock.withLock { running = false } }
        // valkey-swift 1.5 stops the process when its client shuts down while a
        // subscription is open, so the client runs detached from graceful
        // shutdown and stops once the subscription has closed.
        let connections = Task.detached { await client.run() }
        await cancelWhenGracefulShutdown { await self.listen(client) }
        connections.cancel()
        await connections.value
        #else
        _ = try client.get()
        #endif
    }

    #if Valkey
    private func listen(_ client: ValkeyClient) async {
        while !Task.isCancelled {
            do {
                try await client.subscribe(to: [channel]) { subscription in
                    for try await message in subscription {
                        do {
                            let message = try PubSubMessage(json: Data(message.message))
                            try await local.broadcast(message.topic, event: message.event, payload: message.payload)
                        } catch {
                            logger.error("PubSub couldn't decode a message", metadata: ["error": "\(error)"])
                        }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    logger.warning("PubSub lost its Valkey subscription and resubscribes", metadata: ["error": "\(error)"])
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
    #endif
}

extension PubSub {
    /// A ``ValkeyPubSub``, which shares messages between the servers that use
    /// `url` and `channel`. Needs Roost's `Valkey` trait.
    public static func valkey(url: String, channel: String? = nil) -> ValkeyPubSub {
        ValkeyPubSub(url: url, channel: channel)
    }
}

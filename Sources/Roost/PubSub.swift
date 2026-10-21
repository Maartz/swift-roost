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

// MARK: - JSON

extension PubSubMessage {
    /// The message as JSON, for an adapter that sends it to other servers.
    ///
    /// - Throws: `EncodingError` for a payload value other than a string,
    ///   number, boolean, or an array or string-keyed dictionary of them.
    func json() throws -> Data {
        try JSONEncoder().encode(["topic": JSONValue.string(topic), "event": .string(event), "payload": JSONValue(payload)])
    }

    init(json: Data) throws {
        let fields = try JSONDecoder().decode([String: JSONValue].self, from: json)
        guard case .string(let topic) = fields["topic"], case .string(let event) = fields["event"],
              case .object(let payload) = fields["payload"] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Not a PubSub message"))
        }
        self.init(topic: topic, event: event, payload: payload.mapValues(\.value))
    }
}

/// A JSON value that decodes to the Swift type it was encoded from, except
/// that a whole `Double` comes back as an `Int`.
private enum JSONValue: Codable {
    case string(String), bool(Bool), int(Int), double(Double), array([JSONValue]), object([String: JSONValue])

    init(_ value: any Sendable) throws {
        switch value {
        case let value as String: self = .string(value)
        case let value as Bool: self = .bool(value)
        case let value as Int: self = .int(value)
        case let value as Double: self = .double(value)
        case let value as [any Sendable]: self = .array(try value.map(JSONValue.init))
        case let value as [String: any Sendable]: self = .object(try value.mapValues(JSONValue.init))
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription:
                "A PubSub payload holds strings, numbers, booleans, arrays, and dictionaries, not \(type(of: value))"))
        }
    }

    var value: any Sendable {
        switch self {
        case .string(let value): value
        case .bool(let value): value
        case .int(let value): value
        case .double(let value): value
        case .array(let values): values.map(\.value)
        case .object(let values): values.mapValues(\.value)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let values = try? container.decode([JSONValue].self) { self = .array(values) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .array(let values): try container.encode(values)
        case .object(let values): try container.encode(values)
        }
    }
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

// MARK: - PubSub factory

/// Factory for PubSub adapters.
///
/// ```swift
/// // One process, such as in development and tests
/// PubSub.inMemory()
///
/// // Several servers, with Roost's Valkey trait
/// PubSub.valkey(url: "valkey://cache.internal:6379")
/// ```
public enum PubSub {
    public static func inMemory() -> InMemoryPubSub {
        InMemoryPubSub()
    }
}

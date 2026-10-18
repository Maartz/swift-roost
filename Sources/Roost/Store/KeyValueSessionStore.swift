import Foundation

/// Keeps sessions in the app's ``KeyValueStore``. With a Valkey store, sessions
/// survive restarts and are shared between servers.
///
/// ```swift
/// let sessionStore: (any SessionStore)? = KeyValueSessionStore()
/// ```
///
/// Session values must be strings, numbers, booleans, or arrays and
/// dictionaries of those. Storing another type, such as a `UUID`, throws
/// ``KeyValueStoreError/Kind/unencodable`` when the session is saved, with
/// every store, so the mistake shows up in development. Store its string form
/// instead.
public struct KeyValueSessionStore: SessionStore {
    private let backend: (any KeyValueStore)?

    /// Sessions in the app's store, ``RoostApp/store``, whether it's
    /// ``RoostApp/sessionStore`` or installed with `session(store:cookieName:ttl:)`.
    public init() {
        backend = nil
    }

    /// Sessions in `store`.
    public init(_ store: any KeyValueStore) {
        backend = store
    }

    public func get(_ id: String) async throws -> [String: any Sendable]? {
        guard let data = try await store().get(Self.key(id)) else { return nil }
        do {
            return try JSONDecoder().decode([String: SessionValue].self, from: data).mapValues(\.value)
        } catch {
            // A session written in another format is treated as expired.
            return nil
        }
    }

    public func set(_ id: String, data: [String: any Sendable], ttl: Duration?) async throws {
        var values: [String: SessionValue] = [:]
        for (key, value) in data {
            guard let value = try SessionValue(value, key: key) else { continue }
            values[key] = value
        }
        try await store().set(Self.key(id), to: JSONEncoder().encode(values), expiringAfter: ttl)
    }

    public func delete(_ id: String) async throws {
        try await store().remove(Self.key(id))
    }

    private func store() throws -> any KeyValueStore {
        guard let store = backend ?? RequestKeyValueStore.current else {
            throw KeyValueStoreError(.misconfigured, """
                KeyValueSessionStore() uses the app's store while a Roost app or TestApp handles a request. \
                Elsewhere, pass a store: KeyValueSessionStore(store)
                """)
        }
        return store
    }

    /// The session ID is the cookie's value, so the key holds its hash:
    /// anyone who can list the store's keys can't sign in with them.
    static func key(_ id: String) -> String { "session:\(Auth.sha256Hex(id))" }
}

/// A session value with its type, so a `Double` such as `2.0` doesn't come
/// back as an `Int`.
enum SessionValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([SessionValue])
    case object([String: SessionValue])

    /// The JSON-compatible form of `value`, or `nil` for a `nil` optional,
    /// which removes the key.
    init?(_ value: Any, key: String) throws {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first?.value else { return nil }
            try self.init(wrapped, key: key)
            return
        }
        switch value {
        case let value as String: self = .string(value)
        case let value as Bool: self = .bool(value)
        case let value as Int: self = .int(value)
        case let value as any BinaryInteger:
            guard let int = Int(exactly: value) else { throw Self.unsupported(value, key: key) }
            self = .int(int)
        case let value as Double where value.isFinite: self = .double(value)
        case let value as Float where value.isFinite: self = .double(Double(value))
        case let values as [Any]:
            self = .array(try values.map { try Self.element($0, key: key) })
        case let values as [String: Any]:
            self = .object(try values.mapValues { try Self.element($0, key: key) })
        default:
            throw Self.unsupported(value, key: key)
        }
    }

    /// An element of an array or dictionary, where `nil` isn't allowed.
    private static func element(_ value: Any, key: String) throws -> SessionValue {
        guard let element = try SessionValue(value, key: key) else { throw unsupported(value, key: key) }
        return element
    }

    var value: any Sendable {
        switch self {
        case .string(let value): value
        case .int(let value): value
        case .double(let value): value
        case .bool(let value): value
        case .array(let values): values.map(\.value)
        case .object(let values): values.mapValues(\.value)
        }
    }

    private static func unsupported(_ value: Any, key: String) -> KeyValueStoreError {
        KeyValueStoreError(.unencodable, """
            The session value under \(key) is a \(type(of: value)). Sessions in a key-value store \
            hold strings, numbers, booleans, and arrays and dictionaries of those.
            """)
    }

    // Encoded as a one-key object naming the type, such as {"d":2.0}.
    private enum CodingKeys: String, CodingKey {
        case string = "s", int = "i", double = "d", bool = "b", array = "a", object = "o"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = container.allKeys.first, container.allKeys.count == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected one type key"))
        }
        switch key {
        case .string: self = .string(try container.decode(String.self, forKey: key))
        case .int: self = .int(try container.decode(Int.self, forKey: key))
        case .double: self = .double(try container.decode(Double.self, forKey: key))
        case .bool: self = .bool(try container.decode(Bool.self, forKey: key))
        case .array: self = .array(try container.decode([SessionValue].self, forKey: key))
        case .object: self = .object(try container.decode([String: SessionValue].self, forKey: key))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let value): try container.encode(value, forKey: .string)
        case .int(let value): try container.encode(value, forKey: .int)
        case .double(let value): try container.encode(value, forKey: .double)
        case .bool(let value): try container.encode(value, forKey: .bool)
        case .array(let values): try container.encode(values, forKey: .array)
        case .object(let values): try container.encode(values, forKey: .object)
        }
    }
}

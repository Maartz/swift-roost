import Foundation
import Nexus

/// A store of encoded values by key, such as Valkey or this process's memory.
///
/// Read and write it through typed ``StoreKey``s, from a request with
/// ``Nexus/Connection/store``:
///
/// ```swift
/// extension StoreKey where Value == Draft {
///     static func draft(_ userID: UUID) -> Self { .init("draft:\(userID)", expiringAfter: .seconds(3600)) }
/// }
///
/// try await conn.store.set(.draft(user.id), to: draft)
/// let saved = try await conn.store.get(.draft(user.id))  // Draft?
/// ```
///
/// Contexts take `any KeyValueStore`, as they take `any Repo`, so a test can
/// pass a ``MemoryKeyValueStore``. Choose the app's store with
/// ``RoostApp/store``.
///
/// Conform to the protocol to add a backend. Its four requirements work on
/// encoded bytes; the typed methods encode values as JSON for every backend.
/// A backend that also conforms to `Service` runs with the server.
public protocol KeyValueStore: Sendable {
    /// The bytes stored under `key`, or `nil` when there are none or they expired.
    func get(_ key: String) async throws -> Data?

    /// Stores `value` under `key`. Without an expiry the value is kept until
    /// it's removed, replacing any earlier expiry.
    func set(_ key: String, to value: Data, expiringAfter expiry: Duration?) async throws

    /// Removes the value stored under `key`, if any.
    func remove(_ key: String) async throws

    /// Atomically adds `amount` to the integer stored under `key`, starting
    /// from zero, and returns the result. When this creates the key, the key
    /// expires after `expiry`; later increments keep that expiry.
    ///
    /// The integer is stored as decimal text, which is also how a typed
    /// `StoreKey<Int>` encodes it. The default implementation throws
    /// ``KeyValueStoreError/Kind/unsupported``.
    func increment(_ key: String, by amount: Int, expiringAfter expiry: Duration?) async throws -> Int
}

extension KeyValueStore {
    public func increment(_ key: String, by amount: Int, expiringAfter expiry: Duration?) async throws -> Int {
        throw KeyValueStoreError(.unsupported, "\(type(of: self)) can't increment values atomically")
    }
}

// MARK: - Typed keys

/// A key in a ``KeyValueStore``, with the type of its value and how long the
/// value is kept.
///
/// Declare keys as static members so every caller uses the same name, type,
/// and expiry:
///
/// ```swift
/// extension StoreKey where Value == Int {
///     static func pageViews(_ pageID: UUID) -> Self { .init("views:\(pageID)") }
/// }
/// ```
public struct StoreKey<Value: Codable & Sendable>: Sendable, Hashable {
    /// The key's name in the store.
    public let name: String

    /// How long a value is kept after it's set, or `nil` to keep it until removed.
    public let expiry: Duration?

    public init(_ name: String, expiringAfter expiry: Duration? = nil) {
        self.name = name
        self.expiry = expiry
    }
}

extension KeyValueStore {
    /// The value stored under `key`, or `nil` when there is none or it expired.
    ///
    /// - Throws: ``KeyValueStoreError/Kind/undecodable`` when the stored value
    ///   isn't a `Value`, for example after the type changed.
    public func get<Value>(_ key: StoreKey<Value>) async throws -> Value? {
        guard let data = try await get(key.name) else { return nil }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw KeyValueStoreError(.undecodable, "The value under \(key.name) isn't a \(Value.self): \(error)")
        }
    }

    /// Stores `value` under `key`, for the key's expiry.
    ///
    /// - Throws: ``KeyValueStoreError/Kind/unencodable`` when `value` can't be
    ///   encoded as JSON, such as a `Double.nan`.
    public func set<Value>(_ key: StoreKey<Value>, to value: Value) async throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            throw KeyValueStoreError(.unencodable, "A \(Value.self) for \(key.name) can't be encoded: \(error)")
        }
        try await set(key.name, to: data, expiringAfter: key.expiry)
    }

    /// Removes the value stored under `key`, if any.
    public func remove<Value>(_ key: StoreKey<Value>) async throws {
        try await remove(key.name)
    }

    /// The value stored under `key`, or the result of `compute`, which is then
    /// stored for the key's expiry.
    ///
    /// ```swift
    /// let forecast = try await conn.store.fetch(.forecast(city)) {
    ///     try await weather.forecast(for: city)
    /// }
    /// ```
    ///
    /// A stored value that can't be decoded as `Value` counts as missing, so a
    /// cached value from an earlier version of the type is replaced.
    public func fetch<Value>(_ key: StoreKey<Value>, compute: () async throws -> Value) async throws -> Value {
        do {
            if let cached = try await get(key) { return cached }
        } catch let error as KeyValueStoreError where error.kind == .undecodable {}
        let value = try await compute()
        try await set(key, to: value)
        return value
    }

    /// Atomically adds `amount` to the counter under `key` and returns the
    /// result. A new counter starts from zero and expires after the key's
    /// expiry.
    @discardableResult
    public func increment(_ key: StoreKey<Int>, by amount: Int = 1) async throws -> Int {
        try await increment(key.name, by: amount, expiringAfter: key.expiry)
    }
}

// MARK: - Errors

/// A ``KeyValueStore`` operation that failed.
public struct KeyValueStoreError: Error, Sendable, CustomStringConvertible {
    public enum Kind: Sendable, Hashable {
        /// A stored value isn't the type its key expects.
        case undecodable
        /// A value can't be encoded for storage.
        case unencodable
        /// The store can't perform the operation, such as an atomic increment.
        case unsupported
        /// An increment would go past `Int.max` or `Int.min`.
        case overflow
        /// The store's configuration is invalid, such as a malformed URL.
        case misconfigured
        /// The store's server failed or couldn't be reached.
        case unavailable
    }

    public let kind: Kind
    public let description: String

    public init(_ kind: Kind, _ description: String) {
        self.kind = kind
        self.description = description
    }
}

// MARK: - Connection

/// The store behind ``Nexus/Connection/store``. Roost and `TestApp` assign
/// it; assign one yourself to test a plug on a connection you build:
///
/// ```swift
/// let conn = TestConnection.build().assign(KeyValueStoreKey.self, value: MemoryKeyValueStore())
/// ```
public enum KeyValueStoreKey: AssignKey {
    public typealias Value = any KeyValueStore
}

extension Connection {
    /// The app's key-value store, chosen with ``RoostApp/store``.
    ///
    /// ```swift
    /// let views = try await conn.store.increment(.pageViews(page.id))
    /// ```
    ///
    /// `TestApp` gives each test app its own ``MemoryKeyValueStore``.
    ///
    /// - Throws: ``KeyValueStoreError/Kind/misconfigured`` for a connection
    ///   that didn't come through a Roost app or `TestApp`, such as one a
    ///   plug's unit test builds, until ``KeyValueStoreKey`` is assigned.
    public var store: any KeyValueStore {
        get throws {
            guard let store = self[KeyValueStoreKey.self] else {
                throw KeyValueStoreError(.misconfigured, """
                    This connection has no key-value store. RoostApp and TestApp set conn.store; \
                    on a connection built another way, assign one: \
                    conn.assign(KeyValueStoreKey.self, value: MemoryKeyValueStore())
                    """)
            }
            return store
        }
    }
}

/// The app's store while Roost handles a request, for code that has no
/// connection, such as a ``KeyValueSessionStore`` installed with `session(store:)`.
enum RequestKeyValueStore {
    @TaskLocal static var current: (any KeyValueStore)?
}

// MARK: - Namespacing

/// Prefixes every key, so apps and environments can share one server.
struct NamespacedStore: KeyValueStore {
    let base: any KeyValueStore
    let prefix: String

    func get(_ key: String) async throws -> Data? {
        try await base.get(prefix + key)
    }

    func set(_ key: String, to value: Data, expiringAfter expiry: Duration?) async throws {
        try await base.set(prefix + key, to: value, expiringAfter: expiry)
    }

    func remove(_ key: String) async throws {
        try await base.remove(prefix + key)
    }

    func increment(_ key: String, by amount: Int, expiringAfter expiry: Duration?) async throws -> Int {
        try await base.increment(prefix + key, by: amount, expiringAfter: expiry)
    }
}

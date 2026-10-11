import Foundation
import Hummingbird
import Logging
import ServiceLifecycle

/// Where ``Nexus/Connection/store`` keeps its values. Set it with ``RoostApp/store``.
///
/// The default, ``environment``, reads `ROOST_STORE_URL` and falls back to
/// memory, so an app needs no code to move to Valkey in production:
///
/// ```sh
/// ROOST_STORE_URL=valkey://:password@cache.internal:6379 .build/release/App
/// ```
///
/// Roost prefixes every key with the app and environment, such as
/// `ReadingRoom:prod:`, so apps and environments can share a server. Choose a
/// different prefix with ``namespaced(_:)``.
public struct StoreConfiguration: Sendable {
    enum Backend: Sendable {
        case environment
        case memory
        case valkey(String)
        case custom(any KeyValueStore)
    }

    let backend: Backend
    let namespace: String?

    /// `ROOST_STORE_URL` when it's set, otherwise a store in memory. The default.
    ///
    /// In production, the first use of that memory store logs a warning,
    /// because its values are lost on restart and aren't shared between
    /// servers.
    public static var environment: StoreConfiguration { .init(backend: .environment, namespace: nil) }

    /// A ``MemoryKeyValueStore``, for an app that runs as a single process.
    /// Unlike the memory fallback of ``environment``, it doesn't warn in production.
    public static var memory: StoreConfiguration { .init(backend: .memory, namespace: nil) }

    /// A Valkey or Redis server: `valkey://[user[:password]@]host[:port][/database]`,
    /// or `valkeys://` for TLS.
    ///
    /// Needs Roost's `Valkey` trait, and macOS 15 or later when running on macOS:
    ///
    /// ```swift
    /// .package(url: "https://github.com/roost-framework/swift-roost", from: "2.3.0",
    ///          traits: [.defaults, "Valkey"])
    /// ```
    ///
    /// While the server is unreachable, requests that use the store fail
    /// after two seconds, then immediately, and recover once it's back.
    public static func valkey(url: String) -> StoreConfiguration {
        .init(backend: .valkey(url), namespace: nil)
    }

    /// Your own ``KeyValueStore``. A store that conforms to `Service` runs
    /// with the server.
    public static func custom(_ store: some KeyValueStore) -> StoreConfiguration {
        .init(backend: .custom(store), namespace: nil)
    }

    /// A Hummingbird `PersistDriver`, such as `RedisPersistDriver` or
    /// `PostgresPersistDriver`, run with the server.
    ///
    /// Values keep the driver's semantics. Drivers can't increment atomically,
    /// so ``KeyValueStore/increment(_:by:expiringAfter:)`` throws.
    public static func persist(_ driver: some PersistDriver) -> StoreConfiguration {
        .init(backend: .custom(PersistDriverStore(driver: driver)), namespace: nil)
    }

    /// This configuration with every key prefixed by `namespace` instead of
    /// the app and environment.
    public func namespaced(_ namespace: String) -> StoreConfiguration {
        .init(backend: backend, namespace: namespace)
    }
}

// MARK: - Resolution

/// The app's store and the services that must run for it.
struct ResolvedStore {
    let store: any KeyValueStore
    let services: [any Service]
}

extension StoreConfiguration {
    /// Builds the store at startup, before the server accepts requests.
    ///
    /// - Throws: ``KeyValueStoreError/Kind/misconfigured`` for an invalid URL,
    ///   or a Valkey store without the `Valkey` trait or on macOS 14.
    func resolve(
        app: String,
        environment: Environment,
        variables: [String: String] = ProcessInfo.processInfo.environment,
        logger: Logger = Logger(label: "roost.store")
    ) throws -> ResolvedStore {
        let resolved: ResolvedStore
        switch backend {
        case .environment:
            if let url = variables["ROOST_STORE_URL"], !url.isEmpty {
                resolved = try Self.valkey(url, logger: logger)
            } else if environment == .prod {
                resolved = ResolvedStore(store: ProductionMemoryStore(logger: logger), services: [])
            } else {
                resolved = ResolvedStore(store: MemoryKeyValueStore(), services: [])
            }
        case .memory:
            resolved = ResolvedStore(store: MemoryKeyValueStore(), services: [])
        case .valkey(let url):
            resolved = try Self.valkey(url, logger: logger)
        case .custom(let store):
            resolved = ResolvedStore(store: store, services: (store as? any Service).map { [$0] } ?? [])
        }
        let prefix = namespace ?? "\(app):\(environment.rawValue):"
        return ResolvedStore(store: NamespacedStore(base: resolved.store, prefix: prefix), services: resolved.services)
    }

    private static func valkey(_ string: String, logger: Logger) throws -> ResolvedStore {
        let url = try ValkeyURL(string)
        #if Valkey
        if #available(macOS 15, *) {
            let store = try ValkeyKeyValueStore(url: url, logger: logger)
            return ResolvedStore(store: store, services: [store.client])
        }
        throw KeyValueStoreError(.misconfigured, "A Valkey store needs macOS 15 or later")
        #else
        _ = url
        throw KeyValueStoreError(.misconfigured, """
            A Valkey store needs Roost's Valkey trait. Add it to the swift-roost dependency: \
            traits: [.defaults, "Valkey"]
            """)
        #endif
    }
}

/// The memory fallback in production: warns once, on first use, that values
/// live in one process.
actor ProductionMemoryStore: KeyValueStore {
    private let base = MemoryKeyValueStore()
    private let logger: Logger
    private var warned = false

    init(logger: Logger) { self.logger = logger }

    func get(_ key: String) async throws -> Data? {
        warnOnce()
        return try await base.get(key)
    }

    func set(_ key: String, to value: Data, expiringAfter expiry: Duration?) async throws {
        warnOnce()
        try await base.set(key, to: value, expiringAfter: expiry)
    }

    func remove(_ key: String) async throws {
        warnOnce()
        try await base.remove(key)
    }

    func increment(_ key: String, by amount: Int, expiringAfter expiry: Duration?) async throws -> Int {
        warnOnce()
        return try await base.increment(key, by: amount, expiringAfter: expiry)
    }

    private func warnOnce() {
        guard !warned else { return }
        warned = true
        logger.warning("""
            conn.store is keeping values in memory in production: they're lost on restart and \
            aren't shared between servers. Set ROOST_STORE_URL, or declare \
            `var store: StoreConfiguration { .memory }` to keep a single-process store.
            """)
    }
}

/// A Hummingbird `PersistDriver` as a ``KeyValueStore``.
struct PersistDriverStore<Driver: PersistDriver>: KeyValueStore, Service {
    let driver: Driver

    func get(_ key: String) async throws -> Data? {
        try await driver.get(key: key, as: Data.self)
    }

    func set(_ key: String, to value: Data, expiringAfter expiry: Duration?) async throws {
        try await driver.set(key: key, value: value, expires: expiry)
    }

    func remove(_ key: String) async throws {
        try await driver.remove(key: key)
    }

    func run() async throws {
        try await driver.run()
    }
}

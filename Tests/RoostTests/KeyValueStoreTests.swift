import Foundation
import Hummingbird
import Logging
import Nexus
import NexusRouter
import ServiceLifecycle
import Testing

@testable import Roost
@testable import RoostTest

// MARK: - Fixtures

private struct Draft: Codable, Sendable, Equatable {
    let title: String
    let words: Int
}

extension StoreKey where Value == Int {
    fileprivate static var visits: Self { .init("visits") }
}

/// A clock the test moves forward.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = ContinuousClock.now

    var now: ContinuousClock.Instant { lock.withLock { current } }
    func advance(_ duration: Duration) { lock.withLock { current += duration } }
}

private final class LogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [String] = []
    var messages: [String] { lock.withLock { _messages } }
    func append(_ message: String) { lock.withLock { _messages.append(message) } }

    var logger: Logger { Logger(label: "test") { _ in CaptureHandler(capture: self) } }
}

private struct CaptureHandler: LogHandler {
    let capture: LogCapture
    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) { capture.append("\(event.message)") }
}

private func kind(_ expected: KeyValueStoreError.Kind) -> @Sendable (any Error) -> Bool {
    { ($0 as? KeyValueStoreError)?.kind == expected }
}

/// Counts how often a computation runs.
private actor Calls {
    var count = 0
    func record() { count += 1 }
}

// MARK: - Backends

/// The stores every conformance test runs against: memory always, and Valkey
/// with the `Valkey` trait when `VALKEY_URL` names a server.
enum StoreBackend: String, Sendable, CaseIterable, CustomTestStringConvertible {
    case memory, valkey

    static var available: [StoreBackend] {
        valkeyURL == nil ? [.memory] : allCases
    }

    static var valkeyURL: String? {
        #if Valkey
        ProcessInfo.processInfo.environment["VALKEY_URL"]
        #else
        nil
        #endif
    }

    var testDescription: String { rawValue }

    /// Runs `body` with a store whose keys no other test uses.
    func withStore(_ body: (any KeyValueStore) async throws -> Void) async throws {
        let prefix = "roost-test:\(UUID().uuidString):"
        switch self {
        case .memory:
            try await body(NamespacedStore(base: MemoryKeyValueStore(), prefix: prefix))
        case .valkey:
            #if Valkey
            guard #available(macOS 15, *), let url = Self.valkeyURL else { return }
            let store = try ValkeyKeyValueStore(url: ValkeyURL(url), logger: Logger(label: "test.valkey"))
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { await store.client.run() }
                defer { group.cancelAll() }
                try await body(NamespacedStore(base: store, prefix: prefix))
            }
            #endif
        }
    }
}

// MARK: - Conformance

@Suite("Key-value store conformance")
struct KeyValueStoreConformanceTests {

    @Test("Values round-trip, are replaced, and are removed", arguments: StoreBackend.available)
    func roundTrip(backend: StoreBackend) async throws {
        try await backend.withStore { store in
            #expect(try await store.get("missing") == nil)
            try await store.set("key", to: Data("one".utf8), expiringAfter: nil)
            #expect(try await store.get("key") == Data("one".utf8))
            try await store.set("key", to: Data("two".utf8), expiringAfter: nil)
            #expect(try await store.get("key") == Data("two".utf8))
            try await store.remove("key")
            #expect(try await store.get("key") == nil)
            try await store.remove("key")
        }
    }

    @Test("A value expires, and setting it again without an expiry keeps it", arguments: StoreBackend.available)
    func expiry(backend: StoreBackend) async throws {
        try await backend.withStore { store in
            try await store.set("brief", to: Data("x".utf8), expiringAfter: .milliseconds(300))
            try await store.set("kept", to: Data("x".utf8), expiringAfter: .milliseconds(300))
            try await store.set("kept", to: Data("y".utf8), expiringAfter: nil)
            #expect(try await store.get("brief") != nil)
            try await Task.sleep(for: .milliseconds(700))
            #expect(try await store.get("brief") == nil)
            #expect(try await store.get("kept") == Data("y".utf8))
        }
    }

    @Test("Counters start at zero, add atomically, and keep their first expiry", arguments: StoreBackend.available)
    func counters(backend: StoreBackend) async throws {
        try await backend.withStore { store in
            #expect(try await store.increment("count", by: 1, expiringAfter: nil) == 1)
            #expect(try await store.increment("count", by: 5, expiringAfter: nil) == 6)
            try await withThrowingTaskGroup(of: Int.self) { group in
                for _ in 0..<100 { group.addTask { try await store.increment("count", by: 1, expiringAfter: nil) } }
                for try await _ in group {}
            }
            #expect(try await store.increment("count", by: 0, expiringAfter: nil) == 106)

            #expect(try await store.increment("window", by: 1, expiringAfter: .milliseconds(400)) == 1)
            try await Task.sleep(for: .milliseconds(250))
            // A later increment doesn't restart the window.
            #expect(try await store.increment("window", by: 1, expiringAfter: .milliseconds(400)) == 2)
            try await Task.sleep(for: .milliseconds(300))
            #expect(try await store.get("window") == nil)
        }
    }

    @Test("Incrementing a value that isn't an integer is undecodable", arguments: StoreBackend.available)
    func incrementText(backend: StoreBackend) async throws {
        try await backend.withStore { store in
            try await store.set("text", to: Data("hello".utf8), expiringAfter: nil)
            await #expect(performing: { try await store.increment("text", by: 1, expiringAfter: nil) },
                          throws: kind(.undecodable))
        }
    }

    @Test("Typed keys store JSON, and a counter reads as an Int", arguments: StoreBackend.available)
    func typedKeys(backend: StoreBackend) async throws {
        try await backend.withStore { store in
            let draft = StoreKey<Draft>("draft", expiringAfter: .seconds(60))
            try await store.set(draft, to: Draft(title: "Plan", words: 3))
            #expect(try await store.get(draft) == Draft(title: "Plan", words: 3))
            let stored = try #require(try await store.get("draft"))
            #expect(try JSONDecoder().decode(Draft.self, from: stored) == Draft(title: "Plan", words: 3))

            try await store.increment(.visits)
            try await store.increment(.visits, by: 2)
            #expect(try await store.get(.visits) == 3)
            try await store.remove(draft)
            #expect(try await store.get(draft) == nil)
        }
    }

    @Test("fetch computes a missing value once, and replaces one of another type", arguments: StoreBackend.available)
    func fetch(backend: StoreBackend) async throws {
        try await backend.withStore { store in
            let calls = Calls()
            let key = StoreKey<Draft>("cached")
            for _ in 0..<3 {
                let draft = try await store.fetch(key) {
                    await calls.record()
                    return Draft(title: "Computed", words: 1)
                }
                #expect(draft.title == "Computed")
            }
            #expect(await calls.count == 1)

            try await store.set(key.name, to: Data("an older format".utf8), expiringAfter: nil)
            _ = try await store.fetch(key) { await calls.record(); return Draft(title: "New", words: 2) }
            #expect(try await store.get(key)?.title == "New")
            #expect(await calls.count == 2)
        }
    }

    @Test("Sessions round-trip with their value types", arguments: StoreBackend.available)
    func sessions(backend: StoreBackend) async throws {
        try await backend.withStore { store in
            let sessions = KeyValueSessionStore(store)
            try await sessions.set("abc", data: ["user": "u1", "step": 2, "ratio": 2.0, "admin": false], ttl: .seconds(60))
            let data = try #require(try await sessions.get("abc"))
            #expect(data["user"] as? String == "u1")
            #expect(data["step"] as? Int == 2)
            #expect(data["ratio"] as? Double == 2.0)
            #expect(data["admin"] as? Bool == false)
            try await sessions.delete("abc")
            #expect(try await sessions.get("abc") == nil)
        }
    }
}

// MARK: - Memory store

@Suite("Memory key-value store")
struct MemoryKeyValueStoreTests {

    @Test("Values and counters expire by the store's clock")
    func clock() async throws {
        let clock = ManualClock()
        let store = MemoryKeyValueStore(now: { clock.now })
        await store.set("key", to: Data("x".utf8), expiringAfter: .seconds(10))
        _ = try await store.increment("count", by: 1, expiringAfter: .seconds(10))
        clock.advance(.seconds(9))
        #expect(await store.get("key") != nil)
        #expect(try await store.increment("count", by: 1, expiringAfter: .seconds(10)) == 2)
        clock.advance(.seconds(1))
        #expect(await store.get("key") == nil)
        #expect(try await store.increment("count", by: 1, expiringAfter: nil) == 1)
    }

    @Test("Expired values are swept even if nobody reads them")
    func sweep() async throws {
        let clock = ManualClock()
        let store = MemoryKeyValueStore(now: { clock.now })
        for index in 0..<(MemoryKeyValueStore.sweepInterval - 1) {
            await store.set("key\(index)", to: Data(), expiringAfter: .seconds(1))
        }
        clock.advance(.seconds(2))
        await store.set("fresh", to: Data(), expiringAfter: nil)
        #expect(await store.count == 1)
    }

    @Test("A counter that would overflow throws instead of wrapping")
    func overflow() async throws {
        let store = MemoryKeyValueStore()
        _ = try await store.increment("count", by: .max, expiringAfter: nil)
        await #expect(performing: { try await store.increment("count", by: 1, expiringAfter: nil) },
                      throws: kind(.unsupported))
    }

    @Test("A value JSON can't encode is rejected before it's stored")
    func unencodable() async throws {
        let store = MemoryKeyValueStore()
        let key = StoreKey<Double>("ratio")
        await #expect(performing: { try await store.set(key, to: .nan) }, throws: kind(.unencodable))
        #expect(await store.get("ratio") == nil)
    }

    @Test("A stored value of another type is undecodable")
    func undecodable() async throws {
        let store = MemoryKeyValueStore()
        await store.set("visits", to: Data("lots".utf8), expiringAfter: nil)
        await #expect(performing: { try await store.get(.visits) }, throws: kind(.undecodable))
    }

    @Test("A namespace prefixes every key")
    func namespace() async throws {
        let base = MemoryKeyValueStore()
        let store = NamespacedStore(base: base, prefix: "App:dev:")
        try await store.set(.visits, to: 4)
        _ = try await store.increment("count", by: 1, expiringAfter: nil)
        #expect(await base.get("App:dev:visits") == Data("4".utf8))
        #expect(await base.get("App:dev:count") == Data("1".utf8))
        #expect(await base.get("visits") == nil)
    }
}

// MARK: - Configuration

@Suite("Store configuration")
struct StoreConfigurationTests {

    @Test("Valkey URLs name the host, port, credentials, database, and TLS", arguments: [
        ("valkey://localhost", ValkeyURL.Fields(host: "localhost", port: 6379, username: nil, password: nil, database: 0, tls: false)),
        ("valkeys://cache.internal:6380/2", .init(host: "cache.internal", port: 6380, username: nil, password: nil, database: 2, tls: true)),
        ("redis://:s%40cret@10.0.0.5", .init(host: "10.0.0.5", port: 6379, username: nil, password: "s@cret", database: 0, tls: false)),
        ("rediss://app:pw@host:7000/", .init(host: "host", port: 7000, username: "app", password: "pw", database: 0, tls: true)),
        ("valkey://:100%25@host", .init(host: "host", port: 6379, username: nil, password: "100%", database: 0, tls: false)),
    ])
    func validURLs(string: String, expected: ValkeyURL.Fields) throws {
        #expect(try ValkeyURL(string).fields == expected)
    }

    @Test("Invalid store URLs are configuration errors", arguments: [
        "http://localhost", "valkey://", "valkey://host/cache", "localhost:6379",
    ])
    func invalidURLs(string: String) {
        #expect(throws: KeyValueStoreError.self) { try ValkeyURL(string) }
    }

    @Test("Error messages hide the URL's password")
    func redaction() {
        #expect(ValkeyURL.redacted("valkey://app:secret@host") == "valkey://app:***@host")
        #expect {
            try ValkeyURL("http://app:secret@host")
        } throws: { error in
            !"\(error)".contains("secret")
        }
    }

    @Test("Without ROOST_STORE_URL, development uses memory under the app and environment")
    func developmentDefault() async throws {
        let resolved = try StoreConfiguration.environment.resolve(app: "ReadingRoom", environment: .dev, variables: [:])
        let store = try #require(resolved.store as? NamespacedStore)
        #expect(store.base is MemoryKeyValueStore)
        #expect(store.prefix == "ReadingRoom:dev:")
        #expect(resolved.services.isEmpty)
    }

    @Test("Production warns once about the implicit memory store, but not about a declared one")
    func productionWarning() async throws {
        let capture = LogCapture()
        let implicit = try StoreConfiguration.environment
            .resolve(app: "ReadingRoom", environment: .prod, variables: [:], logger: capture.logger).store
        #expect(capture.messages.isEmpty)
        try await implicit.set(.visits, to: 1)
        _ = try await implicit.get(.visits)
        #expect(capture.messages.count == 1)
        #expect(capture.messages.first?.contains("ROOST_STORE_URL") == true)

        let declared = LogCapture()
        let memory = try StoreConfiguration.memory
            .resolve(app: "ReadingRoom", environment: .prod, variables: [:], logger: declared.logger).store
        try await memory.set(.visits, to: 1)
        #expect(declared.messages.isEmpty)
    }

    @Test("A namespace replaces the app and environment prefix")
    func namespace() throws {
        let resolved = try StoreConfiguration.memory.namespaced("shared:").resolve(app: "App", environment: .prod)
        #expect((resolved.store as? NamespacedStore)?.prefix == "shared:")
    }

    #if Valkey
    @Test("ROOST_STORE_URL selects Valkey, which runs as a service")
    func valkeyFromEnvironment() throws {
        guard #available(macOS 15, *) else { return }
        let resolved = try StoreConfiguration.environment
            .resolve(app: "App", environment: .prod, variables: ["ROOST_STORE_URL": "valkey://localhost:6390"])
        #expect((resolved.store as? NamespacedStore)?.base is ValkeyKeyValueStore)
        #expect(resolved.services.count == 1)
    }
    #else
    @Test("Without the Valkey trait, a Valkey URL stops the app with the fix")
    func valkeyWithoutTrait() {
        #expect {
            try StoreConfiguration.environment
                .resolve(app: "App", environment: .prod, variables: ["ROOST_STORE_URL": "valkey://localhost"])
        } throws: { error in
            let error = error as? KeyValueStoreError
            return error?.kind == .misconfigured && error?.description.contains("\"Valkey\"") == true
        }
    }
    #endif

    @Test("A custom store that is a Service runs with the server")
    func customService() throws {
        struct ServiceStore: KeyValueStore, Service {
            func get(_ key: String) async throws -> Data? { nil }
            func set(_ key: String, to value: Data, expiringAfter expiry: Duration?) async throws {}
            func remove(_ key: String) async throws {}
            func run() async throws {}
        }
        #expect(try StoreConfiguration.custom(ServiceStore()).resolve(app: "App", environment: .dev).services.count == 1)
        #expect(try StoreConfiguration.custom(MemoryKeyValueStore()).resolve(app: "App", environment: .dev).services.isEmpty)
    }

    @Test("A Hummingbird persist driver works as a store, without atomic counters")
    func persistDriver() async throws {
        let resolved = try StoreConfiguration.persist(MemoryPersistDriver()).resolve(app: "App", environment: .dev)
        #expect(resolved.services.count == 1)
        let store = resolved.store
        try await store.set(StoreKey<Draft>("draft"), to: Draft(title: "Plan", words: 3))
        #expect(try await store.get(StoreKey<Draft>("draft")) == Draft(title: "Plan", words: 3))
        await #expect(performing: { try await store.increment(.visits) }, throws: kind(.unsupported))
    }
}

extension ValkeyURL {
    /// The parsed fields, for comparing with expected values.
    struct Fields: Equatable, Sendable {
        let host: String, port: Int, username: String?, password: String?, database: Int, tls: Bool
    }

    var fields: Fields {
        Fields(host: host, port: port, username: username, password: password, database: database, tls: tls)
    }
}

// MARK: - Sessions

@Suite("Key-value session store")
struct KeyValueSessionStoreTests {

    @Test("Nested values, optionals, and integer widths round-trip")
    func values() async throws {
        let sessions = KeyValueSessionStore(MemoryKeyValueStore())
        let maybe: String? = "here"
        let none: String? = nil
        try await sessions.set("id", data: [
            "tags": ["a", "b"], "counts": ["x": 1], "nested": ["list": [1.5, 2.5]],
            "maybe": maybe, "none": none, "small": Int16(7),
        ], ttl: nil)
        let data = try #require(try await sessions.get("id"))
        #expect(data["tags"] as? [String] == ["a", "b"])
        #expect(data["counts"] as? [String: Int] == ["x": 1])
        #expect((data["nested"] as? [String: Any])?["list"] as? [Double] == [1.5, 2.5])
        #expect(data["maybe"] as? String == "here")
        #expect(data["none"] == nil)
        #expect(data["small"] as? Int == 7)
    }

    @Test("A value that isn't JSON-compatible is rejected with its key")
    func unsupported() async throws {
        let sessions = KeyValueSessionStore(MemoryKeyValueStore())
        await #expect {
            try await sessions.set("id", data: ["userID": UUID()], ttl: nil)
        } throws: { error in
            let error = error as? KeyValueStoreError
            return error?.kind == .unencodable && error?.description.contains("userID") == true
        }
    }

    @Test("Sessions expire after their TTL")
    func ttl() async throws {
        let clock = ManualClock()
        let sessions = KeyValueSessionStore(MemoryKeyValueStore(now: { clock.now }))
        try await sessions.set("id", data: ["user": "u1"], ttl: .seconds(60))
        clock.advance(.seconds(61))
        #expect(try await sessions.get("id") == nil)
    }

    @Test("A session in another format reads as expired")
    func corrupted() async throws {
        let store = MemoryKeyValueStore()
        await store.set("session:id", to: Data("{not json".utf8), expiringAfter: nil)
        #expect(try await KeyValueSessionStore(store).get("id") == nil)
    }

    @Test("Outside an app, a session store without a store says how to give it one")
    func unbound() async {
        await #expect(performing: { try await KeyValueSessionStore().get("id") }, throws: kind(.misconfigured))
    }
}

// MARK: - Requests

private struct CounterApp: RoostApp {
    @RouteBuilder var routes: [Route] {
        POST("/visits") { conn in
            try conn.json(value: ["count": try await conn.store.increment(.visits)])
        }
    }
}

private struct StoreSessionApp: RoostApp {
    let sessionStore: (any SessionStore)? = KeyValueSessionStore()

    @RouteBuilder var routes: [Route] {
        POST("/step") { conn in conn.putSessionValue("step", 2.5).text("saved") }
        GET("/step") { conn in conn.text("\(conn.sessionValue("step") ?? "none")") }
    }
}

@Suite("Key-value store in requests")
struct KeyValueStoreRequestTests {

    @Test("conn.store is the test app's own store")
    func connectionStore() async throws {
        let app = try await TestApp(CounterApp.self)
        #expect(try await app.post("/visits", json: [String: String]()).json["count"] as? Int == 1)
        #expect(try await app.post("/visits", json: [String: String]()).json["count"] as? Int == 2)
        #expect(try await app.store.get(.visits) == 2)

        let other = try await TestApp(CounterApp.self)
        #expect(try await other.post("/visits", json: [String: String]()).json["count"] as? Int == 1)
    }

    @Test("A test app can share a store it was given")
    func injectedStore() async throws {
        let store = MemoryKeyValueStore()
        try await store.set(.visits, to: 41)
        let app = try await TestApp(CounterApp.self, store: store)
        #expect(try await app.post("/visits", json: [String: String]()).json["count"] as? Int == 42)
    }

    #if Valkey
    @Test("On Valkey, sessions survive a restart",
          .enabled(if: StoreBackend.valkeyURL != nil))
    func survivesRestart() async throws {
        guard #available(macOS 15, *), let url = StoreBackend.valkeyURL else { return }
        let namespace = "roost-test:\(UUID().uuidString):"
        // Each run resolves the store as RoostApp.main() does and runs its client.
        func run<T: Sendable>(_ body: @Sendable (TestApp<StoreSessionApp>) async throws -> T) async throws -> T {
            let resolved = try StoreConfiguration.valkey(url: url).namespaced(namespace)
                .resolve(app: "StoreSessionApp", environment: .test)
            return try await withThrowingTaskGroup(of: T?.self) { group in
                for service in resolved.services { group.addTask { try await service.run(); return nil } }
                defer { group.cancelAll() }
                return try await body(TestApp(StoreSessionApp.self, store: resolved.store))
            }
        }
        let id = try await run { app in
            try #require(try await app.request(method: .post, path: "/step").cookies["_roost_session"])
        }
        let step = try await run { app in
            try await app.get("/step", headers: ["Cookie": "_roost_session=\(id)"]).text
        }
        #expect(step == "2.5")
    }
    #endif

    @Test("KeyValueSessionStore() keeps sessions in the app's store")
    func sessionsInStore() async throws {
        let app = try await TestApp(StoreSessionApp.self)
        let saved = try await app.request(method: .post, path: "/step")
        let id = try #require(saved.cookies["_roost_session"])
        #expect(try await app.store.get("session:\(id)") != nil)
        let read = try await app.get("/step", headers: ["Cookie": "_roost_session=\(id)"])
        #expect(read.text == "2.5")
    }
}

import Foundation
import HTTPTypes
import Logging
import Nexus
import NexusRouter
import NexusTest
import Testing

@testable import Roost
@testable import RoostTest

// MARK: - Helpers

private func buildConn(
    method: HTTPRequest.Method = .get,
    headers: [String: String] = [:],
    assigns: [String: String] = [:]
) -> Connection {
    var conn = TestConnection.build()
    conn.request.method = method
    for (name, value) in headers {
        if let fieldName = HTTPField.Name(name) {
            conn.request.headerFields[fieldName] = value
        }
    }
    for (key, value) in assigns {
        conn.assigns[key] = value
    }
    return conn
}

private func runRateLimitPlug(_ conn: Connection, plug: @escaping Plug) async throws -> Connection {
    try await plug(conn)
}

// MARK: - Tests

@Suite("Rate Limiting")
struct RateLimitPlugTests {

    // MARK: - Basic enforcement

    @Test("returns 429 when limit is exceeded")
    func returns429WhenExceeded() async throws {
        let plug = rateLimit(max: 2, windowSeconds: 60, by: .ip)

        let conn1 = buildConn(headers: ["X-Forwarded-For": "10.0.0.1"])
        let result1 = try await runRateLimitPlug(conn1, plug: plug)
        #expect(!result1.isHalted)

        let conn2 = buildConn(headers: ["X-Forwarded-For": "10.0.0.1"])
        let result2 = try await runRateLimitPlug(conn2, plug: plug)
        #expect(!result2.isHalted)

        let conn3 = buildConn(headers: ["X-Forwarded-For": "10.0.0.1"])
        let result3 = try await runRateLimitPlug(conn3, plug: plug)
        #expect(result3.response.status == .tooManyRequests)
        #expect(result3.isHalted)
    }

    // MARK: - Rate limit headers

    @Test("sets X-RateLimit-Limit, X-RateLimit-Remaining, and X-RateLimit-Reset on all responses")
    func setsRateLimitHeaders() async throws {
        let plug = rateLimit(max: 10, windowSeconds: 60, by: .ip)

        let conn = buildConn(headers: ["X-Forwarded-For": "192.168.1.1"])
        let result = try await runRateLimitPlug(conn, plug: plug)

        #expect(result.response.headerFields[.rateLimitLimitName] == "10")
        #expect(result.response.headerFields[.rateLimitRemainingName] == "9")
        #expect(result.response.headerFields[.rateLimitResetName] != nil)
    }

    // MARK: - Retry-After header

    @Test("sets Retry-After on 429 responses")
    func setsRetryAfter() async throws {
        let plug = rateLimit(max: 1, windowSeconds: 30, by: .ip)

        let conn1 = buildConn(headers: ["X-Forwarded-For": "172.16.0.1"])
        _ = try await runRateLimitPlug(conn1, plug: plug)

        let conn2 = buildConn(headers: ["X-Forwarded-For": "172.16.0.1"])
        let result = try await runRateLimitPlug(conn2, plug: plug)

        #expect(result.response.headerFields[.retryAfterName] != nil)
    }

    // MARK: - IP key extraction

    @Test("extracts IP from X-Forwarded-For")
    func extractsIPFromForwardedFor() async throws {
        let plug = rateLimit(max: 1, windowSeconds: 60)

        let conn = buildConn(headers: ["X-Forwarded-For": "10.0.0.1"])
        let result = try await runRateLimitPlug(conn, plug: plug)

        #expect(!result.isHalted)
        #expect(result.response.headerFields[.rateLimitRemainingName] == "0")
    }

    @Test("extracts IP from X-Real-IP when no X-Forwarded-For")
    func extractsIPFromRealIP() async throws {
        let plug = rateLimit(max: 1, windowSeconds: 60)

        let conn = buildConn(headers: ["X-Real-IP": "10.0.0.2"])
        let result = try await runRateLimitPlug(conn, plug: plug)

        #expect(!result.isHalted)
        #expect(result.response.headerFields[.rateLimitRemainingName] == "0")
    }

    @Test("X-Forwarded-For takes priority over X-Real-IP")
    func forwardedForPriority() async throws {
        let plug = rateLimit(max: 1, windowSeconds: 60)

        let conn1 = buildConn(
            headers: ["X-Forwarded-For": "10.0.0.1", "X-Real-IP": "10.0.0.2"]
        )
        _ = try await runRateLimitPlug(conn1, plug: plug)

        let conn2 = buildConn(
            headers: ["X-Forwarded-For": "10.0.0.1", "X-Real-IP": "10.0.0.2"]
        )
        let result2 = try await runRateLimitPlug(conn2, plug: plug)
        #expect(result2.response.status == .tooManyRequests)

        let conn3 = buildConn(
            headers: ["X-Forwarded-For": "10.0.0.3", "X-Real-IP": "10.0.0.2"]
        )
        let result3 = try await runRateLimitPlug(conn3, plug: plug)
        #expect(!result3.isHalted)
    }

    @Test("different IPs are tracked separately")
    func differentIPs() async throws {
        let plug = rateLimit(max: 1, windowSeconds: 60)

        let conn1 = buildConn(headers: ["X-Forwarded-For": "10.0.0.1"])
        _ = try await runRateLimitPlug(conn1, plug: plug)

        let conn2 = buildConn(headers: ["X-Forwarded-For": "10.0.0.2"])
        let result2 = try await runRateLimitPlug(conn2, plug: plug)
        #expect(!result2.isHalted)
    }

    // MARK: - Header key

    @Test("header key uses specified request header")
    func headerKey() async throws {
        let plug = rateLimit(max: 1, windowSeconds: 60, by: .header(.authorization))

        let conn1 = buildConn(headers: ["Authorization": "Bearer abc123"])
        _ = try await runRateLimitPlug(conn1, plug: plug)

        let conn2 = buildConn(headers: ["Authorization": "Bearer abc123"])
        let result2 = try await runRateLimitPlug(conn2, plug: plug)
        #expect(result2.response.status == .tooManyRequests)

        let conn3 = buildConn(headers: ["Authorization": "Bearer xyz789"])
        let result3 = try await runRateLimitPlug(conn3, plug: plug)
        #expect(!result3.isHalted)
    }

    // MARK: - Assign key

    @Test("assign key uses connection assigns")
    func assignKey() async throws {
        let plug = rateLimit(max: 1, windowSeconds: 60, by: .assign("user_id"))

        let conn1 = buildConn(assigns: ["user_id": "42"])
        _ = try await runRateLimitPlug(conn1, plug: plug)

        let conn2 = buildConn(assigns: ["user_id": "42"])
        let result2 = try await runRateLimitPlug(conn2, plug: plug)
        #expect(result2.response.status == .tooManyRequests)

        let conn3 = buildConn(assigns: ["user_id": "99"])
        let result3 = try await runRateLimitPlug(conn3, plug: plug)
        #expect(!result3.isHalted)
    }

    // MARK: - Custom key

    @Test("custom key allows arbitrary extraction")
    func customKey() async throws {
        let plug = rateLimit(
            max: 1,
            windowSeconds: 60,
            by: .custom { conn in
                conn.request.headerFields[.xAPIKeyName]
            }
        )

        let conn1 = buildConn(headers: ["X-API-Key": "key-1"])
        _ = try await runRateLimitPlug(conn1, plug: plug)

        let conn2 = buildConn(headers: ["X-API-Key": "key-1"])
        let result2 = try await runRateLimitPlug(conn2, plug: plug)
        #expect(result2.response.status == .tooManyRequests)
    }

    @Test("nil from custom key passes through without limiting")
    func nilCustomKey() async throws {
        let plug = rateLimit(
            max: 1,
            windowSeconds: 60,
            by: .custom { _ in nil }
        )

        for _ in 0..<10 {
            let result = try await runRateLimitPlug(buildConn(), plug: plug)
            #expect(!result.isHalted)
            #expect(result.response.status != .tooManyRequests)
        }
    }

    // MARK: - Content negotiation

    @Test("429 returns JSON for JSON requests")
    func json429() async throws {
        let plug = rateLimit(max: 1, windowSeconds: 60, by: .ip)

        let conn1 = buildConn(method: .post, headers: [
            "X-Forwarded-For": "10.0.0.5",
            "Content-Type": "application/json",
        ])
        _ = try await runRateLimitPlug(conn1, plug: plug)

        let conn2 = buildConn(method: .post, headers: [
            "X-Forwarded-For": "10.0.0.5",
            "Content-Type": "application/json",
            "Accept": "application/json",
        ])
        let result = try await runRateLimitPlug(conn2, plug: plug)
        #expect(result.response.headerFields[.contentType] == "application/json")
        if case .buffered(let data) = result.responseBody {
            let json = String(data: data, encoding: .utf8)
            #expect(json?.contains("error") == true)
        } else {
            Issue.record("Expected buffered body")
        }
    }

    @Test("429 returns plain text for non-JSON requests")
    func plainText429() async throws {
        let plug = rateLimit(max: 1, windowSeconds: 60, by: .ip)

        let conn1 = buildConn(headers: ["X-Forwarded-For": "10.0.0.99"])
        _ = try await runRateLimitPlug(conn1, plug: plug)

        let conn2 = buildConn(headers: ["X-Forwarded-For": "10.0.0.99"])
        let result = try await runRateLimitPlug(conn2, plug: plug)
        #expect(result.response.headerFields[.contentType] == nil)
        if case .buffered(let data) = result.responseBody {
            #expect(String(data: data, encoding: .utf8) == "Too Many Requests")
        } else {
            Issue.record("Expected buffered body")
        }
    }

    // MARK: - Custom 429 message

    @Test("custom message appears in 429 response")
    func customMessage() async throws {
        let plug = rateLimit(max: 1, windowSeconds: 60, message: "Slow down!")

        let conn1 = buildConn(headers: ["X-Forwarded-For": "10.0.0.50"])
        _ = try await runRateLimitPlug(conn1, plug: plug)

        let conn2 = buildConn(headers: ["X-Forwarded-For": "10.0.0.50"])
        let result = try await runRateLimitPlug(conn2, plug: plug)
        if case .buffered(let data) = result.responseBody {
            #expect(String(data: data, encoding: .utf8) == "Slow down!")
        } else {
            Issue.record("Expected buffered body")
        }
    }

    // MARK: - Multiple plugs coexist

    @Test("multiple rate limit plugs can coexist")
    func multiplePlugs() async throws {
        let globalPlug = rateLimit(max: 100, windowSeconds: 60, by: .ip)
        let strictPlug = rateLimit(max: 2, windowSeconds: 60, by: .ip)

        // Request 1: both plugs allow
        let conn1 = buildConn(headers: ["X-Forwarded-For": "192.168.2.1"])
        let result1 = try await runRateLimitPlug(conn1, plug: globalPlug)
        let result1s = try await runRateLimitPlug(result1, plug: strictPlug)
        #expect(!result1s.isHalted)

        // Request 2: strict at 2/2, still allowed
        let conn2 = buildConn(headers: ["X-Forwarded-For": "192.168.2.1"])
        let result2 = try await runRateLimitPlug(conn2, plug: globalPlug)
        let result2s = try await runRateLimitPlug(result2, plug: strictPlug)
        #expect(!result2s.isHalted)

        // Request 3: strict should hit 429
        let conn3 = buildConn(headers: ["X-Forwarded-For": "192.168.2.1"])
        _ = try await runRateLimitPlug(conn3, plug: globalPlug)
        let result3 = try await runRateLimitPlug(conn3, plug: strictPlug)
        #expect(result3.response.status == .tooManyRequests)
    }

    // MARK: - IP with multiple proxies

    @Test("X-Forwarded-For takes first IP in comma-separated list")
    func forwardedForMultipleIPs() async throws {
        let plug = rateLimit(max: 1, windowSeconds: 60)

        let conn = buildConn(headers: ["X-Forwarded-For": "1.2.3.4, 5.6.7.8, 9.10.11.12"])
        let result = try await runRateLimitPlug(conn, plug: plug)

        #expect(result.response.headerFields[.rateLimitLimitName] == "1")
        #expect(result.response.headerFields[.rateLimitRemainingName] == "0")
    }
}

// MARK: - Counters in the key-value store

/// The start of a 60-second window, so tests know where windows begin.
private let windowStart = Date(timeIntervalSince1970: 6_000)

private func client(_ id: String, store: (any KeyValueStore)? = nil) -> Connection {
    let conn = buildConn(headers: ["X-Client": id])
    guard let store else { return conn }
    return conn.assign(KeyValueStoreKey.self, value: store)
}

private func limit(
    max: Int, name: String = "test", now: @escaping @Sendable () -> Date = { windowStart },
    logger: Logger = Logger(label: "test")
) -> Plug {
    roost_rateLimit(max: max, windowSeconds: 60, by: .header(HTTPField.Name("X-Client")!),
                    message: "Too Many Requests", name: name, now: now, logger: logger)
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = windowStart
    var now: Date { lock.withLock { current } }
    func set(_ date: Date) { lock.withLock { current = date } }
}

private final class Messages: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [String] = []
    var all: [String] { lock.withLock { _all } }
    func append(_ message: String) { lock.withLock { _all.append(message) } }

    var logger: Logger {
        Logger(label: "test") { _ in Handler(messages: self) }
    }

    struct Handler: LogHandler {
        let messages: Messages
        var logLevel: Logger.Level = .trace
        var metadata: Logger.Metadata = [:]
        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }
        func log(event: LogEvent) { messages.append("\(event.message)") }
    }
}

/// Fails every operation, like a store whose server is down.
private struct FailingStore: KeyValueStore {
    func get(_ key: String) async throws -> Data? { throw KeyValueStoreError(.unavailable, "down") }
    func set(_ key: String, to value: Data, expiringAfter expiry: Duration?) async throws {
        throw KeyValueStoreError(.unavailable, "down")
    }
    func remove(_ key: String) async throws { throw KeyValueStoreError(.unavailable, "down") }
    func increment(_ key: String, by amount: Int, expiringAfter expiry: Duration?) async throws -> Int {
        throw KeyValueStoreError(.unavailable, "down")
    }
}

/// Stores values but can't increment, like a Hummingbird persist driver.
private struct NoCounterStore: KeyValueStore {
    let base = MemoryKeyValueStore()
    func get(_ key: String) async throws -> Data? { await base.get(key) }
    func set(_ key: String, to value: Data, expiringAfter expiry: Duration?) async throws {
        await base.set(key, to: value, expiringAfter: expiry)
    }
    func remove(_ key: String) async throws { await base.remove(key) }
}

private struct LimitedApp: RoostApp {
    var plugs: [Plug] { [rateLimit(max: 1, windowSeconds: 60, by: .header(HTTPField.Name("X-Client")!))] }

    @RouteBuilder var routes: [Route] {
        GET("/") { conn in conn.text("ok") }
    }
}

@Suite("Rate limits in the key-value store")
struct RateLimitStoreTests {

    @Test("Instances of an app that share a store share its limits", arguments: StoreBackend.available)
    func sharedAcrossInstances(backend: StoreBackend) async throws {
        try await backend.withStore { store in
            let first = limit(max: 2), second = limit(max: 2)
            let one = try await first(client("a", store: store))
            let two = try await second(client("a", store: store))
            let three = try await first(client("a", store: store))
            let otherClient = try await second(client("b", store: store))
            #expect(!one.isHalted)
            #expect(!two.isHalted)
            #expect(three.response.status == .tooManyRequests)
            #expect(!otherClient.isHalted)
        }
    }

    @Test("Limits with different names count separately in one store")
    func names() async throws {
        let store = MemoryKeyValueStore()
        let login = limit(max: 1, name: "login"), api = limit(max: 1, name: "api")
        #expect(try await !login(client("a", store: store)).isHalted)
        #expect(try await !api(client("a", store: store)).isHalted)
        #expect(try await login(client("a", store: store)).isHalted)
    }

    @Test("In an app, limits count in conn.store, which each test app has to itself")
    func throughTestApp() async throws {
        let app = try await TestApp(LimitedApp.self)
        #expect(try await app.get("/", headers: ["X-Client": "a"]).status == .ok)
        #expect(try await app.get("/", headers: ["X-Client": "a"]).status == .tooManyRequests)
        let other = try await TestApp(LimitedApp.self)
        #expect(try await other.get("/", headers: ["X-Client": "a"]).status == .ok)
    }

    @Test("The window slides: the previous window's requests fade out")
    func slides() async throws {
        let clock = TestClock()
        let plug = limit(max: 10, now: { clock.now })
        let store = MemoryKeyValueStore()
        clock.set(windowStart.addingTimeInterval(1))
        for _ in 0..<10 { #expect(try await !plug(client("a", store: store)).isHalted) }
        #expect(try await plug(client("a", store: store)).isHalted)

        // Halfway through the next window, half of the previous 11 requests still count.
        clock.set(windowStart.addingTimeInterval(90))
        for _ in 0..<4 { #expect(try await !plug(client("a", store: store)).isHalted) }
        #expect(try await plug(client("a", store: store)).isHalted)
    }

    @Test("Retry-After is the wait until a retry would fit")
    func retryAfter() {
        let window = RateLimitWindow(max: 10, seconds: 60, name: "test")
        let midway = windowStart.addingTimeInterval(30)
        // The previous window fades: after 12 s, 10 × 18/60 + 7 = 10.
        let fading = window.decide(.init(current: 6, previous: 10), at: midway)
        #expect(fading == .init(allowed: false, remaining: 0, reset: midway.addingTimeInterval(12), retryAfter: 12))
        // This window is over the limit: wait until it fades in the next one,
        // where 12 × 45/60 + 1 = 10.
        let over = window.decide(.init(current: 12, previous: 0), at: midway)
        #expect(over.retryAfter == 45)
        let allowed = window.decide(.init(current: 3, previous: 10), at: midway)
        #expect(allowed == .init(allowed: true, remaining: 2, reset: windowStart.addingTimeInterval(60), retryAfter: 0))
    }

    @Test("Without proxy headers, .ip limits by the socket address")
    func socketAddress() async throws {
        let plug = rateLimit(max: 1, windowSeconds: 60)
        #expect(try await !plug(TestConnection.build(remoteIP: "203.0.113.9")).isHalted)
        #expect(try await plug(TestConnection.build(remoteIP: "203.0.113.9")).isHalted)
        #expect(try await !plug(TestConnection.build(remoteIP: "203.0.113.10")).isHalted)
    }

    @Test("When the store fails, requests are allowed and the error is logged once a minute")
    func failOpen() async throws {
        let clock = TestClock()
        let messages = Messages()
        let plug = limit(max: 1, now: { clock.now }, logger: messages.logger)
        for _ in 0..<3 { #expect(try await !plug(client("a", store: FailingStore())).isHalted) }
        #expect(messages.all.count == 1)
        clock.set(windowStart.addingTimeInterval(61))
        _ = try await plug(client("a", store: FailingStore()))
        #expect(messages.all.count == 2)
    }

    @Test("A store that can't count falls back to counting in this process")
    func unsupportedStore() async throws {
        let messages = Messages()
        let plug = limit(max: 1, logger: messages.logger)
        let store = NoCounterStore()
        #expect(try await !plug(client("a", store: store)).isHalted)
        #expect(try await plug(client("a", store: store)).isHalted)
        #expect(messages.all.count == 1)
    }
}

// MARK: - Test header name

extension HTTPField.Name {
    static let xAPIKeyName = Self("X-API-Key")!
}

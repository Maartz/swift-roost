import Foundation
import HTTPTypes
import Logging
import Nexus

// MARK: - RateLimitKey

/// How to identify clients for rate limiting.
public enum RateLimitKey: Sendable {
    /// Client IP address from `X-Forwarded-For` / `X-Real-IP` / socket.
    ///
    /// The first `X-Forwarded-For` address is whatever the client sent unless a
    /// proxy in front of the app replaces the header, so a client that reaches
    /// the app directly can choose its own key. Without either header, the
    /// socket address is used.
    case ip
    /// A specific request header value (e.g. API key).
    case header(HTTPField.Name)
    /// A value from connection assigns (e.g. user ID after auth).
    case assign(String)
    /// Custom extraction function. Return nil to skip rate limiting.
    case custom(@Sendable (Connection) -> String?)
}

// MARK: - Rate Limit Plug

/// A plug that limits the number of requests per client within a sliding time window.
///
/// The counters live in the app's key-value store, ``Nexus/Connection/store``,
/// so with a Valkey store a limit applies across every instance of the app.
/// Outside a Roost app, the plug counts in its own memory.
///
/// ```swift
/// // Global rate limit
/// var plugs: [Plug] {
///     [rateLimit(max: 100, windowSeconds: 60), roost_requestLogger()]
/// }
/// ```
///
/// The window slides: a request counts the current window's requests plus the
/// previous window's, weighted by how much of the previous window still
/// overlaps the last `windowSeconds`. Rejected requests count too.
///
/// If the store fails, for example while Valkey is unreachable, requests are
/// allowed and the error is logged at most once a minute. A store that can't
/// increment atomically, such as a Hummingbird persist driver, falls back to
/// counting in each process's memory.
///
/// - Parameters:
///   - max: Maximum number of requests allowed per window.
///   - windowSeconds: Duration of the sliding window in seconds.
///   - by: How to identify the client. Defaults to IP address.
///   - message: Custom error message for 429 responses.
///   - name: Keeps this limit's counters apart from other limits'. Defaults to
///     the place in the code that creates the plug, so limits created there
///     share counters on every instance of the app.
///   - fileID: The file that creates the plug, which names it when `name` is `nil`.
///   - line: The line that creates the plug, which names it when `name` is `nil`.
/// - Returns: A plug that enforces rate limits and sets `X-RateLimit-*` headers.
public func rateLimit(
    max: Int,
    windowSeconds: Int,
    by: RateLimitKey = .ip,
    message: String = "Too Many Requests",
    name: String? = nil,
    fileID: String = #fileID,
    line: Int = #line
) -> Plug {
    roost_rateLimit(
        max: max, windowSeconds: windowSeconds, by: by, message: message,
        name: name ?? "\(fileID):\(line)"
    )
}

/// The rate limit plug, with the clock and logger tests replace.
func roost_rateLimit(
    max: Int,
    windowSeconds: Int,
    by key: RateLimitKey,
    message: String,
    name: String,
    now: @escaping @Sendable () -> Date = { Date.now },
    logger: Logger = Logger(label: "roost.ratelimit")
) -> Plug {
    let window = RateLimitWindow(max: max, seconds: Swift.max(1, windowSeconds), name: name)
    let fallback = MemoryKeyValueStore()
    let warnings = RateLimitWarnings(logger: logger)

    return { conn in
        guard let client = extractKey(from: conn, using: key) else { return conn }
        let time = now()

        let counts: RateLimitWindow.Counts
        do {
            counts = try await window.count(client, at: time, in: conn[KeyValueStoreKey.self] ?? fallback)
        } catch let error as KeyValueStoreError where error.kind == .unsupported {
            warnings.unsupported(error)
            counts = try await window.count(client, at: time, in: fallback)
        } catch {
            warnings.failed(error, at: time)
            return conn
        }

        let decision = window.decide(counts, at: time)
        var updated = conn
        updated.response.headerFields[.rateLimitLimitName] = String(max)
        updated.response.headerFields[.rateLimitRemainingName] = String(decision.remaining)
        updated.response.headerFields[.rateLimitResetName] = String(Int(decision.reset.timeIntervalSince1970.rounded(.up)))

        guard decision.allowed else {
            updated.response.status = .tooManyRequests
            updated.response.headerFields[.retryAfterName] = String(decision.retryAfter)

            if requestsJSON(conn) {
                updated.response.headerFields[.contentType] = "application/json"
                let body = #"{"error": "\#(message)"}"#
                updated.responseBody = .string(body)
            } else {
                updated.responseBody = .string(message)
            }
            updated.isHalted = true
            return updated
        }

        return updated
    }
}

// MARK: - Sliding window

/// Approximates a sliding window with two fixed windows: the current window's
/// count plus the previous window's, weighted by how much of it the sliding
/// window still covers.
struct RateLimitWindow: Sendable {
    let max: Int
    let seconds: Int
    let name: String

    struct Counts: Sendable, Equatable {
        let current: Int
        let previous: Int
    }

    struct Decision: Equatable {
        let allowed: Bool
        let remaining: Int
        /// When the client's allowance is next restored: the end of the
        /// current window, or the end of the wait for a rejected client.
        let reset: Date
        /// Seconds a rejected client should wait.
        let retryAfter: Int
    }

    /// Counts this request in the current window and reads the previous one.
    func count(_ client: String, at time: Date, in store: any KeyValueStore) async throws -> Counts {
        let index = windowIndex(at: time)
        // A window's counter is read as the previous one until the next window ends.
        async let current = store.increment(key(client, index), by: 1, expiringAfter: .seconds(2 * seconds))
        async let previous = store.get(key(client, index - 1))
        let previousCount = try await previous.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        return Counts(current: try await current, previous: previousCount)
    }

    func decide(_ counts: Counts, at time: Date) -> Decision {
        let length = Double(seconds)
        let windowEnd = Double(windowIndex(at: time) + 1) * length
        let left = windowEnd - time.timeIntervalSince1970
        let estimate = Double(counts.previous) * left / length + Double(counts.current)
        let remaining = Swift.max(0, max - Int(estimate.rounded(.up)))
        guard estimate > Double(max) else {
            return Decision(allowed: true, remaining: remaining, reset: Date(timeIntervalSince1970: windowEnd), retryAfter: 0)
        }

        // How long until a retry, which also counts, would fit.
        let wait: Double
        if counts.current < max, counts.previous > 0 {
            // The previous window's weight has to fall while this window lasts.
            wait = left - Double(max - counts.current - 1) * length / Double(counts.previous)
        } else {
            // This window alone is over the limit, so wait for it to become the
            // previous window and fade enough.
            let fade = 1 - Double(Swift.max(0, max - 1)) / Double(counts.current)
            wait = left + length * Swift.max(0, fade)
        }
        let retryAfter = Swift.max(1, Int(wait.rounded(.up)))
        return Decision(
            allowed: false, remaining: 0,
            reset: time.addingTimeInterval(Double(retryAfter)), retryAfter: retryAfter
        )
    }

    private func windowIndex(at time: Date) -> Int {
        Int((time.timeIntervalSince1970 / Double(seconds)).rounded(.down))
    }

    private func key(_ client: String, _ index: Int) -> String {
        "ratelimit:\(name):\(client):\(index)"
    }
}

/// Logs store problems without flooding the log during an outage.
private final class RateLimitWarnings: @unchecked Sendable {
    private let lock = NSLock()
    private let logger: Logger
    private var warnedUnsupported = false
    private var lastFailure: Date?

    init(logger: Logger) { self.logger = logger }

    func unsupported(_ error: KeyValueStoreError) {
        let first = lock.withLock { () -> Bool in
            defer { warnedUnsupported = true }
            return !warnedUnsupported
        }
        guard first else { return }
        logger.warning("The key-value store can't count requests atomically, so rate limits count in each process's memory: \(error)")
    }

    func failed(_ error: any Error, at time: Date) {
        let due = lock.withLock { () -> Bool in
            guard lastFailure.map({ time.timeIntervalSince($0) >= 60 }) ?? true else { return false }
            lastFailure = time
            return true
        }
        guard due else { return }
        logger.error("Rate limiting is allowing requests because the key-value store failed: \(error)")
    }
}

// MARK: - Key extraction

private func extractKey(from conn: Connection, using key: RateLimitKey) -> String? {
    switch key {
    case .ip:
        if let forwarded = conn.request.headerFields[.xForwardedForName],
           let first = forwarded.split(separator: ",").first {
            return String(first.trimmingCharacters(in: .whitespaces))
        }
        if let realIP = conn.request.headerFields[.xRealIPName] {
            return realIP
        }
        return conn.remoteIP
    case .header(let name):
        return conn.request.headerFields[name]
    case .assign(let name):
        return conn.assigns[name] as? String
    case .custom(let fn):
        return fn(conn)
    }
}

// MARK: - Helpers

private func requestsJSON(_ conn: Connection) -> Bool {
    if let accept = conn.request.headerFields[.accept],
       accept.contains("application/json") {
        return true
    }
    if let contentType = conn.request.headerFields[.contentType],
       contentType.contains("application/json") {
        return true
    }
    return false
}

// MARK: - Non-standard header names

extension HTTPField.Name {
    static let xForwardedForName = Self("X-Forwarded-For")!
    static let xRealIPName = Self("X-Real-IP")!
    static let rateLimitLimitName = Self("X-RateLimit-Limit")!
    static let rateLimitRemainingName = Self("X-RateLimit-Remaining")!
    static let rateLimitResetName = Self("X-RateLimit-Reset")!
    static let retryAfterName = Self("Retry-After")!
}

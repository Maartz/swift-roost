import Foundation

/// A ``KeyValueStore`` in this process's memory, for development, tests, and
/// apps that run as a single process.
///
/// It keeps values encoded, with the same expiry and increment rules as
/// Valkey, so a value that can't be stored fails in development and tests,
/// not first in production. Values are lost when the process stops and aren't
/// shared between servers.
public actor MemoryKeyValueStore: KeyValueStore {
    private var entries: [String: (data: Data, expiresAt: ContinuousClock.Instant?)] = [:]
    private var writesSinceSweep = 0
    private let now: @Sendable () -> ContinuousClock.Instant

    /// Expired entries are removed when read, and swept after this many writes.
    static let sweepInterval = 1000

    public init() {
        self.now = { ContinuousClock.now }
    }

    /// A store that reads the time from `now`, so tests can expire values
    /// without waiting.
    init(now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.now = now
    }

    public func get(_ key: String) -> Data? {
        guard let entry = entries[key] else { return nil }
        if let expiresAt = entry.expiresAt, now() >= expiresAt {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.data
    }

    public func set(_ key: String, to value: Data, expiringAfter expiry: Duration?) {
        entries[key] = (value, expiry.map { now() + $0 })
        sweepIfDue()
    }

    public func remove(_ key: String) {
        entries.removeValue(forKey: key)
    }

    // Declared `async` like the protocol's default implementation, so a call
    // on a `MemoryKeyValueStore` value resolves to this method, not the default.
    public func increment(_ key: String, by amount: Int, expiringAfter expiry: Duration?) async throws -> Int {
        let expiresAt: ContinuousClock.Instant?
        let current: Int
        if let data = get(key) {
            guard let value = Int(String(decoding: data, as: UTF8.self)) else {
                throw KeyValueStoreError(.undecodable, "The value under \(key) isn't an integer")
            }
            current = value
            expiresAt = entries[key]?.expiresAt
        } else {
            current = 0
            expiresAt = expiry.map { now() + $0 }
        }
        let (result, overflow) = current.addingReportingOverflow(amount)
        guard !overflow else {
            throw KeyValueStoreError(.overflow, "Incrementing \(key) by \(amount) overflows")
        }
        entries[key] = (Data(String(result).utf8), expiresAt)
        sweepIfDue()
        return result
    }

    /// The number of entries held, including expired ones not yet swept.
    var count: Int { entries.count }

    private func sweepIfDue() {
        writesSinceSweep += 1
        guard writesSinceSweep >= Self.sweepInterval else { return }
        writesSinceSweep = 0
        let now = now()
        entries = entries.filter { $0.value.expiresAt.map { now < $0 } ?? true }
    }
}

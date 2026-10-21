import Foundation
import Logging
#if Valkey
import NIOSSL
import Valkey
#endif

/// A parsed `valkey://` URL: `valkey://[user[:password]@]host[:port][/database]`.
///
/// `valkeys://` connects with TLS. `redis://` and `rediss://` are accepted as
/// the same schemes.
struct ValkeyURL: Equatable {
    var host: String
    var port: Int
    var username: String?
    var password: String?
    var database: Int
    var tls: Bool

    init(_ string: String) throws {
        guard let components = URLComponents(string: string),
              let scheme = components.scheme?.lowercased(),
              ["valkey", "valkeys", "redis", "rediss"].contains(scheme) else {
            throw KeyValueStoreError(.misconfigured, "A store URL starts with valkey:// or valkeys://, not \(Self.redacted(string))")
        }
        guard let host = components.host, !host.isEmpty else {
            throw KeyValueStoreError(.misconfigured, "The store URL \(Self.redacted(string)) has no host")
        }
        // URLComponents keeps the brackets of an IPv6 address, which name resolution rejects.
        self.host = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        self.port = components.port ?? 6379
        // URLComponents decodes percent-escapes in the user and password.
        self.username = components.user.flatMap { $0.isEmpty ? nil : $0 }
        self.password = components.password
        self.tls = scheme == "valkeys" || scheme == "rediss"
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty {
            self.database = 0
        } else if let database = Int(path), database >= 0 {
            self.database = database
        } else {
            throw KeyValueStoreError(.misconfigured, "The store URL path names a database number, not \(path)")
        }
    }

    /// `true` when ``host`` is an IPv4 or IPv6 address rather than a name.
    /// TLS can't send an address as the server name (SNI).
    var hostIsIPAddress: Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    /// The URL without its credentials, for error messages and logs: whatever
    /// comes between `://` and the last `@` is hidden, also in a URL
    /// `URLComponents` can't parse, such as one with an unescaped `#` in its password.
    static func redacted(_ string: String) -> String {
        guard let at = string.lastIndex(of: "@") else { return string }
        let start = string.range(of: "://")?.upperBound ?? string.startIndex
        guard start <= at else { return string }
        return string[..<start] + "***" + string[at...]
    }
}

#if Valkey
/// A ``KeyValueStore`` on a Valkey or Redis server, through valkey-swift.
struct ValkeyKeyValueStore: KeyValueStore {
    let client: ValkeyClient

    /// Requests fail fast once the server has been unreachable this long,
    /// instead of waiting for valkey-swift's 60-second default.
    static let circuitBreakerTripAfter: Duration = .seconds(2)

    /// How long a command waits for a reply from a server that is reachable
    /// but not answering, such as one paused during a failover, instead of
    /// valkey-swift's 30-second default. The circuit breaker only covers
    /// connections that can't be opened.
    static let commandTimeout: Duration = .seconds(2)

    init(url: ValkeyURL, logger: Logger) throws {
        var configuration = ValkeyClientConfiguration(
            authentication: url.password.map { .init(username: url.username ?? "default", password: $0) },
            tls: url.tls ? try .enable(.makeClientConfiguration(), tlsServerName: url.hostIsIPAddress ? nil : url.host) : .disable,
            databaseNumber: url.database
        )
        configuration.connectionPool.circuitBreakerTripAfter = Self.circuitBreakerTripAfter
        configuration.commandTimeout = Self.commandTimeout
        client = ValkeyClient(.hostname(url.host, port: url.port), configuration: configuration, logger: logger)
    }

    func get(_ key: String) async throws -> Data? {
        try await valkey { try await client.get(ValkeyKey(key)).map { Data($0) } }
    }

    func set(_ key: String, to value: Data, expiringAfter expiry: Duration?) async throws {
        // A SET without an expiry also clears an earlier one.
        try await valkey { _ = try await client.set(ValkeyKey(key), value: value, expiration: expiry.map { .milliseconds(Self.milliseconds($0)) }) }
    }

    func remove(_ key: String) async throws {
        try await valkey { _ = try await client.del(keys: [ValkeyKey(key)]) }
    }

    func increment(_ key: String, by amount: Int, expiringAfter expiry: Duration?) async throws -> Int {
        try await valkey {
            let key = ValkeyKey(key)
            guard let expiry else { return try await client.incrby(key, increment: amount) }
            // One transaction, so a new counter can't be left without its expiry. SET NX
            // creates it with the expiry; PEXPIRE's NX option would need Redis 7.
            let (_, count) = try await client.transaction(
                SET(key, value: "0", condition: .nx, expiration: .milliseconds(Self.milliseconds(expiry))),
                INCRBY(key, increment: amount)
            )
            return try count.get()
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        max(1, Int((duration / .milliseconds(1)).rounded(.up)))
    }

    /// Reports valkey-swift's errors as ``KeyValueStoreError``, so apps don't depend on its types.
    private func valkey<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as KeyValueStoreError {
            throw error
        } catch let error as ValkeyClientError
            where error.errorCode == .commandError && error.message?.contains("not an integer") == true
        {
            // Matches MemoryKeyValueStore, which reports a non-integer counter the same way.
            throw KeyValueStoreError(.undecodable, "Valkey: \(error.message ?? "value is not an integer")")
        } catch let error as ValkeyClientError
            where error.errorCode == .commandError && error.message?.contains("overflow") == true
        {
            throw KeyValueStoreError(.overflow, "Valkey: \(error.message ?? "increment would overflow")")
        } catch {
            throw KeyValueStoreError(.unavailable, "Valkey: \(error)")
        }
    }
}
#endif

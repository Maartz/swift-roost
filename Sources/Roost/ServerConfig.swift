import Foundation

/// Server binding settings and optional transport configuration.
///
/// Roost's current bootstrap applies only `host` and `port`. The TLS and HTTP/2
/// settings are deprecated because the running Hummingbird server doesn't use
/// them; terminate TLS in a reverse proxy instead.
public struct ServerConfig: Sendable {
    public let host: String
    public let port: Int

    // The deprecated settings, stored without the deprecated types so the
    // supported initializer doesn't use them.
    private let certificatePath: String?
    private let keyPath: String?
    private let requestsHTTP2: Bool

    /// Requested TLS configuration. Roost's bootstrap does not apply it yet.
    @available(*, deprecated, message: """
        Roost's bootstrap doesn't apply TLS or HTTP/2 settings; terminate TLS in a reverse proxy. \
        Roost 3.0 removes them from the stable API until they are implemented.
        """)
    public var tls: TLSConfig? {
        guard let certificatePath, let keyPath else { return nil }
        return TLSConfig(certificatePath: certificatePath, keyPath: keyPath)
    }

    /// Requested HTTP/2 support. Setting `tls` also sets this value to `true`,
    /// but Roost's bootstrap does not yet enable HTTP/2 on the running server.
    @available(*, deprecated, message: """
        Roost's bootstrap doesn't apply TLS or HTTP/2 settings; terminate TLS in a reverse proxy. \
        Roost 3.0 removes them from the stable API until they are implemented.
        """)
    public var http2: Bool { requestsHTTP2 }

    /// TLS certificate and key pair.
    @available(*, deprecated, message: """
        Roost's bootstrap doesn't apply TLS or HTTP/2 settings; terminate TLS in a reverse proxy. \
        Roost 3.0 removes them from the stable API until they are implemented.
        """)
    public struct TLSConfig: Sendable {
        /// Path to the PEM-encoded certificate file.
        public let certificatePath: String
        /// Path to the PEM-encoded private key file.
        public let keyPath: String

        public init(certificatePath: String, keyPath: String) {
            self.certificatePath = certificatePath
            self.keyPath = keyPath
        }
    }

    // MARK: - Init

    public init(host: String = "127.0.0.1", port: Int = 8080) {
        self.host = host
        self.port = port
        certificatePath = nil
        keyPath = nil
        requestsHTTP2 = false
    }

    @available(*, deprecated, message: """
        Roost's bootstrap doesn't apply TLS or HTTP/2 settings; terminate TLS in a reverse proxy. \
        Roost 3.0 removes them from the stable API until they are implemented.
        """)
    public init(
        host: String = "127.0.0.1",
        port: Int = 8080,
        tls: TLSConfig?,
        http2: Bool = false
    ) {
        self.host = host
        self.port = port
        certificatePath = tls?.certificatePath
        keyPath = tls?.keyPath
        // If TLS is configured, HTTP/2 is automatically enabled.
        requestsHTTP2 = tls != nil ? true : http2
    }

    @available(*, deprecated, message: """
        Roost's bootstrap doesn't apply TLS or HTTP/2 settings; terminate TLS in a reverse proxy. \
        Roost 3.0 removes them from the stable API until they are implemented.
        """)
    public init(host: String = "127.0.0.1", port: Int = 8080, http2: Bool) {
        self.init(host: host, port: port, tls: nil, http2: http2)
    }

    /// Reads `ROOST_HOST` and `ROOST_PORT` from the environment,
    /// falling back to the provided defaults.
    public static func fromEnvironment(
        defaultHost: String = "127.0.0.1",
        defaultPort: Int = 8080
    ) -> ServerConfig {
        let host = ProcessInfo.processInfo.environment["ROOST_HOST"] ?? defaultHost
        let port = ProcessInfo.processInfo.environment["ROOST_PORT"]
            .flatMap(Int.init) ?? defaultPort
        return ServerConfig(host: host, port: port)
    }

    // MARK: - Validation

    /// Validates that any configured TLS certificate and key files exist on
    /// disk. Returns a descriptive error string on failure, or nil if valid.
    @available(*, deprecated, message: """
        validate() checks only the TLS files, which Roost's bootstrap doesn't use. \
        Roost 3.0 removes it from the stable API until TLS is implemented.
        """)
    public func validate() -> [String]? {
        var errors: [String] = []

        if let certificatePath, let keyPath {
            if !FileManager.default.fileExists(atPath: certificatePath) {
                errors.append("TLS certificate file not found: \(certificatePath)")
            }
            if !FileManager.default.fileExists(atPath: keyPath) {
                errors.append("TLS key file not found: \(keyPath)")
            }
        }

        return errors.isEmpty ? nil : errors
    }
}

import Foundation
import HummingbirdCore
import HummingbirdHTTP2
import NIOSSL

/// Server binding settings and optional TLS.
///
/// Without ``tls`` the server speaks HTTP/1.1. With it, the server speaks HTTPS
/// and negotiates HTTP/2 with clients that support it, falling back to HTTP/1.1.
///
/// ```swift
/// var server: ServerConfig {
///     ServerConfig(host: "0.0.0.0", port: 443, tls: .init(
///         certificatePath: "/etc/ssl/app/fullchain.pem",
///         keyPath: "/etc/ssl/app/privkey.pem"
///     ))
/// }
/// ```
public struct ServerConfig: Sendable {
    public let host: String
    public let port: Int

    /// The certificate and key the server uses for HTTPS, or `nil` for plain HTTP.
    public let tls: TLSConfig?

    /// Whether the server negotiates HTTP/2. Setting ``tls`` turns it on.
    /// HTTP/2 needs TLS: without it, ``validate()`` reports an error and the app
    /// stops at startup.
    public let http2: Bool

    /// TLS certificate and key pair.
    public struct TLSConfig: Sendable {
        /// Path to the PEM-encoded certificate file. Put intermediate
        /// certificates after the server's own, as in a `fullchain.pem`.
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
        self.init(host: host, port: port, tls: nil)
    }

    public init(
        host: String = "127.0.0.1",
        port: Int = 8080,
        tls: TLSConfig?,
        http2: Bool = false
    ) {
        self.host = host
        self.port = port
        self.tls = tls
        // If TLS is configured, HTTP/2 is automatically enabled.
        self.http2 = tls != nil ? true : http2
    }

    @available(*, deprecated, message: """
        HTTP/2 needs TLS, so an app with this configuration stops at startup. \
        Pass tls: to serve HTTPS with HTTP/2, or terminate TLS in a reverse proxy.
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

    /// Checks that the configured TLS certificate and key files exist, and that
    /// HTTP/2 isn't requested without TLS. Returns a descriptive error string for
    /// each problem, or nil if the configuration is valid.
    public func validate() -> [String]? {
        var errors: [String] = []

        if let tls {
            if !FileManager.default.fileExists(atPath: tls.certificatePath) {
                errors.append("TLS certificate file not found: \(tls.certificatePath)")
            }
            if !FileManager.default.fileExists(atPath: tls.keyPath) {
                errors.append("TLS key file not found: \(tls.keyPath)")
            }
        } else if http2 {
            errors.append("HTTP/2 needs TLS: set tls, or terminate TLS in a reverse proxy")
        }

        return errors.isEmpty ? nil : errors
    }

    /// The Hummingbird server for this configuration: HTTP/1.1, or HTTPS that
    /// negotiates HTTP/2 when ``tls`` is set.
    ///
    /// - Throws: ``ServerConfigError`` when ``validate()`` finds a problem, or
    ///   NIOSSL's error when the certificate or key can't be parsed.
    func serverBuilder() throws -> HTTPServerBuilder {
        if let errors = validate() { throw ServerConfigError(messages: errors) }
        guard let tls else { return .http1() }
        let certificates = try NIOSSLCertificate.fromPEMFile(tls.certificatePath).map(NIOSSLCertificateSource.certificate)
        let key = try NIOSSLPrivateKey(file: tls.keyPath, format: .pem)
        return try .http2Upgrade(tlsConfiguration: .makeServerConfiguration(
            certificateChain: certificates, privateKey: .privateKey(key)
        ))
    }
}

/// A server configuration the app can't start with, such as a missing
/// certificate file. Each message names one problem.
public struct ServerConfigError: Error, Sendable, CustomStringConvertible {
    public let messages: [String]

    public var description: String { messages.joined(separator: "\n") }
}

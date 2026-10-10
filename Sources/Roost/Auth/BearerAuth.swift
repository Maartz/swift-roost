import Foundation
import HTTPTypes
import Nexus

// MARK: - TokenExpirable Protocol

/// Conform your token model to this protocol to get expiry-checking helpers.
///
/// ```swift
/// @Schema("user_tokens")
/// struct UserToken: TokenExpirable {
///     @ID var id: UUID
///     @Column var token: String
///     @Column var context: String
///     @Column var userId: UUID
///     @Column var expiresAt: Date?
///     // ...
/// }
///
/// // Then in your bearer auth plug:
/// if tokenRow.isExpired { return nil }
/// ```
public protocol TokenExpirable: Sendable {
    /// When the token expires. `nil` means it never expires.
    var expiresAt: Date? { get }
}

extension TokenExpirable {
    /// `true` when the token has passed its expiry date.
    ///
    /// Returns `false` when `expiresAt` is `nil` (no expiry set).
    public var isExpired: Bool {
        guard let expiry = expiresAt else { return false }
        return expiry < Date()
    }

    /// `true` when the token has not yet expired.
    public var isActive: Bool { !isExpired }
}

// MARK: - Connection Extensions — Bearer Token Auth

extension Connection {

    /// Extract the bearer token from the `Authorization` header.
    ///
    /// Returns `nil` when the header is missing or doesn't start with `Bearer `.
    ///
    /// ```swift
    /// if let token = conn.bearerToken {
    ///     let hashed = Auth.sha256Hex(token)
    ///     // look up hashed token in your user_tokens table
    /// }
    /// ```
    public var bearerToken: String? {
        guard let header = getReqHeader(.authorization),
              header.hasPrefix("Bearer ")
        else { return nil }

        let token = String(header.dropFirst("Bearer ".count))
        return token.isEmpty ? nil : token
    }

    /// Store a bearer-authenticated user in assigns, tagged with
    /// context `"api"` instead of `"session"`.
    ///
    /// Call this from your API authentication plug after validating
    /// the bearer token against the database.
    public func setBearerUser<U: Authenticatable>(_ user: U) -> Connection {
        roost_authenticate(user, context: .api)
    }
}

// MARK: - HTTP Error Response Helpers

extension Connection {

    /// Return a 401 Unauthorized response with a `WWW-Authenticate` header.
    ///
    /// Follows RFC 6750 for bearer token error responses.
    ///
    /// - Parameters:
    ///   - realm: The authentication realm (default: `"API"`).
    ///   - error: Optional error code (`"invalid_token"`, `"insufficient_scope"`, etc.).
    /// - Returns: A halted connection with status 401 and the appropriate header.
    public func unauthorized(
        realm: String = "API",
        error: String? = nil
    ) -> Connection {
        var headerValue = "Bearer realm=\"\(realm)\""
        if let error {
            headerValue += ", error=\"\(error)\""
        }

        var copy = self
        copy.response.status = .unauthorized
        if let wwwAuth = HTTPField.Name("WWW-Authenticate") {
            copy.response.headerFields[wwwAuth] = headerValue
        }
        copy.isHalted = true
        return copy
    }

    /// Return a 403 Forbidden response.
    public func forbidden() -> Connection {
        var copy = self
        copy.response.status = .forbidden
        copy.isHalted = true
        return copy
    }
}

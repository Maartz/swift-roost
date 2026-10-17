import Foundation
import HTTPTypes
import Nexus
import NexusTest
import Testing

@testable import Roost

// MARK: - Test User Model

/// Minimal Authenticatable user for testing.
struct TestUser: Authenticatable, Equatable {
    let id: String
    let email: String
    let hashedPassword: String

    var authID: String { id }

    init(id: String = "user-42", email: String = "test@example.com", hashedPassword: String = "") {
        self.id = id
        self.email = email
        self.hashedPassword = hashedPassword
    }
}

// MARK: - Password Hashing Tests

@Suite("Auth — Password Hashing")
struct PasswordHashingTests {

    @Test("hashPassword produces a PBKDF2-SHA256 formatted string")
    func hashFormatIsCorrect() throws {
        let hash = try Auth.hashPassword("password123")
        let parts = hash.split(separator: "$")
        #expect(parts.count == 4)
        #expect(parts[0] == "pbkdf2-sha256")
        #expect(parts[1] == "600000")
        // salt and hash are non-empty base64url
        #expect(parts[2].count > 0)
        #expect(parts[3].count > 0)
    }

    @Test("verifyPassword succeeds for matching password")
    func verifyMatchingPassword() throws {
        let hash = try Auth.hashPassword("my-secret-pass")
        #expect(Auth.verifyPassword("my-secret-pass", against: hash))
    }

    @Test("verifyPassword fails for wrong password")
    func verifyWrongPassword() throws {
        let hash = try Auth.hashPassword("my-secret-pass")
        #expect(!Auth.verifyPassword("wrong-password", against: hash))
    }

    @Test("hashPassword throws for passwords shorter than minimum length")
    func shortPasswordThrows() {
        #expect(throws: AuthError.self) {
            _ = try Auth.hashPassword("short")
        }
    }

    @Test("hashPassword minimum length is 8")
    func minimumLengthIs8() throws {
        // Exactly 8 should work
        _ = try Auth.hashPassword("12345678")

        // 7 should fail
        #expect(throws: AuthError.self) {
            _ = try Auth.hashPassword("1234567")
        }
    }

    @Test("each hash is unique due to random salt")
    func uniqueHashes() throws {
        let hash1 = try Auth.hashPassword("same-password")
        let hash2 = try Auth.hashPassword("same-password")
        #expect(hash1 != hash2)
        // But both verify
        #expect(Auth.verifyPassword("same-password", against: hash1))
        #expect(Auth.verifyPassword("same-password", against: hash2))
    }

    @Test("verifyPassword rejects malformed hash strings")
    func rejectMalformedHash() {
        #expect(!Auth.verifyPassword("anything", against: "not-a-valid-hash"))
        #expect(!Auth.verifyPassword("anything", against: ""))
        #expect(!Auth.verifyPassword("anything", against: "a$b$c"))
        #expect(!Auth.verifyPassword("anything", against: "pbkdf2-sha256$notanumber$abc$def"))
    }
}

// MARK: - Token Generation Tests

@Suite("Auth — Token Generation")
struct TokenGenerationTests {

    @Test("generateToken produces URL-safe base64 string")
    func tokenIsURLSafe() {
        let token = Auth.generateToken()
        #expect(!token.contains("+"))
        #expect(!token.contains("/"))
        #expect(!token.contains("="))
        #expect(token.count > 0)
    }

    @Test("generateToken default length produces 43-char string")
    func defaultTokenLength() {
        // 32 bytes -> ceil(32 * 4/3) = 43 chars in base64url (no padding)
        let token = Auth.generateToken()
        #expect(token.count == 43)
    }

    @Test("generateToken with custom byte count")
    func customByteCount() {
        let short = Auth.generateToken(bytes: 16)
        let long = Auth.generateToken(bytes: 64)
        #expect(short.count < long.count)
    }

    @Test("each token is unique")
    func tokensAreUnique() {
        let tokens = (0..<10).map { _ in Auth.generateToken() }
        let unique = Set(tokens)
        #expect(unique.count == 10)
    }
}

// MARK: - SHA256 Hex Tests

@Suite("Auth — SHA256 Hex")
struct SHA256HexTests {

    @Test("sha256Hex produces 64-char lowercase hex string")
    func hexFormat() {
        let hex = Auth.sha256Hex("hello")
        #expect(hex.count == 64)
        #expect(hex == hex.lowercased())
        #expect(hex.allSatisfy { $0.isHexDigit })
    }

    @Test("sha256Hex is deterministic")
    func deterministic() {
        #expect(Auth.sha256Hex("test") == Auth.sha256Hex("test"))
    }

    @Test("sha256Hex differs for different inputs")
    func differentInputs() {
        #expect(Auth.sha256Hex("a") != Auth.sha256Hex("b"))
    }
}

// MARK: - Session Auth Tests

@Suite("Auth — Session Auth")
struct SessionAuthTests {

    @Test("loginUser stores user in assigns and returns token")
    func loginStoresUser() async throws {
        let store = MemorySessionStore()
        let conn = try await withSession(store: store)
        let user = TestUser()

        let (loggedIn, token) = conn.loginUser(user)

        // Token is non-empty
        #expect(!token.isEmpty)

        // User is in assigns
        let current = loggedIn.currentUser(TestUser.self)
        #expect(current?.id == "user-42")

        // isAuthenticated is true
        #expect(loggedIn.isAuthenticated)
    }

    @Test("logoutUser clears session auth data")
    func logoutClearsSession() async throws {
        let store = MemorySessionStore()
        let conn = try await withSession(store: store)
        let user = TestUser()

        let (loggedIn, _) = conn.loginUser(user)
        let loggedOut = loggedIn.logoutUser()

        #expect(loggedOut.authSessionToken == nil)
        #expect(loggedOut.authUserID == nil)
        #expect(loggedOut.currentUser(TestUser.self) == nil)
        #expect(!loggedOut.isAuthenticated)
    }

    @Test("setCurrentUser and currentUser round-trip")
    func setAndGetCurrentUser() {
        let conn = TestConnection.build()
        let user = TestUser(id: "abc-123", email: "alice@example.com")

        let updated = conn.setCurrentUser(user)

        let loaded = updated.currentUser(TestUser.self)
        #expect(loaded?.id == "abc-123")
        #expect(loaded?.email == "alice@example.com")
        #expect(updated.isAuthenticated)
    }

    @Test("currentUser returns nil when no user is set")
    func noUserReturnsNil() {
        let conn = TestConnection.build()
        #expect(conn.currentUser(TestUser.self) == nil)
        #expect(!conn.isAuthenticated)
    }

    @Test("authUserID returns the session-stored user ID")
    func authUserIDFromSession() async throws {
        let store = MemorySessionStore()
        let sessionID = "test-session"
        try await store.set(sessionID, data: ["_roost_user_id": "user-99"], ttl: nil)

        let conn = connWithSessionCookie(sessionID)
        let plug = session(store: store)
        let afterPlug = try await plug(conn)

        #expect(afterPlug.authUserID == "user-99")
    }
}

// MARK: - Bearer Auth Tests

@Suite("Auth — Bearer Token")
struct BearerAuthTests {

    @Test("bearerToken extracts token from Authorization header")
    func extractBearerToken() {
        let conn = TestConnection.build(
            headers: [.authorization: "Bearer my-api-token-123"]
        )
        #expect(conn.bearerToken == "my-api-token-123")
    }

    @Test("bearerToken returns nil when header is missing")
    func missingHeader() {
        let conn = TestConnection.build()
        #expect(conn.bearerToken == nil)
    }

    @Test("bearerToken returns nil for non-Bearer auth schemes")
    func nonBearerScheme() {
        let conn = TestConnection.build(
            headers: [.authorization: "Basic dXNlcjpwYXNz"]
        )
        #expect(conn.bearerToken == nil)
    }

    @Test("bearerToken returns nil for empty token after Bearer prefix")
    func emptyToken() {
        let conn = TestConnection.build(
            headers: [.authorization: "Bearer "]
        )
        #expect(conn.bearerToken == nil)
    }

    @Test("setBearerUser sets context to api")
    func bearerContextIsApi() {
        let conn = TestConnection.build()
        let user = TestUser()
        let updated = conn.setBearerUser(user)

        #expect(updated.isAuthenticated)
        #expect(updated.authContext == .api)
    }

    @Test("Apps using the 2.1 AuthAssign string keys see the same authentication state")
    func stringKeysShareStorage() {
        let user = TestUser(id: "user-7")
        let conn = TestConnection.build().setBearerUser(user)
        #expect(conn.assigns["_roost_current_user"] as? TestUser == user)
        #expect(conn.assigns["_roost_current_user_id"] as? String == "user-7")
        #expect(conn.assigns["_roost_auth_context"] as? String == "api")

        var signedOut = conn
        signedOut.assigns.removeValue(forKey: "_roost_current_user_id")
        #expect(!signedOut.isAuthenticated)

        let legacy = TestConnection.build().assign(key: "_roost_current_user_id", value: "user-8")
        #expect(legacy.authenticatedUserID == "user-8")
    }
}

// MARK: - Auth Plug Tests

@Suite("Auth — Plugs")
struct AuthPlugTests {

    @Test("requireAuth redirects unauthenticated users")
    func requireAuthRedirects() async throws {
        let plug = requireAuth()
        let conn = TestConnection.build(path: "/dashboard")

        let result = try await plug(conn)

        #expect(result.isHalted)
        #expect(result.response.status == .seeOther)
    }

    @Test("requireAuth passes authenticated users through")
    func requireAuthPassesAuthenticated() async throws {
        let plug = requireAuth()
        let conn = TestConnection.build().setCurrentUser(TestUser())

        let result = try await plug(conn)

        #expect(!result.isHalted)
        #expect(result.currentUser(TestUser.self) != nil)
    }

    @Test("requireAuth uses custom redirect path")
    func requireAuthCustomRedirect() async throws {
        let plug = requireAuth(redirectTo: "/sign-in")
        let conn = TestConnection.build(path: "/protected")

        let result = try await plug(conn)

        #expect(result.isHalted)
        #expect(result.response.status == .seeOther)
    }

    @Test("requireApiAuth returns 401 for unauthenticated requests")
    func requireApiAuthReturns401() async throws {
        let plug = requireApiAuth()
        let conn = TestConnection.build()

        let result = try await plug(conn)

        #expect(result.isHalted)
        #expect(result.response.status == .unauthorized)
    }

    @Test("requireApiAuth returns invalid_token when token present but invalid")
    func requireApiAuthInvalidToken() async throws {
        let plug = requireApiAuth()
        let conn = TestConnection.build(
            headers: [.authorization: "Bearer invalid-token"]
        )

        let result = try await plug(conn)

        #expect(result.isHalted)
        #expect(result.response.status == .unauthorized)
        let wwwAuth = result.response.headerFields[HTTPField.Name("WWW-Authenticate")!]
        #expect(wwwAuth?.contains("invalid_token") == true)
    }

    @Test("requireApiAuth passes authenticated API requests")
    func requireApiAuthPassesAuthenticated() async throws {
        let plug = requireApiAuth()
        let conn = TestConnection.build(
            headers: [.authorization: "Bearer some-token"]
        ).setBearerUser(TestUser())

        let result = try await plug(conn)

        #expect(!result.isHalted)
    }

    @Test("optionalAuth is a no-op")
    func optionalAuthIsNoOp() async throws {
        let plug = optionalAuth()
        let conn = TestConnection.build()

        let result = try await plug(conn)

        #expect(!result.isHalted)
    }

    @Test("fetchSessionUser loads user when session has userID")
    func fetchSessionUserLoads() async throws {
        let plug = fetchSessionUser { userID, _ -> TestUser? in
            if userID == "user-42" {
                return TestUser(id: "user-42")
            }
            return nil
        }

        // Simulate a connection with user ID in session data
        var conn = TestConnection.build()
        conn = conn.assign(key: SessionDataKey.storageKey, value: ["_roost_user_id": "user-42"] as [String: any Sendable])

        let result = try await plug(conn)
        #expect(result.currentUser(TestUser.self)?.id == "user-42")
    }

    @Test("fetchBearerUser loads user from bearer token")
    func fetchBearerUserLoads() async throws {
        let plug = fetchBearerUser { token, _ -> TestUser? in
            if token == "valid-token" {
                return TestUser(id: "api-user")
            }
            return nil
        }

        let conn = TestConnection.build(
            headers: [.authorization: "Bearer valid-token"]
        )

        let result = try await plug(conn)
        #expect(result.currentUser(TestUser.self)?.id == "api-user")
        #expect(result.authContext == .api)
    }

    @Test("fetchBearerUser is no-op without Authorization header")
    func fetchBearerUserNoHeader() async throws {
        let plug = fetchBearerUser { _, _ -> TestUser? in
            TestUser() // Should never be called
        }

        let conn = TestConnection.build()
        let result = try await plug(conn)
        #expect(!result.isAuthenticated)
    }
}

// MARK: - HTTP Response Helper Tests

@Suite("Auth — Response Helpers")
struct ResponseHelperTests {

    @Test("unauthorized sets 401 status and WWW-Authenticate header")
    func unauthorizedResponse() {
        let conn = TestConnection.build()
        let result = conn.unauthorized(realm: "MyApp")

        #expect(result.response.status == .unauthorized)
        #expect(result.isHalted)
        let header = result.response.headerFields[HTTPField.Name("WWW-Authenticate")!]
        #expect(header == "Bearer realm=\"MyApp\"")
    }

    @Test("unauthorized with error includes error parameter")
    func unauthorizedWithError() {
        let conn = TestConnection.build()
        let result = conn.unauthorized(realm: "API", error: "invalid_token")

        let header = result.response.headerFields[HTTPField.Name("WWW-Authenticate")!]
        #expect(header == "Bearer realm=\"API\", error=\"invalid_token\"")
    }

    @Test("forbidden sets 403 status")
    func forbiddenResponse() {
        let conn = TestConnection.build()
        let result = conn.forbidden()

        #expect(result.response.status == .forbidden)
        #expect(result.isHalted)
    }
}

// MARK: - Test Helpers

/// Build a connection that has gone through the session plug.
private func withSession(
    store: MemorySessionStore,
    sessionID: String? = nil
) async throws -> Connection {
    var conn: Connection
    if let sessionID {
        conn = connWithSessionCookie(sessionID)
    } else {
        conn = TestConnection.build()
    }
    let plug = session(store: store)
    return try await plug(conn)
}

/// Build a connection with a session cookie.
private func connWithSessionCookie(
    _ sessionID: String,
    cookieName: String = "_roost_session"
) -> Connection {
    var conn = TestConnection.build()
    conn = conn.putReqHeader(HTTPField.Name("Cookie")!, "\(cookieName)=\(sessionID)")
    return conn
}

/// Extension to access the internal storage key for SessionDataKey in tests.
extension SessionDataKey {
    static var storageKey: String { String(describing: SessionDataKey.self) }
}

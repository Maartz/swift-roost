import Foundation
import Nexus
import NexusTest
import Testing

@testable import Roost

// MARK: - Test Scope Types

/// Minimal AuthScope for testing.
struct TestScope: AuthScope, Equatable {
    let userId: String?

    static var scopeName: String { "test" }
    var scopeId: String? { userId }

    init(userId: String? = nil) {
        self.userId = userId
    }
}

/// Test user that conforms to UserRoleProvider.
struct RoleUser: Authenticatable, UserRoleProvider, Equatable {
    let id: String
    let role: String

    var authID: String { id }

    init(id: String = "user-1", role: String = "user") {
        self.id = id
        self.role = role
    }
}

/// Test user that conforms to PermissionProvider.
struct PermUser: Authenticatable, PermissionProvider, Equatable {
    let id: String
    let permissions: Set<String>

    var authID: String { id }

    init(id: String = "user-1", permissions: Set<String> = []) {
        self.id = id
        self.permissions = permissions
    }

    func hasPermission(_ permission: String) -> Bool {
        permissions.contains(permission)
    }
}

// MARK: - AuthScope Protocol Tests

@Suite("Scope — AuthScope Protocol")
struct AuthScopeProtocolTests {

    @Test("scopeName defaults to type name")
    func defaultScopeName() {
        #expect(TestScope.scopeName == "test")
    }

    @Test("isEmpty is true when scopeId is nil")
    func emptyScope() {
        let scope = TestScope(userId: nil)
        #expect(scope.isEmpty)
    }

    @Test("isEmpty is false when scopeId is present")
    func nonEmptyScope() {
        let scope = TestScope(userId: "abc")
        #expect(!scope.isEmpty)
    }

    @Test("scopeId returns the stored value")
    func scopeIdReturnsValue() {
        let scope = TestScope(userId: "user-42")
        #expect(scope.scopeId == "user-42")
    }
}

// MARK: - Connection Scope Extension Tests

@Suite("Scope — Connection Extensions")
struct ConnectionScopeTests {

    @Test("setScope and currentScope round-trip")
    func setAndGetScope() {
        let conn = TestConnection.build()
        let scope = TestScope(userId: "user-42")

        let updated = conn.setScope(scope)

        let loaded = updated.currentScope(TestScope.self)
        #expect(loaded == scope)
        #expect(loaded?.scopeId == "user-42")
    }

    @Test("currentScope returns nil when no scope set")
    func noScopeReturnsNil() {
        let conn = TestConnection.build()
        #expect(conn.currentScope(TestScope.self) == nil)
    }

    @Test("currentScope returns nil for wrong type")
    func wrongTypeReturnsNil() {
        struct OtherScope: AuthScope {
            static var scopeName: String { "other" }
            var scopeId: String? { "x" }
        }

        let conn = TestConnection.build().setScope(TestScope(userId: "abc"))
        #expect(conn.currentScope(OtherScope.self) == nil)
    }

    @Test("hasScope is true when non-empty scope is set")
    func hasScopeTrue() {
        let conn = TestConnection.build().setScope(TestScope(userId: "abc"))
        #expect(conn.hasScope)
    }

    @Test("hasScope is false when no scope is set")
    func hasScopeFalseNoScope() {
        let conn = TestConnection.build()
        #expect(!conn.hasScope)
    }

    @Test("hasScope is false when empty scope is set")
    func hasScopeFalseEmptyScope() {
        let conn = TestConnection.build().setScope(TestScope(userId: nil))
        #expect(!conn.hasScope)
    }

    @Test("A scope's ID has the type of the entity's primary key")
    func typedScopeID() {
        struct ReaderScope: AuthScope {
            let userID: UUID
            var scopeId: UUID? { userID }
        }
        let id = UUID()
        let scope = TestConnection.build().setScope(ReaderScope(userID: id)).currentScope(ReaderScope.self)
        let scopeID: UUID? = scope?.scopeId
        #expect(scopeID == id)
    }

    @Test("requireScope returns the scope that was set")
    func requireScopeReturnsScope() throws {
        let conn = TestConnection.build().setScope(TestScope(userId: "abc"))
        #expect(try conn.requireScope(TestScope.self) == TestScope(userId: "abc"))
    }

    @Test("requireScope is a 401 when no scope, an empty scope, or another type is set", arguments: [
        TestConnection.build(),
        TestConnection.build().setScope(TestScope(userId: nil)),
        TestConnection.build().setScope(UUIDScope(id: UUID())),
    ])
    func requireScopeUnauthorized(conn: Connection) {
        #expect {
            try conn.requireScope(TestScope.self)
        } throws: { error in
            (error as? NexusHTTPError)?.status == .unauthorized
        }
    }

    @Test("logoutUser clears the scope")
    func logoutClearsScope() {
        let conn = TestConnection.build()
            .setCurrentUser(RoleUser())
            .setScope(TestScope(userId: "user-1"))
            .logoutUser()
        #expect(conn.currentScope(TestScope.self) == nil)
        #expect(!conn.isAuthenticated)
    }
}

private struct UUIDScope: AuthScope {
    let id: UUID
    var scopeId: UUID? { id }
}

// MARK: - requireRole Plug Tests

@Suite("Scope — requireRole")
struct RequireRoleTests {

    @Test("requireRole passes when user has matching role")
    func matchingRole() async throws {
        let plug = requireRole("moderator")
        let conn = TestConnection.build()
            .setCurrentUser(RoleUser(role: "moderator"))

        let result = try await plug(conn)

        #expect(!result.isHalted)
    }

    @Test("requireRole passes when user is admin")
    func adminBypassesAll() async throws {
        let plug = requireRole("moderator")
        let conn = TestConnection.build()
            .setCurrentUser(RoleUser(role: "admin"))

        let result = try await plug(conn)

        #expect(!result.isHalted)
    }

    @Test("requireRole returns 403 when role doesn't match")
    func wrongRole() async throws {
        let plug = requireRole("admin")
        let conn = TestConnection.build()
            .setCurrentUser(RoleUser(role: "user"))

        let result = try await plug(conn)

        #expect(result.isHalted)
        #expect(result.response.status == .forbidden)
    }

    @Test("requireRole returns 403 when no user is authenticated")
    func noUser() async throws {
        let plug = requireRole("admin")
        let conn = TestConnection.build()

        let result = try await plug(conn)

        #expect(result.isHalted)
        #expect(result.response.status == .forbidden)
    }

    @Test("requireRole returns 403 when user doesn't conform to UserRoleProvider")
    func nonRoleUser() async throws {
        // TestUser from AuthTests doesn't conform to UserRoleProvider
        let plug = requireRole("admin")
        let conn = TestConnection.build()
            .setCurrentUser(TestUser())

        let result = try await plug(conn)

        #expect(result.isHalted)
        #expect(result.response.status == .forbidden)
    }

    @Test("requireRole redirects when redirectTo is set")
    func redirectOnFailure() async throws {
        let plug = requireRole("admin", redirectTo: "/forbidden")
        let conn = TestConnection.build()
            .setCurrentUser(RoleUser(role: "user"))

        let result = try await plug(conn)

        #expect(result.isHalted)
        #expect(result.response.status == .seeOther)
    }
}

// MARK: - requirePermission Plug Tests

@Suite("Scope — requirePermission")
struct RequirePermissionTests {

    @Test("requirePermission passes when user has permission")
    func hasPermission() async throws {
        let plug = requirePermission("posts.create")
        let conn = TestConnection.build()
            .setCurrentUser(PermUser(permissions: ["posts.create", "posts.read"]))

        let result = try await plug(conn)

        #expect(!result.isHalted)
    }

    @Test("requirePermission returns 403 when user lacks permission")
    func lacksPermission() async throws {
        let plug = requirePermission("posts.delete")
        let conn = TestConnection.build()
            .setCurrentUser(PermUser(permissions: ["posts.create"]))

        let result = try await plug(conn)

        #expect(result.isHalted)
        #expect(result.response.status == .forbidden)
    }

    @Test("requirePermission returns 403 when no user is authenticated")
    func noUser() async throws {
        let plug = requirePermission("posts.create")
        let conn = TestConnection.build()

        let result = try await plug(conn)

        #expect(result.isHalted)
        #expect(result.response.status == .forbidden)
    }

    @Test("requirePermission returns 403 when user doesn't conform to PermissionProvider")
    func nonPermissionUser() async throws {
        let plug = requirePermission("posts.create")
        let conn = TestConnection.build()
            .setCurrentUser(RoleUser(role: "admin"))

        let result = try await plug(conn)

        #expect(result.isHalted)
        #expect(result.response.status == .forbidden)
    }

    @Test("requirePermission redirects when redirectTo is set")
    func redirectOnFailure() async throws {
        let plug = requirePermission("admin.panel", redirectTo: "/no-access")
        let conn = TestConnection.build()
            .setCurrentUser(PermUser(permissions: []))

        let result = try await plug(conn)

        #expect(result.isHalted)
        #expect(result.response.status == .seeOther)
    }
}

// MARK: - fetchScope Plug Tests

@Suite("Scope — fetchScope")
struct FetchScopeTests {

    @Test("fetchScope loads scope from authenticated user")
    func loadsFromUser() async throws {
        let plug = fetchScope { user, _ -> TestScope in
            if let user = user {
                return TestScope(userId: user.authID)
            }
            return TestScope(userId: nil)
        }

        let conn = TestConnection.build()
            .setCurrentUser(RoleUser(id: "user-42"))

        let result = try await plug(conn)

        let scope = result.currentScope(TestScope.self)
        #expect(scope?.userId == "user-42")
        #expect(result.hasScope)
    }

    @Test("fetchScope creates empty scope for unauthenticated request")
    func emptyForGuest() async throws {
        let plug = fetchScope { user, _ -> TestScope in
            if let user = user {
                return TestScope(userId: user.authID)
            }
            return TestScope(userId: nil)
        }

        let conn = TestConnection.build()
        let result = try await plug(conn)

        let scope = result.currentScope(TestScope.self)
        #expect(scope?.isEmpty == true)
        #expect(!result.hasScope)
    }
}

// MARK: - ScopeMetadata Tests

@Suite("Scope — ScopeMetadata")
struct ScopeMetadataTests {

    @Test("ScopeMetadata stores correct values")
    func storesValues() {
        let meta = ScopeMetadata(
            name: "user",
            isDefault: true,
            schemaKey: "user_id",
            schemaType: "UUID",
            schemaTable: "users"
        )

        #expect(meta.name == "user")
        #expect(meta.isDefault)
        #expect(meta.schemaKey == "user_id")
        #expect(meta.schemaType == "UUID")
        #expect(meta.schemaTable == "users")
        #expect(meta.routePrefix == nil)
    }

    @Test("ScopeMetadata defaults")
    func defaults() {
        let meta = ScopeMetadata(name: "session", schemaKey: "session_id")

        #expect(!meta.isDefault)
        #expect(meta.assignKey == "_roost_current_scope")
        #expect(meta.schemaType == "UUID")
        #expect(meta.schemaTable == nil)
        #expect(meta.routePrefix == nil)
    }

    @Test("ScopeMetadata equality")
    func equality() {
        let a = ScopeMetadata(name: "user", schemaKey: "user_id")
        let b = ScopeMetadata(name: "user", schemaKey: "user_id")
        #expect(a == b)
    }
}

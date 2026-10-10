import Nexus

/// How the current request's user authenticated.
public enum AuthContext: String, Sendable {
    /// A browser session, from ``Nexus/Connection/loginUser(_:remember:token:)``.
    case session
    /// A bearer token, from ``Nexus/Connection/setBearerUser(_:)``.
    case api
}

/// String-based assign keys for authentication state.
@available(*, deprecated, message: """
    Read authentication state with currentUser(_:), authenticatedUserID, authContext, \
    and currentScope(_:). Roost 3.0 removes these string keys.
    """)
public enum AuthAssign {
    /// The currently authenticated user (type-erased).
    public static let currentUser = "_roost_current_user"

    /// The authenticated user's ID string.
    public static let currentUserID = "_roost_current_user_id"

    /// Auth context: `"session"` or `"api"`.
    public static let authContext = "_roost_auth_context"

    /// The currently active scope (type-erased).
    public static let currentScope = "_roost_current_scope"
}

// MARK: - Typed keys

// Nexus stores a typed assign under `String(describing:)` of its key type, so
// these types are named after the strings `AuthAssign` exposes. Typed and
// string access share one slot, and apps that still use `AuthAssign` keep
// working. Roost 3.0 renames them when it removes `AuthAssign`.

// swiftlint:disable type_name
enum _roost_current_user: AssignKey { typealias Value = any Authenticatable }
enum _roost_current_user_id: AssignKey { typealias Value = String }
enum _roost_auth_context: AssignKey { typealias Value = String }
enum _roost_current_scope: AssignKey { typealias Value = any AuthScope }
// swiftlint:enable type_name

typealias CurrentUserKey = _roost_current_user
typealias CurrentUserIDKey = _roost_current_user_id
typealias AuthContextKey = _roost_auth_context
typealias CurrentScopeKey = _roost_current_scope

extension Connection {
    /// Stores `user` as the authenticated user.
    func roost_authenticate(_ user: some Authenticatable, context: AuthContext?) -> Connection {
        let conn = assign(CurrentUserKey.self, value: user)
            .assign(CurrentUserIDKey.self, value: user.authID)
        guard let context else { return conn }
        return conn.assign(AuthContextKey.self, value: context.rawValue)
    }

    /// Removes the authenticated user, how they authenticated, and the scope.
    func roost_clearAuthentication() -> Connection {
        var conn = self
        for key: any AssignKey.Type in [CurrentUserKey.self, CurrentUserIDKey.self, AuthContextKey.self, CurrentScopeKey.self] {
            conn.assigns.removeValue(forKey: String(describing: key))
        }
        return conn
    }
}

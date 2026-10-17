import Foundation
import HTTPTypes
import Nexus

// MARK: - Role-Based Authorization

/// Require the authenticated user to have a specific role.
///
/// The current user (see ``Nexus/Connection/currentUser(_:)``) must conform to
/// ``UserRoleProvider``. If it doesn't, or the role doesn't match,
/// the request is halted with a 403 or redirected.
///
/// Admins (role `"admin"`) bypass all role checks.
///
/// ```swift
/// // In a pipeline:
/// pipeline("admin") {
///     requireAuth()
///     requireRole("admin")
/// }
/// ```
///
/// - Parameters:
///   - role: The required role string (e.g. `"admin"`, `"moderator"`).
///   - redirectTo: If set, redirect instead of returning 403.
/// - Returns: A plug that enforces the role check.
public func requireRole(
    _ role: String,
    redirectTo: String? = nil
) -> Plug {
    return { conn in
        // Must be authenticated
        guard conn.isAuthenticated,
              let user = conn.roost_untypedAssign(CurrentUserKey.self)
        else {
            return haltForbiddenOrRedirect(conn, redirectTo: redirectTo)
        }

        // User must conform to UserRoleProvider
        guard let provider = user as? UserRoleProvider else {
            return haltForbiddenOrRedirect(conn, redirectTo: redirectTo)
        }

        // Admin bypasses all role checks
        if provider.role == "admin" { return conn }

        // Check role
        if provider.role == role { return conn }

        return haltForbiddenOrRedirect(conn, redirectTo: redirectTo)
    }
}

// MARK: - Permission-Based Authorization

/// Require the authenticated user to have a specific permission.
///
/// The current user (see ``Nexus/Connection/currentUser(_:)``) must conform to
/// ``PermissionProvider``. If it doesn't, or the permission check fails,
/// the request is halted with a 403 or redirected.
///
/// ```swift
/// pipeline("posts_write") {
///     requireAuth()
///     requirePermission("posts.create")
/// }
/// ```
///
/// - Parameters:
///   - permission: The required permission (e.g. `"posts.create"`).
///   - redirectTo: If set, redirect instead of returning 403.
/// - Returns: A plug that enforces the permission check.
public func requirePermission(
    _ permission: String,
    redirectTo: String? = nil
) -> Plug {
    return { conn in
        guard conn.isAuthenticated,
              let user = conn.roost_untypedAssign(CurrentUserKey.self)
        else {
            return haltForbiddenOrRedirect(conn, redirectTo: redirectTo)
        }

        guard let provider = user as? PermissionProvider else {
            return haltForbiddenOrRedirect(conn, redirectTo: redirectTo)
        }

        if provider.hasPermission(permission) { return conn }

        return haltForbiddenOrRedirect(conn, redirectTo: redirectTo)
    }
}

// MARK: - Scope Loading

/// Build a plug that loads a scope from the current user and stores it
/// with ``Nexus/Connection/setScope(_:)``.
///
/// The `loader` closure receives the authenticated user (if any) and the
/// connection, and returns a scope value. If there's no authenticated
/// user, `nil` is passed.
///
/// ```swift
/// // In your plug pipeline:
/// fetchScope { user, conn -> UserScope in
///     UserScope(userID: (user as? User)?.id)  // nil for a guest
/// }
/// ```
///
/// - Parameter loader: A closure that builds the scope from the current user.
/// - Returns: A plug that sets the scope ``Nexus/Connection/currentScope(_:)`` returns.
public func fetchScope<S: AuthScope>(
    _ loader: @escaping @Sendable (
        (any Authenticatable)?, Connection
    ) async throws -> S
) -> Plug {
    return { conn in
        let user = conn[CurrentUserKey.self]
        let scope = try await loader(user, conn)
        return conn.setScope(scope)
    }
}

// MARK: - Private Helpers

/// Halt with 403 or redirect, depending on configuration.
private func haltForbiddenOrRedirect(
    _ conn: Connection,
    redirectTo: String?
) -> Connection {
    if let path = redirectTo {
        return conn.redirect(to: path, status: .seeOther)
    }
    return conn.forbidden()
}

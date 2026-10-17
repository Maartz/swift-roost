import Roost

/// Fetch once for both browser routes and cookie-authenticated JSON routes.
/// Protected scopes use Roost's `requireAuth()` after this plug.
func fetchCurrentUser() -> Plug {
    { conn in
        guard let token = conn.authSessionToken else { return conn }
        guard let user = try await AccountsContext(repo: conn.repo()).user(for: token) else {
            return conn.logoutUser()
        }
        return conn.setCurrentUser(user).setScope(ReaderScope(userID: user.id))
    }
}

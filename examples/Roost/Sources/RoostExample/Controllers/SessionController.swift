import Roost

struct SessionController: Controller {
    enum Action: String, ControllerAction {
        case new, create, delete
    }

    static func action(_ action: Action) -> Plug {
        switch action {
        case .new: new
        case .create: create
        case .delete: delete
        }
    }

    static func new(_ conn: Connection) async throws -> Connection {
        try conn.render(LoginView(error: conn.flash.error), title: "Log in")
    }

    static func create(_ conn: Connection) async throws -> Connection {
        let email = conn.bodyParams["email"] ?? ""
        guard let form = try? conn.permit(Credentials.self),
              let (user, token) = try await AccountsContext(repo: conn.repo()).login(
                email: form.email, password: form.password) else {
            return try conn.render(LoginView(email: email, error: "Invalid email or password"), title: "Log in", status: .unprocessableContent)
        }
        await RoostExample.readingQueue.invalidate(conn)
        return conn.loginUser(user, token: token).0.putFlash(.info, "Logged in").redirect(to: "/")
    }

    static func delete(_ conn: Connection) async throws -> Connection {
        await RoostExample.readingQueue.invalidate(conn)
        if let token = conn.authSessionToken {
            try await AccountsContext(repo: conn.repo()).revoke(token: token)
        }
        return conn.logoutUser().renewSessionID().deleteSession("_csrf_token").redirect(to: "/auth/login")
    }
}

import Roost

struct RegistrationController: Controller {
    enum Action: String, ControllerAction {
        case new, create
    }

    static func action(_ action: Action) -> Plug {
        switch action {
        case .new: new
        case .create: create
        }
    }

    static func new(_ conn: Connection) async throws -> Connection {
        try conn.render(RegisterView(), title: "Register")
    }

    static func create(_ conn: Connection) async throws -> Connection {
        let email = conn.bodyParams["email"] ?? ""
        do {
            let form = try conn.permit(Credentials.self)
            let (user, token) = try await AccountsContext(repo: conn.repo()).register(
                email: form.email, password: form.password)
            await RoostExample.readingQueue.invalidate(conn)
            return conn.loginUser(user, token: token).0.putFlash(.info, "Account created").redirect(to: "/")
        } catch let errors as ValidationErrors {
            let message = errors.fieldErrors.sorted { $0.key < $1.key }.flatMap { $0.value }.joined(separator: ". ")
            return try conn.render(RegisterView(email: email, error: message), title: "Register", status: .unprocessableContent)
        }
    }
}

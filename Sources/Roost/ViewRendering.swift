import ESW
import Foundation
import HTTPTypes
import Nexus

/// A layout receives the current connection, page title, and rendered content.
/// Set `RoostApp.layout` once to apply it to every `conn.render(...)` response.
public typealias HTMLLayout = @Sendable (Connection, String, String) -> String

enum HTMLLayoutKey: AssignKey {
    typealias Value = HTMLLayout
}

public enum ViewRenderingError: Error, Sendable, CustomStringConvertible {
    case missingCSRFContext, invalidFormAction, invalidFormMethod, invalidFormAttribute, invalidFieldAttribute

    public var description: String {
        switch self {
        case .missingCSRFContext: "Render browser forms with conn.render(...) after session and browserPlugs()."
        case .invalidFormAction: "Form actions must be relative URLs or HTTP(S) URLs without whitespace, credentials, or backslashes."
        case .invalidFormMethod: "Form methods must be GET, POST, PUT, PATCH, or DELETE."
        case .invalidFormAttribute: "Invalid or reserved form attribute."
        case .invalidFieldAttribute: "Invalid or reserved field attribute. Use the component's named arguments for field attributes."
        }
    }
}

extension Connection {
    /// Renders a typed view and the application's layout in one request scope.
    /// Forms use the existing middleware token. A misconfigured form rejects the
    /// entire response instead of emitting an unprotected form or empty token.
    public func render<View: ESWView>(
        _ view: View, title: String = "", status: HTTPResponse.Status = .ok
    ) throws -> Connection where View.Output == String {
        let context = FormRenderContext(connection: self)
        let rendered = FormRenderContext.$current.withValue(context) {
            let content = view.render()
            return self[HTMLLayoutKey.self]?(self, title, content) ?? content
        }
        if let error = context.error { throw error }
        return html(rendered, status: status)
    }
}

/// A fresh scope per render, inherited only by that task's children. The lock
/// protects error recording if a user component performs concurrent work.
final class FormRenderContext: @unchecked Sendable {
    @TaskLocal static var current: FormRenderContext?
    let connection: Connection
    private let lock = NSLock()
    private var failure: ViewRenderingError?

    init(connection: Connection) { self.connection = connection }

    var error: ViewRenderingError? { lock.withLock { failure } }

    func record(_ error: ViewRenderingError) {
        lock.withLock { if failure == nil { failure = error } }
    }
}

import ESWLive
import Nexus

/// An ESW interactive page whose handlers receive the current Roost request.
/// Use its repository and authenticated scope just as in a controller. State
/// should contain page data, never a retained Connection or transaction.
public protocol LivePage: Interactive {
    func mount(_ conn: Connection, context: LiveContext) async throws -> State
    func handleEvent(_ event: LiveEvent, state: State, conn: Connection) async throws -> State
}

extension LivePage {
    public func mount(_ context: LiveContext) async throws -> State {
        guard let conn = LiveRequest.connection else { throw LiveError.unauthorized }
        return try await mount(conn, context: context)
    }

    public func handleEvent(_ event: LiveEvent, state: State) async throws -> State {
        guard let conn = LiveRequest.connection else { throw LiveError.unauthorized }
        return try await handleEvent(event, state: state, conn: conn)
    }
}

enum LiveRequest {
    @TaskLocal static var connection: Connection?

    /// ESW's queued operations inherit these task locals from the submitting
    /// request, including when they wait for a previous event to finish.
    static func withConnection<T>(_ conn: Connection, operation: () async throws -> T) async throws -> T {
        let forms = FormRenderContext(connection: conn)
        return try await $connection.withValue(conn) {
            try await FormRenderContext.$current.withValue(forms) {
                let result = try await operation()
                if let error = forms.error { throw error }
                return result
            }
        }
    }
}

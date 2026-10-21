import ESWLive
import Nexus

/// An ESW interactive page whose handlers receive the current Roost request.
/// Use its repository and authenticated scope just as in a controller. State
/// should contain page data, never a retained Connection or transaction.
public protocol LivePage: Interactive {
    /// Messages the server sends to open pages with ``LiveRoute/broadcast(_:to:)``,
    /// like the messages a Phoenix LiveView receives in `handle_info`.
    associatedtype Info: Sendable = Never

    func mount(_ conn: Connection, context: LiveContext) async throws -> State
    func handleEvent(_ event: LiveEvent, state: State, conn: Connection) async throws -> State

    /// The topics this page listens to, decided when it's rendered. Default: none.
    func topics(_ conn: Connection, context: LiveContext) throws -> [String]

    /// Updates the state for a message broadcast to one of the page's topics.
    /// `conn` is the request of the page's open stream, with its repository
    /// and authenticated scope. Default: the state, unchanged.
    func handleInfo(_ info: Info, state: State, conn: Connection) async throws -> State
}

extension LivePage {
    public func topics(_ conn: Connection, context: LiveContext) throws -> [String] { [] }

    public func handleInfo(_ info: Info, state: State, conn: Connection) async throws -> State { state }

    public func mount(_ context: LiveContext) async throws -> State {
        guard let conn = LiveRequest.connection else { throw LiveError.unauthorized }
        return try await mount(conn, context: context)
    }

    public func handleEvent(_ event: LiveEvent, state: State) async throws -> State {
        guard let conn = LiveRequest.connection else { throw LiveError.unauthorized }
        guard event.name == LiveRequest.infoEvent else { return try await handleEvent(event, state: state, conn: conn) }
        // Only broadcast sets the message, so a browser can't send one.
        guard let info = LiveRequest.info as? Info else { throw LiveError.invalidEvent }
        return try await handleInfo(info, state: state, conn: conn)
    }
}

enum LiveRequest {
    @TaskLocal static var connection: Connection?
    @TaskLocal static var info: (any Sendable)?
    /// The instance whose handler is running. Its own broadcasts skip it.
    @TaskLocal static var instance: String?

    /// The event name that carries a broadcast message to ``LivePage/handleInfo(_:state:conn:)``.
    static let infoEvent = "_roost_info"

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

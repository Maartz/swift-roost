import Roost

struct BookmarksLive: LivePage {
    /// A change made in another tab, or through the HTML or JSON controllers.
    enum Info: Sendable { case changed }

    struct State: Sendable {
        let readerID: UUID
        let filter: ReadingFilter
        var bookmarks: [Bookmark]
    }

    func mount(_ conn: Connection, context: LiveContext) async throws -> State {
        let reader = try conn.requireScope(ReaderScope.self)
        return try await State(
            readerID: reader.userID,
            filter: ReadingFilter(rawValue: context.parameters["filter"] ?? "") ?? .unread,
            bookmarks: conn.bookmarks().listBookmarks()
        )
    }

    func handleEvent(_ event: LiveEvent, state: State, conn: Connection) async throws -> State {
        guard try conn.requireScope(ReaderScope.self).userID == state.readerID else { throw LiveError.unauthorized }
        guard event.name == "read", let rawID = event.value("id"), let id = UUID(uuidString: rawID),
              let rawRead = event.value("read"), ["true", "false"].contains(rawRead) else { throw LiveError.invalidEvent }
        let context = try conn.bookmarks()
        // The same owner-scoped action as the ordinary POST endpoint. Set a value;
        // don't invert it, so repeated intent cannot accidentally undo a change.
        try await context.setRead(id: id, read: rawRead == "true")
        var next = state
        next.bookmarks = try await context.listBookmarks()
        return next
    }

    func topics(_ conn: Connection, context: LiveContext) throws -> [String] {
        [try conn.bookmarks().topic]
    }

    func handleInfo(_ info: Info, state: State, conn: Connection) async throws -> State {
        guard try conn.requireScope(ReaderScope.self).userID == state.readerID else { throw LiveError.unauthorized }
        var next = state
        next.bookmarks = try await conn.bookmarks().listBookmarks()
        return next
    }

    func render(_ state: State) -> ESWLiveRender {
        BookmarksLiveView(bookmarks: state.bookmarks, filter: state.filter).render()
    }
}

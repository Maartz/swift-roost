import Roost

/// The reading queue as JSON, for the signed-in reader's session.
struct BookmarkAPIController: Controller {
    enum Action: String, ControllerAction {
        case index, show, create, update, delete
    }

    static func action(_ action: Action) -> Plug {
        switch action {
        case .index: index
        case .show: show
        case .create: create
        case .update: update
        case .delete: delete
        }
    }

    static func index(_ conn: Connection) async throws -> Connection {
        try conn.json(value: await conn.bookmarks().listBookmarks())
    }

    static func show(_ conn: Connection) async throws -> Connection {
        let id: UUID = try conn.requireParam("id")
        return try conn.json(value: await conn.bookmarks().getBookmark(id: id))
    }

    static func create(_ conn: Connection) async throws -> Connection {
        let context = try conn.bookmarks()
        do {
            return try conn.json(status: .created, value: await context.createBookmark(conn.permit(Bookmark.editable)))
        } catch let errors as ValidationErrors {
            return try conn.json(status: .unprocessableContent, value: errors)
        }
    }

    static func update(_ conn: Connection) async throws -> Connection {
        let context = try conn.bookmarks()
        let id: UUID = try conn.requireParam("id")
        do {
            return try conn.json(value: await context.updateBookmark(id: id, with: conn.permit(Bookmark.editable)))
        } catch let errors as ValidationErrors {
            return try conn.json(status: .unprocessableContent, value: errors)
        }
    }

    static func delete(_ conn: Connection) async throws -> Connection {
        let id: UUID = try conn.requireParam("id")
        try await conn.bookmarks().deleteBookmark(id: id)
        return try conn.json(value: ["deleted": true])
    }
}

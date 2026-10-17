import Roost

/// One reader's bookmarks. Every query and write goes through `bookmarks`,
/// which only reaches rows the reader owns, including in tests that pass a
/// transaction repository.
struct BookmarksContext: Sendable {
    let bookmarks: ScopedRepo<Bookmark, UUID>

    init(repo: any Repo, reader: ReaderScope) {
        bookmarks = repo.scoped(\Bookmark.userId, to: reader.userID)
    }

    func listBookmarks() async throws -> [Bookmark] {
        try await bookmarks.query().orderBy(\.createdAt, .asc).all()
    }

    func getBookmark(id: UUID) async throws -> Bookmark {
        try await bookmarks.get(id)
    }

    func createBookmark(_ changes: Changes<Bookmark>) async throws -> Bookmark {
        try await bookmarks.insert(Bookmark.validate(changes))
    }

    func updateBookmark(id: UUID, with changes: Changes<Bookmark>) async throws -> Bookmark {
        try await bookmarks.update(id, Bookmark.validate(changes))
    }

    func deleteBookmark(id: UUID) async throws {
        try await bookmarks.delete(id)
    }

    /// A separate domain action keeps a reading-state change from replacing the saved link.
    func setRead(id: UUID, read: Bool) async throws {
        _ = try await bookmarks.update(id, Changes().setting(\.read, to: read))
    }
}

extension Bookmark {
    /// The fields a reader edits, in the HTML form and the JSON API.
    static let editable = Permitted<Bookmark>(\.title, \.url, \.note, \.read)

    /// Trims the submitted text and checks it before it is saved.
    static func validate(_ changes: Changes<Bookmark>) async throws -> Changes<Bookmark> {
        try await changes.trimmingWhitespace().validated(using: [
            .required(\.title),
            .length(\.title, max: 160),
            .length(\.note, max: 2000),
            .custom(\.url) { isWebLink($0) ? nil : "Enter a complete http:// or https:// link" },
        ])
    }

    /// A complete http:// or https:// link, without credentials or spaces.
    private static func isWebLink(_ link: String) -> Bool {
        guard let url = URLComponents(string: link),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return false }
        return url.user == nil && url.password == nil && !link.contains(where: { $0.isWhitespace })
    }
}

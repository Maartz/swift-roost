import Roost

/// Only called with ROOST_DEMO=1 in development. Existing accounts are left alone.
func seedDemo(repo: any Repo) async throws {
    let email = "reader@roost.test"
    guard try await repo.query(User.self).where({ $0.email == email }).first() == nil else { return }
    let (user, _) = try await AccountsContext(repo: repo).register(
        email: email, password: "Read-with-Roost-2026"
    )
    let context = BookmarksContext(repo: repo, reader: ReaderScope(userID: user.id))
    let links: [(String, String, String, Bool)] = [
        ("A tour of Swift", "https://docs.swift.org/swift-book/documentation/the-swift-programming-language/guidedtour/",
         "Revisit the language, one small example at a time.", false),
        ("Designing with contexts", "https://hexdocs.pm/phoenix/contexts.html",
         "A useful reference for keeping domain work out of route handlers.", false),
        ("The ESW template compiler", "https://github.com/roost-framework/ESW",
         "HTML templates that become Swift functions at build time.", false),
        ("Meet Roost", "https://github.com/roost-framework/swift-roost",
         "The framework underneath this little reading list.", true),
    ]
    for (title, url, note, read) in links {
        _ = try await context.createBookmark(Changes()
            .setting(\.title, to: title).setting(\.url, to: url)
            .setting(\.note, to: note).setting(\.read, to: read))
    }
}

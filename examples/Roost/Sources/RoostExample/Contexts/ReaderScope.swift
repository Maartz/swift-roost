import Roost

/// The signed-in reader. `fetchCurrentUser()` sets it, and `BookmarksContext`
/// limits every query and write to the reader's own links.
struct ReaderScope: AuthScope {
    let userID: UUID

    static var scopeName: String { "reader" }
    var scopeId: UUID? { userID }
}

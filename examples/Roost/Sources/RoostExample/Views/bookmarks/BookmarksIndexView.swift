import Roost

/// A String view remains available for ordinary rendering and tests.
struct BookmarksIndexView: ESWView {
    let bookmarks: [Bookmark]
    var filter: ReadingFilter = .unread

    var visible: [Bookmark] { bookmarks.filter { filter.includes($0) } }
    func render() -> String { BookmarksLiveView(bookmarks: bookmarks, filter: filter).render().html }
}

@ESWTemplate("index.live.hesw")
struct BookmarksLiveView {
    let bookmarks: [Bookmark]
    var filter: ReadingFilter = .unread

    var visible: [Bookmark] { bookmarks.filter { filter.includes($0) } }
}

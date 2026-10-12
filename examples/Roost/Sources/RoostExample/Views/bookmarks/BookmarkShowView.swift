import Roost

@ESWTemplate("show.esw")
struct BookmarkShowView {
    let bookmark: Bookmark

    var status: String {
        guard bookmark.read else { return "Saved for later" }
        guard let readAt = bookmark.readAt else { return "Finished reading" }
        return "Finished \(readAt.formatted(date: .abbreviated, time: .omitted))"
    }
}

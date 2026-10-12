import Roost

@Schema("bookmarks")
struct Bookmark {
    @ID var id: UUID
    @ForeignKey var userId: UUID
    @Column var title: String
    @Column var url: String
    @Column var note: String
    @Column var read: Bool
    /// Set by the database when `read` becomes true; see `TrackWhenLinksAreRead`.
    @Column var readAt: Date?
    @Timestamp var createdAt: Date
    @Timestamp var updatedAt: Date
}

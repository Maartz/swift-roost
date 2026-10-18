import Roost

/// A reader's queue is listed oldest first, so one index covers both the owner
/// filter and the order. It replaces the generated index on `user_id` alone.
struct IndexReadingQueues: Migration {
    static let id = "1791704721_index_reading_queues"

    var change: MigrationPlan {
        CreateIndex("bookmarks_user_id_created_at_index", on: "bookmarks", columns: ["user_id", "created_at"])

        SQL(
            up: "DROP INDEX bookmarks_user_id_index",
            down: "CREATE INDEX bookmarks_user_id_index ON bookmarks (user_id)"
        )
    }
}

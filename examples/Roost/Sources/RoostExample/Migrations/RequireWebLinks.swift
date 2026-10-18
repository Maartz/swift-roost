import Roost

/// The database also refuses a link that isn't http:// or https://, including
/// one written without `Bookmark.validate`. The context checks the details.
struct RequireWebLinks: Migration {
    static let id = "1791704722_require_web_links"

    var change: MigrationPlan {
        SQL(
            up: "ALTER TABLE bookmarks ADD CONSTRAINT bookmarks_url_web_link CHECK (url ~* '^https?://[^[:space:]]+$')",
            down: "ALTER TABLE bookmarks DROP CONSTRAINT bookmarks_url_web_link"
        )
    }
}

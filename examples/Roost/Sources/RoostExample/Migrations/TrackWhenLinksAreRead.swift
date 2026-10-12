import Roost

/// Records when each link was finished. The database keeps `read_at` in step
/// with `read`, so the read button, the edit form, and the JSON API agree.
struct TrackWhenLinksAreRead: Migration {
    static let id = "1791704720_track_when_links_are_read"

    var change: MigrationPlan {
        // AlterTable adds columns but cannot drop them, so the rollback is explicit.
        Reversible {
            AlterTable("bookmarks") { table in
                table.add("read_at", .timestamptz)
            }
            // A finished link's last update is the closest time on record.
            SQL("UPDATE bookmarks SET read_at = updated_at WHERE read")
        } down: {
            SQL("ALTER TABLE bookmarks DROP COLUMN read_at")
        }

        SQL(
            up: """
                CREATE FUNCTION bookmarks_track_read_at() RETURNS trigger AS $$
                BEGIN
                    IF NOT NEW.read THEN
                        NEW.read_at := NULL;
                    ELSIF TG_OP = 'INSERT' OR NOT OLD.read THEN
                        NEW.read_at := now();
                    END IF;
                    RETURN NEW;
                END;
                $$ LANGUAGE plpgsql
                """,
            down: "DROP FUNCTION bookmarks_track_read_at()"
        )

        SQL(
            up: """
                CREATE TRIGGER bookmarks_track_read_at
                BEFORE INSERT OR UPDATE OF read ON bookmarks
                FOR EACH ROW EXECUTE FUNCTION bookmarks_track_read_at()
                """,
            down: "DROP TRIGGER bookmarks_track_read_at ON bookmarks"
        )
    }
}

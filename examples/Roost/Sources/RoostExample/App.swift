import Roost

@main
struct RoostExample: RoostApp {
    static let readingQueue = LiveRoute(BookmarksLive(), path: "/_live/bookmarks") { conn in
        _ = try conn.requireScope(ReaderScope.self)
    }

    var services: [any Service] { [Self.readingQueue] }
    let database: Database? = Database.postgres(database: "roost")

    /// The generated SQL history, then the Swift migrations written since.
    /// `RoostExample migrate plan` prints the SQL without a database.
    var migrations: MigrationRegistry? {
        MigrationRegistry {
            SQLMigrations(bundle: .module, directory: "SQL")
            TrackWhenLinksAreRead()
            IndexReadingQueues()
            RequireWebLinks()
        }
    }

    let sessionStore: (any SessionStore)? = KeyValueSessionStore()

    var layout: HTMLLayout? {
        { conn, title, content in LayoutView(conn: conn, title: title, content: content).render() }
    }

    var plugs: [Plug] {
        [requestId(), roost_requestLogger(), roost_staticFiles()] + browserPlugs() + [
            fetchCurrentUser(),
            // roost:plugs
        ]
    }

    @RouteBuilder var routes: [Route] {
        Self.readingQueue.routes
        scope("/auth") { authRoutes() }
        resources("/bookmarks", BookmarkController.self)
        POST("/bookmarks/:id/read", BookmarkController.self, .read)
        scope("/api") { resources("/bookmarks", BookmarkAPIController.self) }
        // roost:routes
        GET("/", PageController.self, .home)
    }

    func willStart(spectro: SpectroClient) async throws {
        if Self.demoMode { try await seedDemo(repo: spectro.repository()) }
    }

    static var demoMode: Bool {
        Roost.env == .dev && ProcessInfo.processInfo.environment["ROOST_DEMO"] == "1"
    }
}

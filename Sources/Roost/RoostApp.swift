import Foundation
import Hummingbird
import Nexus
import NexusHummingbird
import NexusRouter
import Spectro

/// The main application protocol. Conform to this and add `@main` to get
/// a running web server with zero boilerplate.
///
/// Only `routes` is required — everything else has sensible defaults.
public protocol RoostApp {
    /// Database configuration. Return `nil` for apps without a database.
    var database: Database? { get }

    /// The app's migration history, run by `App migrate`. Return `nil` to run the
    /// SQL files in `Sources/Migrations/` instead.
    ///
    /// A registry lists Swift migrations and bundled SQL directories explicitly:
    ///
    /// ```swift
    /// var migrations: MigrationRegistry? {
    ///     MigrationRegistry {
    ///         SQLMigrations(bundle: .module, directory: "SQL")
    ///         AddReadAtToBookmarks()
    ///     }
    /// }
    /// ```
    ///
    /// Declare it optional, as above. A property of type `MigrationRegistry`,
    /// without the `?`, doesn't implement this requirement: Swift accepts it
    /// silently, and `App migrate` keeps running `Sources/Migrations/`.
    ///
    /// Default: `nil`.
    var migrations: MigrationRegistry? { get }

    /// Session store for server-side sessions. Return `nil` for apps that
    /// don't need sessions.
    /// Default: `nil`. Override to use `KeyValueSessionStore()`, which keeps
    /// sessions in ``store``, or another ``SessionStore``.
    var sessionStore: SessionStore? { get }

    /// Where ``Nexus/Connection/store`` keeps values.
    /// Default: ``StoreConfiguration/environment``, which reads
    /// `ROOST_STORE_URL` and falls back to memory.
    var store: StoreConfiguration { get }

    /// Services such as live routes. They stop before the HTTP server drains its
    /// connections, so open event streams cannot hold shutdown open.
    var services: [any Service] { get }

    /// Shared layout applied by `conn.render`. Default: render the view alone.
    var layout: HTMLLayout? { get }

    /// PubSub adapter. Return `nil` for apps that don't need pub/sub.
    /// Default: `nil`. Override to use `PubSub.inMemory()`, which delivers within one process.
    var pubSub: (any RoostPubSub)? { get }

    /// Channel router. Map topic patterns to `Channel` handler types.
    /// Default: empty router (no channels configured).
    var channels: ChannelRouter { get }

    /// Job queue driver. Return `JobQueue.inMemory()`; its jobs don't survive a restart.
    /// Default: `nil` (no job queue configured).
    var jobs: (any RoostJobQueue)? { get }

    /// Recurring jobs to run on a schedule.
    /// Default: `[]` (no scheduled jobs).
    var scheduledJobs: [ScheduledJobEntry] { get }

    /// Called once on WebSocket upgrade to authenticate the socket.
    /// Return assigns (e.g. `["userID": id]`) to attach to the socket, or throw to reject.
    /// Default: returns empty assigns (no authentication).
    func authenticateSocket(_ conn: Connection) async throws -> SocketAssigns

    /// Middleware pipeline applied to every request.
    /// Default: `[requestId(), roost_requestLogger()]`.
    var plugs: [Plug] { get }

    /// Route definitions.
    @RouteBuilder var routes: [Route] { get }

    /// Server binding configuration.
    /// Default: reads from `ROOST_HOST` / `ROOST_PORT` env vars,
    /// falls back to `127.0.0.1:8080`.
    var server: ServerConfig { get }

    /// Called after database is connected but before the server starts
    /// accepting connections. Use for seed data, cache warming, etc.
    ///
    /// Only called when `database` is non-nil.
    func willStart(spectro: SpectroClient) async throws

    /// Called during startup to allow per-environment configuration.
    func configure(for env: Environment)

    /// Optional custom error page renderer. Return a `Connection` to
    /// render your own page, or `nil` to use Roost's default.
    ///
    /// Use this to hook in compiled ESW error templates (e.g. `Views/errors/404.esw`).
    var customErrorPage: ErrorPageRenderer? { get }

    /// Application entry point. A default implementation is provided
    /// that wires everything together and starts the server.
    static func main() async throws

    init()
}

// MARK: - Defaults

extension RoostApp {
    public var database: Database? { nil }

    public var migrations: MigrationRegistry? { nil }

    public var sessionStore: SessionStore? { nil }

    public var store: StoreConfiguration { .environment }

    public var services: [any Service] { [] }

    public var layout: HTMLLayout? { nil }

    public var pubSub: (any RoostPubSub)? { nil }

    public var channels: ChannelRouter { ChannelRouter() }

    public var jobs: (any RoostJobQueue)? { nil }

    public var scheduledJobs: [ScheduledJobEntry] { [] }

    public func authenticateSocket(_ conn: Connection) async throws -> SocketAssigns { [:] }

    public var plugs: [Plug] {
        [requestId(), roost_requestLogger()]
    }

    public var server: ServerConfig {
        ServerConfig.fromEnvironment()
    }

    public func willStart(spectro: SpectroClient) async throws {}

    public func configure(for env: Environment) {}

    public var customErrorPage: ErrorPageRenderer? { nil }
}

// MARK: - Bootstrap

extension RoostApp {
    public static func main() async throws {
        let app = Self()
        app.configure(for: Roost.env)

        let arguments = Array(CommandLine.arguments.dropFirst(2))
        switch CommandLine.arguments.dropFirst().first {
        case "migrate":
            do {
                let status = try await app.runMigrationCommand(arguments)
                if status != 0 { exit(status) }
            } catch {
                FileHandle.standardError.write(Data("Error: \(Self.postgresMessage(error))\n".utf8))
                exit(1)
            }
            return
        case "db":
            let status = await app.runDatabaseCommand(arguments)
            if status != 0 { exit(status) }
            return
        case "routes":
            print(app.roost_routeTable)
            return
        default:
            break
        }

        // A store configuration error stops the app before it opens the database.
        let store = try app.store.resolve(app: String(describing: Self.self), environment: Roost.env)

        // PubSub setup (call once to get a stable shared instance)
        let pubSubAdapter = app.pubSub

        // Channel setup
        let channelRegistry = ChannelRegistry(router: app.channels)

        // Job queue setup
        let jobQueueAdapter = app.jobs
        if let inMemory = jobQueueAdapter as? InMemoryJobQueue {
            inMemory.registerSchedule(app.scheduledJobs)
        }

        // Database setup
        var spectro: SpectroClient?
        if let dbConfig = app.database {
            let client = try SpectroClient(
                hostname: dbConfig.hostname,
                port: dbConfig.port,
                username: dbConfig.username,
                password: dbConfig.password,
                database: dbConfig.database
            )
            spectro = client
            do { try await app.willStart(spectro: client) }
            catch {
                await client.shutdown()
                throw error
            }
        }

        let finalPlug = roost_applicationPipeline(
            app, spectro: spectro, store: store.store, channels: channelRegistry,
            jobs: jobQueueAdapter, pubSub: pubSubAdapter
        )

        // Boot server
        let config = app.server
        if Roost.env != .test {
            print("Roost running on http://\(config.host):\(config.port)")
        }

        let adapter = NexusHummingbirdAdapter(plug: finalPlug)
        // The server stops accepting requests before the store's connections close.
        let server = Application(
            responder: adapter,
            configuration: .init(address: .hostname(config.host, port: config.port)),
            services: store.services
        )

        do {
            let group = ServiceGroup(configuration: .init(
                services: [server] + app.services,
                gracefulShutdownSignals: [.sigterm, .sigint],
                logger: server.logger
            ))
            try await group.run()
        } catch {
            await spectro?.shutdown()
            throw error
        }
        await spectro?.shutdown()
    }
}

// MARK: - Routes

extension RoostApp {
    /// What `App routes` prints, like `mix phx.routes`: each route's method and
    /// path, one per line, in matching order.
    package var roost_routeTable: String {
        let routes = self.routes
        let width = routes.map(\.method.rawValue.count).max() ?? 0
        return routes.map { $0.method.rawValue.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + $0.path }
            .joined(separator: "\n")
    }
}

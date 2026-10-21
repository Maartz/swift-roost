import Foundation
import PostgresNIO
import Spectro

extension RoostApp {
    /// Create, drop, and seed the database with exactly the same configuration
    /// as the server, like Ecto's `mix ecto.create`, `ecto.drop`, `ecto.setup`,
    /// and `ecto.reset`. Available in a compiled release too: `MyApp db setup`.
    ///
    /// - `create`: creates the database unless it exists.
    /// - `drop`: drops the database and closes its connections.
    /// - `seed`: runs `Seeds/<env>.sql` (see ``Seeder``).
    /// - `setup`: `create`, `migrate up`, then `seed` when the seed file exists.
    /// - `reset`: `drop`, then `setup`.
    ///
    /// `drop` and `reset` refuse to run in `.prod`.
    ///
    /// - Returns: The process exit status.
    package func runDatabaseCommand(_ arguments: [String]) async -> Int32 {
        let commands = ["create", "drop", "seed", "setup", "reset"]
        guard arguments.count == 1, commands.contains(arguments[0]) else {
            return Self.databaseCommandFailure("Usage: \(Self.self) db \(commands.joined(separator: "|"))", status: 64)
        }
        let command = arguments[0]
        guard let config = database else {
            return Self.databaseCommandFailure("No database configured in \(Self.self).")
        }
        if Roost.env == .prod, ["drop", "reset"].contains(command) {
            return Self.databaseCommandFailure("Refusing to drop \(config.database) in production.", status: 77)  // EX_NOPERM
        }
        do {
            switch command {
            case "create": try await Self.createDatabase(config)
            case "drop": try await Self.dropDatabase(config)
            case "seed": try await Self.seedDatabase(config, required: true)
            default:
                if command == "reset" { try await Self.dropDatabase(config) }
                try await Self.createDatabase(config)
                let status = try await runMigrationCommand(["up"])
                guard status == 0 else { return status }
                try await Self.seedDatabase(config, required: false)
            }
        } catch {
            return Self.databaseCommandFailure("\(config.hostname):\(config.port): \(Self.postgresMessage(error))")
        }
        return 0
    }

    private static func createDatabase(_ config: Database) async throws {
        try await withClient(config, database: "postgres") { client in
            let repo = client.repository()
            if try await databaseExists(config.database, repo: repo) {
                print("Database \(config.database) already exists.")
            } else {
                try await repo.executeRawSQL("CREATE DATABASE \(quotedIdentifier(config.database))")
                print("Created database \(config.database).")
            }
        }
    }

    private static func dropDatabase(_ config: Database) async throws {
        try await withClient(config, database: "postgres") { client in
            let repo = client.repository()
            if try await databaseExists(config.database, repo: repo) {
                // FORCE (PostgreSQL 13+) closes other sessions, such as a running dev server.
                try await repo.executeRawSQL("DROP DATABASE \(quotedIdentifier(config.database)) WITH (FORCE)")
                print("Dropped database \(config.database).")
            } else {
                print("Database \(config.database) does not exist.")
            }
        }
    }

    private static func seedDatabase(_ config: Database, required: Bool) async throws {
        try await withClient(config, database: config.database) { client in
            let seeder = Seeder(database: client)
            guard required || seeder.seedFileExists() else { return }
            let result = try await seeder.seed()
            print("Seeded \(config.database) from Seeds/\(result.file).")
        }
    }

    private static func databaseExists(_ name: String, repo: some Repo) async throws -> Bool {
        try await !repo.executeRawQuery(
            sql: "SELECT 1 FROM pg_database WHERE datname = $1", parameters: [PostgresData(string: name)]
        ).isEmpty
    }

    private static func quotedIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Runs `body` with a client for `database` on the configured server, then shuts the client down.
    private static func withClient(
        _ config: Database, database: String, _ body: (SpectroClient) async throws -> Void
    ) async throws {
        let client = try SpectroClient(hostname: config.hostname, port: config.port,
            username: config.username, password: config.password, database: database)
        do {
            try await body(client)
        } catch {
            await client.shutdown()
            throw error
        }
        await client.shutdown()
    }

    /// PostgreSQL's own message, which `PSQLError`'s description withholds.
    static func postgresMessage(_ error: any Error) -> String {
        if case SpectroError.queryExecutionFailed(_, let underlying) = error { return postgresMessage(underlying) }
        if let postgres = error as? PSQLError {
            if let message = postgres.serverInfo?[.message] { return message }
            if let underlying = postgres.underlying { return "\(underlying)" }
        }
        return "\(error)"
    }

    private static func databaseCommandFailure(_ message: String, status: Int32 = 1) -> Int32 {
        FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
        return status
    }
}

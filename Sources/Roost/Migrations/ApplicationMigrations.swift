import Foundation
import Spectro
import SpectroMigrations

extension RoostApp {
    /// Run migrations with exactly the same database configuration as the server.
    /// Available in a compiled release too: `MyApp migrate up|down|status`.
    ///
    /// When the app declares ``RoostApp/migrations``, Spectro's migration command
    /// runs the registry and also accepts `plan` and its options. `down` without
    /// `--step` still rolls back only the newest migration.
    ///
    /// - Returns: The process exit status.
    package func runMigrationCommand(_ arguments: [String]) async throws -> Int32 {
        if let migrations {
            let database = database, app = "\(Self.self)"
            return await MigrationCommand.run(arguments: Self.registryArguments(arguments), migrations: migrations) {
                guard let config = database else { throw MigrationCommandError("No database configured in \(app).") }
                return DatabaseConfiguration(hostname: config.hostname, port: config.port,
                    username: config.username, password: config.password, database: config.database)
            }
        }
        guard arguments.count == 1, ["up", "down", "status"].contains(arguments[0]) else {
            throw MigrationCommandError("Usage: \(Self.self) migrate up|down|status")
        }
        guard let config = database else { throw MigrationCommandError("No database configured in \(Self.self).") }
        let client = try SpectroClient(hostname: config.hostname, port: config.port,
            username: config.username, password: config.password, database: config.database)
        let migrator = RoostMigrator(database: client)
        do {
            switch arguments[0] {
            case "up":
                let pending = try await migrator.pending()
                print("Applying \(pending.count) migration(s) to \(config.database)")
                try await migrator.migrate()
            case "down": try await migrator.rollback()
            default: try await migrator.status().printReport()
            }
        } catch {
            await client.shutdown()
            throw error
        }
        await client.shutdown()
        return 0
    }

    /// Spectro's `down` rolls back every migration unless `--step` is given.
    /// `roost migrate down` has always meant the newest one, so keep that.
    package static func registryArguments(_ arguments: [String]) -> [String] {
        guard arguments.first == "down",
              !arguments.contains(where: { $0 == "--step" || $0.hasPrefix("--step=") || $0 == "--help" || $0 == "-h" })
        else { return arguments }
        return arguments + ["--step", "1"]
    }
}

private struct MigrationCommandError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

import Foundation
import Spectro
import SpectroMigrations

extension RoostApp {
    /// Run migrations with exactly the same database configuration as the server.
    /// Available in a compiled release too: `MyApp migrate up|down|status`.
    ///
    /// When the app declares ``RoostApp/migrations``, Spectro's migration command
    /// runs the registry and also accepts `plan` and its options. `down` without
    /// `--step` still rolls back only the newest migration; `down --all` rolls
    /// back every one.
    ///
    /// - Returns: The process exit status.
    package func runMigrationCommand(_ arguments: [String]) async throws -> Int32 {
        if let migrations {
            let database = database, app = "\(Self.self)"
            let spectroArguments: [String]
            do {
                spectroArguments = try Self.registryArguments(arguments)
            } catch {
                FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
                return 64  // EX_USAGE
            }
            // Spectro's help names its own `migrations` command and says that `down`
            // without `--step` rolls back everything.
            if Self.asksForHelp(arguments) {
                print("""
                    Run these as `\(app) migrate <subcommand>`. In \(app), `down` without --step rolls back \
                    only the newest migration; `down --all` rolls back every one.

                    """)
            }
            return await MigrationCommand.run(arguments: spectroArguments, migrations: migrations) {
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

    /// `true` when Spectro will print help: no subcommand, `help`, or a help flag.
    package static func asksForHelp(_ arguments: [String]) -> Bool {
        arguments.isEmpty || arguments.first == "help"
            || arguments.contains { ["--help", "-h", "-help"].contains($0) }
    }

    /// Spectro's `down` rolls back every migration unless `--step` is given.
    /// `roost migrate down` has always meant the newest one, so keep that, and
    /// turn `down --all` into Spectro's bare `down`.
    package static func registryArguments(_ arguments: [String]) throws -> [String] {
        guard arguments.first == "down" else { return arguments }
        let hasStep = arguments.contains { $0 == "--step" || $0.hasPrefix("--step=") }
        if arguments.contains("--all") {
            guard !hasStep else { throw MigrationCommandError("Pass --step or --all to down, not both.") }
            return arguments.filter { $0 != "--all" }
        }
        guard !hasStep, !asksForHelp(arguments) else { return arguments }
        return arguments + ["--step", "1"]
    }
}

private struct MigrationCommandError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

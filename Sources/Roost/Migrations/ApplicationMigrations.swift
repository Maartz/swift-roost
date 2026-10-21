import Foundation
import Spectro
import SpectroMigrations

extension RoostApp {
    /// Run migrations with exactly the same database configuration as the server.
    /// Available in a compiled release too: `MyApp migrate up|down|status`.
    ///
    /// `down` rolls back the newest migration, `down --step N` the newest N, and
    /// `down --all` every one. When the app declares ``RoostApp/migrations``,
    /// Spectro's migration command runs the registry and also accepts `plan` and
    /// its options.
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
        let usage = "Usage: \(Self.self) migrate up|status|down [--step N|--all]"
        if Self.asksForHelp(arguments) {
            print(usage)
            return 0
        }
        let steps: Int
        do {
            guard ["up", "down", "status"].contains(arguments[0]), arguments[0] == "down" || arguments.count == 1 else {
                throw MigrationCommandError(usage)
            }
            steps = try Self.rollbackSteps(Array(arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
            return 64  // EX_USAGE
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
            case "down": try await migrator.rollback(steps: steps)
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

    /// How many SQL migrations `down` rolls back: the newest by default, `--step N`,
    /// or every one with `--all` (`Int.max`).
    package static func rollbackSteps(_ options: [String]) throws -> Int {
        if options.isEmpty { return 1 }
        if options == ["--all"] { return .max }
        let value = options.count == 2 && options[0] == "--step" ? options[1]
            : options.count == 1 && options[0].hasPrefix("--step=") ? String(options[0].dropFirst("--step=".count)) : nil
        guard let steps = value.flatMap(Int.init), steps >= 0 else {
            throw MigrationCommandError("down takes --step N, with N 0 or more, or --all.")
        }
        return steps
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

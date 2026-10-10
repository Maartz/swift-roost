import Foundation
import SpectroCommon

// MARK: - Roost Migration Report

/// Rich status report for Roost migrations.
public struct RoostMigrationReport: Sendable {
    /// Name of the database.
    public let database: String

    /// All discovered migration files with their status.
    public let migrations: [RoostMigrationInfo]

    /// Whether the database is fully up to date.
    public var isUpToDate: Bool {
        migrations.allSatisfy { $0.isApplied }
    }

    /// Applied migration count.
    public var appliedCount: Int {
        migrations.filter(\.isApplied).count
    }

    /// Pending migration count.
    public var pendingCount: Int {
        migrations.filter { !$0.isApplied }.count
    }

    public init(database: String, migrations: [RoostMigrationInfo]) {
        self.database = database
        self.migrations = migrations
    }

    /// Print a human-readable status report.
    public func printReport() {
        print("Database: \(database)")
        print("Status:   \(isUpToDate ? "Up to date" : "\(pendingCount) migration(s) pending")")
        print("")
        print("Migration Status:")

        for info in migrations {
            let status = info.isApplied ? "Applied" : "Pending"
            print("  \(status)  \(info.version)  \(info.name)")
        }
    }
}

/// Information about a single migration.
public struct RoostMigrationInfo: Sendable {
    /// Migration version string (e.g. `"1712504400_create_users"`).
    public let version: String

    /// Human-readable name (e.g. `"create_users"`).
    public let name: String

    /// The migration file path on disk.
    public let filePath: URL

    /// Whether this migration has been applied.
    public let isApplied: Bool

    /// When the migration was applied (nil if pending).
    public let appliedAt: Date?

    public init(
        version: String,
        name: String,
        filePath: URL,
        isApplied: Bool,
        appliedAt: Date? = nil
    ) {
        self.version = version
        self.name = name
        self.filePath = filePath
        self.isApplied = isApplied
        self.appliedAt = appliedAt
    }
}

// MARK: - Seed Result

/// Result of running a seed file.
public struct SeedResult: Sendable {
    /// The environment that was seeded.
    public let environment: Environment

    /// The seed file that was executed.
    public let file: String

    /// How long the seed took to execute.
    public let duration: TimeInterval

    public init(environment: Environment, file: String, duration: TimeInterval) {
        self.environment = environment
        self.file = file
        self.duration = duration
    }
}

// MARK: - Drift Detection Types

/// Report from comparing database schema against a snapshot.
public struct DriftReport: Sendable {
    /// Whether any drift was detected.
    public let hasDrift: Bool

    /// Tables found in actual but not in expected.
    public let unexpectedTables: [String]

    /// Columns found in actual but not in expected.
    public let unexpectedColumns: [ColumnDrift]

    /// Tables found in expected but not in actual.
    public let missingTables: [String]

    /// Columns found in expected but not in actual.
    public let missingColumns: [ColumnDrift]

    /// Columns where the type differs between actual and expected.
    public let typeMismatches: [TypeDrift]

    public init(
        unexpectedTables: [String] = [],
        unexpectedColumns: [ColumnDrift] = [],
        missingTables: [String] = [],
        missingColumns: [ColumnDrift] = [],
        typeMismatches: [TypeDrift] = []
    ) {
        self.hasDrift = !unexpectedTables.isEmpty
            || !unexpectedColumns.isEmpty
            || !missingTables.isEmpty
            || !missingColumns.isEmpty
            || !typeMismatches.isEmpty
        self.unexpectedTables = unexpectedTables
        self.unexpectedColumns = unexpectedColumns
        self.missingTables = missingTables
        self.missingColumns = missingColumns
        self.typeMismatches = typeMismatches
    }

    /// A report with no drift.
    public static let clean = DriftReport()

    /// Print a human-readable drift report.
    public func printReport() {
        if !hasDrift {
            print("Schema matches snapshot (.roost/schema.sql)")
            return
        }

        print("Schema drift detected!\n")

        if !unexpectedTables.isEmpty {
            print("Unexpected tables (in DB, not in snapshot):")
            for table in unexpectedTables {
                print("  - \(table)")
            }
            print("")
        }

        if !unexpectedColumns.isEmpty {
            print("Unexpected columns (in DB, not in snapshot):")
            for drift in unexpectedColumns {
                print("  - \(drift.table).\(drift.column)")
            }
            print("")
        }

        if !missingTables.isEmpty {
            print("Missing tables (in snapshot, not in DB):")
            for table in missingTables {
                print("  - \(table)")
            }
            print("")
        }

        if !missingColumns.isEmpty {
            print("Missing columns (in snapshot, not in DB):")
            for drift in missingColumns {
                print("  - \(drift.table).\(drift.column)")
            }
            print("")
        }

        if !typeMismatches.isEmpty {
            print("Type mismatches:")
            for mismatch in typeMismatches {
                print("  - \(mismatch.table).\(mismatch.column): database=\(mismatch.actualType), snapshot=\(mismatch.expectedType)")
            }
        }

        print("\nIf the database is correct, save a new snapshot with DriftDetector.saveSnapshot(_:to:)")
    }
}

/// A column that exists in one schema but not the other.
public struct ColumnDrift: Sendable, Equatable {
    public let table: String
    public let column: String

    public init(table: String, column: String) {
        self.table = table
        self.column = column
    }
}

/// A column whose type differs between two schemas.
public struct TypeDrift: Sendable, Equatable {
    public let table: String
    public let column: String
    public let actualType: String
    public let expectedType: String

    public init(table: String, column: String, actualType: String, expectedType: String) {
        self.table = table
        self.column = column
        self.actualType = actualType
        self.expectedType = expectedType
    }
}

// MARK: - Schema Snapshot (Internal)

/// Parsed representation of a SQL schema snapshot.
public struct SchemaSnapshot: Sendable, Equatable {
    /// Tables keyed by name.
    public var tables: [String: TableInfo]

    public init(tables: [String: TableInfo] = [:]) {
        self.tables = tables
    }
}

/// Information about a single table in a schema snapshot.
public struct TableInfo: Sendable, Equatable {
    public let name: String
    public var columns: [ColumnInfo]

    public init(name: String, columns: [ColumnInfo] = []) {
        self.name = name
        self.columns = columns
    }

    func hasColumn(named name: String) -> Bool {
        columns.contains { $0.name == name }
    }

    func column(named name: String) -> ColumnInfo? {
        columns.first { $0.name == name }
    }
}

/// Information about a single column.
public struct ColumnInfo: Sendable, Equatable {
    public let name: String
    public let type: String
    public let nullable: Bool

    public init(name: String, type: String, nullable: Bool = true) {
        self.name = name
        self.type = type
        self.nullable = nullable
    }
}

// MARK: - Roost Migration Error

/// Errors specific to Roost's migration system.
public enum RoostMigrationError: Error, Sendable {
    /// The migrations directory does not exist.
    case migrationsDirectoryNotFound(String)

    /// The seed file for the given environment was not found.
    case seedFileNotFound(String)

    /// The schema snapshot file was not found.
    case snapshotFileNotFound(String)

    /// A migration file could not be parsed.
    case invalidMigrationFormat(String)

    /// Migration name is empty or invalid.
    case invalidMigrationName(String)

    /// The seeds directory does not exist.
    case seedsDirectoryNotFound(String)
}

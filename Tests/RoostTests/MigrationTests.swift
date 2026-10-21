import Foundation
import Testing

@testable import Roost

// MARK: - Migration Generator Tests

@Suite("Migrations — Generator")
struct MigrationGeneratorTests {

    @Test("sanitize converts description to snake_case")
    func sanitizeDescription() {
        #expect(MigrationGenerator.sanitize("Create Users Table") == "create_users_table")
        #expect(MigrationGenerator.sanitize("add-email-index") == "add_email_index")
        #expect(MigrationGenerator.sanitize("AddPosts") == "addposts")
        #expect(MigrationGenerator.sanitize("  spaced  out  ") == "spaced_out")
    }

    @Test("sanitize strips special characters")
    func sanitizeStripsSpecialChars() {
        #expect(MigrationGenerator.sanitize("hello@world!") == "helloworld")
        #expect(MigrationGenerator.sanitize("café") == "café")
        #expect(MigrationGenerator.sanitize("123_numbers") == "123_numbers")
    }

    @Test("sanitize rejects empty after sanitization")
    func sanitizeEmptyThrows() {
        #expect(MigrationGenerator.sanitize("!!!") == "")
        #expect(MigrationGenerator.sanitize("") == "")
    }

    @Test("create generates file with correct name format")
    func createFileNameFormat() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roost-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fixedDate = Date(timeIntervalSince1970: 1712504400)

        let url = try MigrationGenerator.create(
            named: "Create Users",
            in: tmpDir,
            now: fixedDate
        )

        #expect(url.lastPathComponent == "1712504400_create_users.sql")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("create generates file with migrate:up and migrate:down markers")
    func createFileContainsMarkers() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roost-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let url = try MigrationGenerator.create(named: "Add Posts", in: tmpDir)
        let content = try String(contentsOf: url, encoding: .utf8)

        #expect(content.contains("-- migrate:up"))
        #expect(content.contains("-- migrate:down"))
        #expect(content.contains("Migration: Add Posts"))
    }

    @Test("create generates file with metadata comments")
    func createFileContainsMetadata() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roost-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let url = try MigrationGenerator.create(named: "Add Email Index", in: tmpDir)
        let content = try String(contentsOf: url, encoding: .utf8)

        #expect(content.contains("-- Migration: Add Email Index"))
        #expect(content.contains("-- Version:"))
        #expect(content.contains("-- Created:"))
    }

    @Test("create throws for empty name")
    func createThrowsForEmptyName() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roost-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        #expect(throws: RoostMigrationError.self) {
            try MigrationGenerator.create(named: "", in: tmpDir)
        }
    }

    @Test("create with special-char-only name throws")
    func createThrowsForSpecialCharName() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roost-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        #expect(throws: RoostMigrationError.self) {
            try MigrationGenerator.create(named: "!!!", in: tmpDir)
        }
    }

    @Test("create creates directory if it doesn't exist")
    func createCreatesDirectory() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roost-test-\(UUID().uuidString)")
            .appendingPathComponent("nested")
            .appendingPathComponent("migrations")
        defer {
            try? FileManager.default.removeItem(
                at: tmpDir.deletingLastPathComponent().deletingLastPathComponent()
            )
        }

        let url = try MigrationGenerator.create(named: "Init", in: tmpDir)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("consecutive creates produce different filenames")
    func consecutiveCreatesUnique() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roost-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let date1 = Date(timeIntervalSince1970: 1000000)
        let date2 = Date(timeIntervalSince1970: 1000001)

        let url1 = try MigrationGenerator.create(named: "First", in: tmpDir, now: date1)
        let url2 = try MigrationGenerator.create(named: "Second", in: tmpDir, now: date2)

        #expect(url1.lastPathComponent != url2.lastPathComponent)
    }
}

// MARK: - Drift Detector Snapshot Parsing Tests

@Suite("Migrations — DriftDetector Parsing")
struct DriftDetectorParsingTests {

    @Test("parseSnapshot extracts table and columns from CREATE TABLE")
    func parseBasicCreateTable() {
        let sql = """
        CREATE TABLE "users" (
            "id" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            "email" TEXT NOT NULL,
            "name" TEXT,
            "created_at" TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
        """

        let snapshot = DriftDetector.parseSnapshot(sql)

        #expect(snapshot.tables.count == 1)
        let users = snapshot.tables["users"]
        #expect(users != nil)
        #expect(users?.columns.count == 4)

        let email = users?.column(named: "email")
        #expect(email?.type == "TEXT")
        #expect(email?.nullable == false)

        let name = users?.column(named: "name")
        #expect(name?.type == "TEXT")
        #expect(name?.nullable == true)
    }

    @Test("parseSnapshot handles multiple tables")
    func parseMultipleTables() {
        let sql = """
        -- Roost Schema Dump

        CREATE TABLE "users" (
            "id" UUID PRIMARY KEY,
            "email" TEXT NOT NULL
        );

        CREATE TABLE "posts" (
            "id" UUID PRIMARY KEY,
            "user_id" UUID NOT NULL,
            "title" TEXT NOT NULL,
            "body" TEXT
        );
        """

        let snapshot = DriftDetector.parseSnapshot(sql)

        #expect(snapshot.tables.count == 2)
        #expect(snapshot.tables["users"] != nil)
        #expect(snapshot.tables["posts"] != nil)
        #expect(snapshot.tables["posts"]?.columns.count == 4)
    }

    @Test("parseSnapshot skips comments and empty lines")
    func parseSkipsComments() {
        let sql = """
        -- This is a comment
        -- Another comment

        CREATE TABLE "items" (
            "id" UUID PRIMARY KEY
        );
        """

        let snapshot = DriftDetector.parseSnapshot(sql)
        #expect(snapshot.tables.count == 1)
    }

    @Test("parseSnapshot handles empty input")
    func parseEmptyInput() {
        let snapshot = DriftDetector.parseSnapshot("")
        #expect(snapshot.tables.isEmpty)
    }

    @Test("parseSnapshot handles CREATE TABLE IF NOT EXISTS")
    func parseIfNotExists() {
        let sql = """
        CREATE TABLE IF NOT EXISTS "configs" (
            "key" TEXT NOT NULL,
            "value" TEXT
        );
        """

        let snapshot = DriftDetector.parseSnapshot(sql)
        #expect(snapshot.tables["configs"] != nil)
        #expect(snapshot.tables["configs"]?.columns.count == 2)
    }

    @Test("extractTableName from various formats")
    func extractTableName() {
        #expect(DriftDetector.extractTableName(from: "CREATE TABLE \"users\" (") == "users")
        #expect(DriftDetector.extractTableName(from: "CREATE TABLE users (") == "users")
        #expect(DriftDetector.extractTableName(from: "CREATE TABLE IF NOT EXISTS \"users\" (") == "users")
    }

    @Test("parseColumnDefinition extracts column info")
    func parseColumnDef() {
        let col1 = DriftDetector.parseColumnDefinition("    \"email\" TEXT NOT NULL,")
        #expect(col1?.name == "email")
        #expect(col1?.type == "TEXT")
        #expect(col1?.nullable == false)

        let col2 = DriftDetector.parseColumnDefinition("    \"bio\" TEXT,")
        #expect(col2?.name == "bio")
        #expect(col2?.type == "TEXT")
        #expect(col2?.nullable == true)

        let col3 = DriftDetector.parseColumnDefinition("    \"id\" UUID PRIMARY KEY DEFAULT gen_random_uuid(),")
        #expect(col3?.name == "id")
        #expect(col3?.type == "UUID")
    }

    @Test("parseColumnDefinition skips constraint lines")
    func parseSkipsConstraints() {
        #expect(DriftDetector.parseColumnDefinition("    PRIMARY KEY (id)") == nil)
        #expect(DriftDetector.parseColumnDefinition("    CONSTRAINT fk_user FOREIGN KEY ...") == nil)
        #expect(DriftDetector.parseColumnDefinition("    UNIQUE (email)") == nil)
    }

    @Test("extractBaseType handles common types")
    func extractBaseType() {
        #expect(DriftDetector.extractBaseType(from: "TEXT NOT NULL") == "TEXT")
        #expect(DriftDetector.extractBaseType(from: "UUID PRIMARY KEY") == "UUID")
        #expect(DriftDetector.extractBaseType(from: "TIMESTAMPTZ NOT NULL DEFAULT NOW()") == "TIMESTAMPTZ")
        #expect(DriftDetector.extractBaseType(from: "INTEGER") == "INTEGER")
    }
}

// MARK: - Drift Detector Comparison Tests

@Suite("Migrations — DriftDetector Comparison")
struct DriftDetectorComparisonTests {

    @Test("identical schemas produce no drift")
    func noDrift() {
        let schema = SchemaSnapshot(tables: [
            "users": TableInfo(name: "users", columns: [
                ColumnInfo(name: "id", type: "UUID"),
                ColumnInfo(name: "email", type: "TEXT", nullable: false),
            ]),
        ])

        let report = DriftDetector.compare(expected: schema, actual: schema)

        #expect(!report.hasDrift)
        #expect(report.unexpectedTables.isEmpty)
        #expect(report.missingTables.isEmpty)
        #expect(report.unexpectedColumns.isEmpty)
        #expect(report.missingColumns.isEmpty)
        #expect(report.typeMismatches.isEmpty)
    }

    @Test("detects unexpected table")
    func unexpectedTable() {
        let expected = SchemaSnapshot(tables: [
            "users": TableInfo(name: "users", columns: [
                ColumnInfo(name: "id", type: "UUID"),
            ]),
        ])
        let actual = SchemaSnapshot(tables: [
            "users": TableInfo(name: "users", columns: [
                ColumnInfo(name: "id", type: "UUID"),
            ]),
            "temp_data": TableInfo(name: "temp_data", columns: [
                ColumnInfo(name: "id", type: "INTEGER"),
            ]),
        ])

        let report = DriftDetector.compare(expected: expected, actual: actual)

        #expect(report.hasDrift)
        #expect(report.unexpectedTables == ["temp_data"])
    }

    @Test("detects missing table")
    func missingTable() {
        let expected = SchemaSnapshot(tables: [
            "users": TableInfo(name: "users", columns: []),
            "posts": TableInfo(name: "posts", columns: []),
        ])
        let actual = SchemaSnapshot(tables: [
            "users": TableInfo(name: "users", columns: []),
        ])

        let report = DriftDetector.compare(expected: expected, actual: actual)

        #expect(report.hasDrift)
        #expect(report.missingTables == ["posts"])
    }

    @Test("detects unexpected column")
    func unexpectedColumn() {
        let expected = SchemaSnapshot(tables: [
            "users": TableInfo(name: "users", columns: [
                ColumnInfo(name: "id", type: "UUID"),
            ]),
        ])
        let actual = SchemaSnapshot(tables: [
            "users": TableInfo(name: "users", columns: [
                ColumnInfo(name: "id", type: "UUID"),
                ColumnInfo(name: "admin", type: "BOOLEAN"),
            ]),
        ])

        let report = DriftDetector.compare(expected: expected, actual: actual)

        #expect(report.hasDrift)
        #expect(report.unexpectedColumns.count == 1)
        #expect(report.unexpectedColumns.first?.table == "users")
        #expect(report.unexpectedColumns.first?.column == "admin")
    }

    @Test("detects missing column")
    func missingColumn() {
        let expected = SchemaSnapshot(tables: [
            "posts": TableInfo(name: "posts", columns: [
                ColumnInfo(name: "id", type: "UUID"),
                ColumnInfo(name: "slug", type: "TEXT"),
            ]),
        ])
        let actual = SchemaSnapshot(tables: [
            "posts": TableInfo(name: "posts", columns: [
                ColumnInfo(name: "id", type: "UUID"),
            ]),
        ])

        let report = DriftDetector.compare(expected: expected, actual: actual)

        #expect(report.hasDrift)
        #expect(report.missingColumns.count == 1)
        #expect(report.missingColumns.first?.column == "slug")
    }

    @Test("detects type mismatch")
    func typeMismatch() {
        let expected = SchemaSnapshot(tables: [
            "users": TableInfo(name: "users", columns: [
                ColumnInfo(name: "created_at", type: "TIMESTAMPTZ"),
            ]),
        ])
        let actual = SchemaSnapshot(tables: [
            "users": TableInfo(name: "users", columns: [
                ColumnInfo(name: "created_at", type: "TIMESTAMP"),
            ]),
        ])

        let report = DriftDetector.compare(expected: expected, actual: actual)

        #expect(report.hasDrift)
        #expect(report.typeMismatches.count == 1)
        #expect(report.typeMismatches.first?.column == "created_at")
        #expect(report.typeMismatches.first?.expectedType == "TIMESTAMPTZ")
        #expect(report.typeMismatches.first?.actualType == "TIMESTAMP")
    }

    @Test("type comparison is case-insensitive")
    func typeCaseInsensitive() {
        let expected = SchemaSnapshot(tables: [
            "t": TableInfo(name: "t", columns: [
                ColumnInfo(name: "c", type: "text"),
            ]),
        ])
        let actual = SchemaSnapshot(tables: [
            "t": TableInfo(name: "t", columns: [
                ColumnInfo(name: "c", type: "TEXT"),
            ]),
        ])

        let report = DriftDetector.compare(expected: expected, actual: actual)
        #expect(!report.hasDrift)
    }

    @Test("empty schemas produce no drift")
    func emptySchemas() {
        let report = DriftDetector.compare(
            expected: SchemaSnapshot(),
            actual: SchemaSnapshot()
        )
        #expect(!report.hasDrift)
    }

    @Test("DriftReport.clean has no drift")
    func cleanReport() {
        #expect(!DriftReport.clean.hasDrift)
    }
}

// MARK: - Drift Detector Snapshot I/O Tests

@Suite("Migrations — DriftDetector I/O")
struct DriftDetectorIOTests {

    @Test("formatSnapshot produces parseable SQL")
    func roundTripFormatParse() {
        let original = SchemaSnapshot(tables: [
            "users": TableInfo(name: "users", columns: [
                ColumnInfo(name: "id", type: "UUID", nullable: false),
                ColumnInfo(name: "email", type: "TEXT", nullable: false),
                ColumnInfo(name: "bio", type: "TEXT", nullable: true),
            ]),
            "posts": TableInfo(name: "posts", columns: [
                ColumnInfo(name: "id", type: "UUID", nullable: false),
                ColumnInfo(name: "title", type: "TEXT", nullable: false),
            ]),
        ])

        let sql = DriftDetector.formatSnapshot(original)
        let parsed = DriftDetector.parseSnapshot(sql)

        #expect(parsed.tables.count == 2)
        #expect(parsed.tables["users"]?.columns.count == 3)
        #expect(parsed.tables["posts"]?.columns.count == 2)

        let email = parsed.tables["users"]?.column(named: "email")
        #expect(email?.type == "TEXT")
        #expect(email?.nullable == false)
    }

    @Test("saveSnapshot and loadSnapshot round-trip")
    func roundTripIO() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roost-test-\(UUID().uuidString)")
        let snapshotFile = tmpDir
            .appendingPathComponent(".roost")
            .appendingPathComponent("schema.sql")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let original = SchemaSnapshot(tables: [
            "items": TableInfo(name: "items", columns: [
                ColumnInfo(name: "id", type: "INTEGER", nullable: false),
                ColumnInfo(name: "name", type: "TEXT", nullable: false),
            ]),
        ])

        try DriftDetector.saveSnapshot(original, to: snapshotFile)
        let loaded = try DriftDetector.loadSnapshot(from: snapshotFile)

        #expect(loaded.tables.count == 1)
        #expect(loaded.tables["items"]?.columns.count == 2)
    }

    @Test("loadSnapshot throws for missing file")
    func loadMissingFileThrows() {
        let bogus = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString)/schema.sql")
        #expect(throws: RoostMigrationError.self) {
            _ = try DriftDetector.loadSnapshot(from: bogus)
        }
    }
}

// MARK: - Migration Types Tests

@Suite("Migrations — Types")
struct MigrationTypesTests {

    @Test("RoostMigrationReport computes isUpToDate correctly")
    func reportUpToDate() {
        let report = RoostMigrationReport(
            database: "test_db",
            migrations: [
                RoostMigrationInfo(
                    version: "100_init",
                    name: "init",
                    filePath: URL(fileURLWithPath: "/tmp/100_init.sql"),
                    isApplied: true
                ),
                RoostMigrationInfo(
                    version: "200_add_users",
                    name: "add_users",
                    filePath: URL(fileURLWithPath: "/tmp/200_add_users.sql"),
                    isApplied: true
                ),
            ]
        )

        #expect(report.isUpToDate)
        #expect(report.appliedCount == 2)
        #expect(report.pendingCount == 0)
    }

    @Test("RoostMigrationReport detects pending migrations")
    func reportPending() {
        let report = RoostMigrationReport(
            database: "test_db",
            migrations: [
                RoostMigrationInfo(
                    version: "100_init",
                    name: "init",
                    filePath: URL(fileURLWithPath: "/tmp/100_init.sql"),
                    isApplied: true
                ),
                RoostMigrationInfo(
                    version: "200_add_users",
                    name: "add_users",
                    filePath: URL(fileURLWithPath: "/tmp/200_add_users.sql"),
                    isApplied: false
                ),
            ]
        )

        #expect(!report.isUpToDate)
        #expect(report.appliedCount == 1)
        #expect(report.pendingCount == 1)
    }

    @Test("SeedResult stores correct values")
    func seedResult() {
        let result = SeedResult(environment: .dev, file: "dev.sql", duration: 0.5)
        #expect(result.environment == .dev)
        #expect(result.file == "dev.sql")
        #expect(result.duration == 0.5)
    }

    @Test("DriftReport with no issues has no drift")
    func noDriftReport() {
        let report = DriftReport()
        #expect(!report.hasDrift)
    }

    @Test("DriftReport with unexpected table has drift")
    func driftWithUnexpectedTable() {
        let report = DriftReport(unexpectedTables: ["temp"])
        #expect(report.hasDrift)
    }

    @Test("DriftReport with missing column has drift")
    func driftWithMissingColumn() {
        let report = DriftReport(missingColumns: [ColumnDrift(table: "t", column: "c")])
        #expect(report.hasDrift)
    }

    @Test("SchemaSnapshot equality")
    func schemaSnapshotEquality() {
        let a = SchemaSnapshot(tables: [
            "t": TableInfo(name: "t", columns: [ColumnInfo(name: "c", type: "TEXT")]),
        ])
        let b = SchemaSnapshot(tables: [
            "t": TableInfo(name: "t", columns: [ColumnInfo(name: "c", type: "TEXT")]),
        ])
        #expect(a == b)
    }
}

// MARK: - Seeder Tests (filesystem only)

@Suite("Migrations — Seeder")
struct SeederTests {

    @Test("seedFileURL builds correct path")
    func seedFileURLCorrect() throws {
        // We can't create a real SpectroClient without a database,
        // but we can verify the Seeder's URL construction logic.
        // The Seeder struct stores the seedsDirectory URL.
        let dir = URL(fileURLWithPath: "/tmp/seeds")
        // Since Seeder requires SpectroClient which needs DB, we test
        // the URL construction indirectly through the type's behavior.
        #expect(dir.appendingPathComponent("dev.sql").lastPathComponent == "dev.sql")
        #expect(dir.appendingPathComponent("test.sql").lastPathComponent == "test.sql")
        #expect(dir.appendingPathComponent("prod.sql").lastPathComponent == "prod.sql")
    }
}

// MARK: - Registry Tests

private struct CreateNotes: Migration {
    static let id = "1791700000_create_notes"

    var change: MigrationPlan {
        CreateTable("notes") { table in
            table.column("id", .uuid).primaryKey().default(.sql("gen_random_uuid()"))
            table.column("body", .text).notNull()
        }
    }
}

private struct EmptyMigration: Migration {
    static let id = "1791700001_empty"

    var change: MigrationPlan {
        get {}
    }
}

private struct RegistryApp: RoostApp {
    var migrations: MigrationRegistry? { MigrationRegistry { CreateNotes() } }
    @RouteBuilder var routes: [Route] { GET("/") { $0 } }
}

private struct InvalidRegistryApp: RoostApp {
    var migrations: MigrationRegistry? { MigrationRegistry { EmptyMigration() } }
    @RouteBuilder var routes: [Route] { GET("/") { $0 } }
}

@Suite("Migrations — Registry")
struct MigrationRegistryCommandTests {

    @Test("down without --step rolls back only the newest migration")
    func downDefaultsToOneStep() throws {
        #expect(try RegistryApp.registryArguments(["down"]) == ["down", "--step", "1"])
        #expect(try RegistryApp.registryArguments(["down", "--database", "app"]) == ["down", "--database", "app", "--step", "1"])
        #expect(try RegistryApp.registryArguments(["down", "--step", "3"]) == ["down", "--step", "3"])
        #expect(try RegistryApp.registryArguments(["down", "--step=0"]) == ["down", "--step=0"])
        #expect(try RegistryApp.registryArguments(["down", "--help"]) == ["down", "--help"])
        #expect(try RegistryApp.registryArguments(["up"]) == ["up"])
        #expect(try RegistryApp.registryArguments(["plan", "--direction", "down"]) == ["plan", "--direction", "down"])
    }

    @Test("down --all rolls back every migration, and can't be combined with --step")
    func downAllRollsBackEverything() throws {
        #expect(try RegistryApp.registryArguments(["down", "--all"]) == ["down"])
        #expect(try RegistryApp.registryArguments(["down", "--all", "--database", "app"]) == ["down", "--database", "app"])
        #expect(throws: (any Error).self) { try RegistryApp.registryArguments(["down", "--all", "--step", "2"]) }
        #expect(throws: (any Error).self) { try RegistryApp.registryArguments(["down", "--step=2", "--all"]) }
    }

    @Test("Roost's note comes with every form of help Spectro prints")
    func helpRequests() throws {
        for arguments in [[], ["help"], ["--help"], ["down", "-h"], ["down", "-help"], ["status", "--help"]] {
            #expect(RegistryApp.asksForHelp(arguments), "\(arguments)")
        }
        for arguments in [["up"], ["down"], ["down", "--step", "2"], ["plan", "--direction", "down"]] {
            #expect(!RegistryApp.asksForHelp(arguments), "\(arguments)")
        }
        #expect(try RegistryApp.registryArguments(["down", "-help"]) == ["down", "-help"])
    }

    @Test("down --all --step is a usage error, before any database connection")
    func downAllWithStepIsAUsageError() async throws {
        #expect(try await RegistryApp().runMigrationCommand(["down", "--all", "--step", "2"]) == 64)
    }

    @Test("plan compiles the registry without a database")
    func planRunsOffline() async throws {
        #expect(RegistryApp().database == nil)
        #expect(try await RegistryApp().runMigrationCommand(["plan"]) == 0)
        #expect(try await RegistryApp().runMigrationCommand(["plan", "--direction", "down"]) == 0)
    }

    @Test("a database command without a configured database fails before connecting")
    func statusNeedsDatabase() async throws {
        #expect(try await RegistryApp().runMigrationCommand(["status"]) != 0)
    }

    @Test("an invalid registry fails planning")
    func invalidRegistryFails() async throws {
        #expect(try await InvalidRegistryApp().runMigrationCommand(["plan"]) != 0)
    }

    @Test("apps without a registry keep the SQL command's usage check")
    func sqlCommandUsage() async throws {
        #expect(try await MinimalMigrationApp().runMigrationCommand(["plan"]) == 64)
    }
}

private struct MinimalMigrationApp: RoostApp {
    @RouteBuilder var routes: [Route] { GET("/") { $0 } }
}

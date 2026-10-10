import Foundation

// MARK: - Snapshot-Based Schema Drift Detection

/// Detects schema drift by comparing two SQL schema snapshots.
///
/// The `roost` CLI has no command for drift detection, so call the detector
/// from your own tooling, such as a test or a CI script:
///
/// 1. After running migrations, dump the schema with
///    `pg_dump --schema-only`, and save it with ``saveSnapshot(_:to:)`` at
///    ``defaultSnapshotPath`` (`.roost/schema.sql`).
/// 2. Commit the snapshot to git.
/// 3. In CI or before deploys, dump the live schema the same way and compare
///    it with the committed snapshot:
///
/// ```swift
/// let actual = DriftDetector.parseSnapshot(currentSchemaDump)
/// let expected = try DriftDetector.loadSnapshot(from: DriftDetector.defaultSnapshotPath)
/// let report = DriftDetector.compare(expected: expected, actual: actual)
/// report.printReport()
/// ```
///
/// The detector parses `CREATE TABLE` statements from SQL dump files
/// and compares table/column definitions. It does **not** parse migration
/// files.
public enum DriftDetector {

    /// Default path for the schema snapshot file.
    public static let defaultSnapshotPath: URL = {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".roost")
            .appendingPathComponent("schema.sql")
    }()

    // MARK: - Snapshot I/O

    /// Load a schema snapshot from a SQL file.
    ///
    /// - Parameter file: Path to the `.roost/schema.sql` file.
    /// - Returns: A parsed ``SchemaSnapshot``.
    /// - Throws: ``RoostMigrationError/snapshotFileNotFound(_:)`` if the
    ///   file does not exist.
    public static func loadSnapshot(from file: URL) throws -> SchemaSnapshot {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw RoostMigrationError.snapshotFileNotFound(file.path)
        }

        let content = try String(contentsOf: file, encoding: .utf8)
        return parseSnapshot(content)
    }

    /// Save a schema snapshot to a SQL file.
    ///
    /// Creates the parent directory if needed.
    ///
    /// - Parameters:
    ///   - snapshot: The schema to serialize.
    ///   - file: Destination file path.
    public static func saveSnapshot(_ snapshot: SchemaSnapshot, to file: URL) throws {
        let content = formatSnapshot(snapshot)

        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try content.write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: - Comparison

    /// Compare two schema snapshots and produce a drift report.
    ///
    /// - Parameters:
    ///   - expected: The schema we expect (from the committed snapshot).
    ///   - actual: The schema we observed (from the live database dump).
    /// - Returns: A ``DriftReport`` describing any differences.
    public static func compare(
        expected: SchemaSnapshot,
        actual: SchemaSnapshot
    ) -> DriftReport {
        var unexpectedTables: [String] = []
        var unexpectedColumns: [ColumnDrift] = []
        var missingTables: [String] = []
        var missingColumns: [ColumnDrift] = []
        var typeMismatches: [TypeDrift] = []

        // Tables in actual but not expected
        for tableName in actual.tables.keys {
            if expected.tables[tableName] == nil {
                unexpectedTables.append(tableName)
            }
        }

        // Tables in expected but not actual
        for tableName in expected.tables.keys {
            if actual.tables[tableName] == nil {
                missingTables.append(tableName)
            }
        }

        // Column-level comparison for tables in both
        for (tableName, expectedTable) in expected.tables {
            guard let actualTable = actual.tables[tableName] else { continue }

            for column in actualTable.columns {
                if !expectedTable.hasColumn(named: column.name) {
                    unexpectedColumns.append(ColumnDrift(
                        table: tableName,
                        column: column.name
                    ))
                }
            }

            for column in expectedTable.columns {
                if !actualTable.hasColumn(named: column.name) {
                    missingColumns.append(ColumnDrift(
                        table: tableName,
                        column: column.name
                    ))
                }
            }

            for column in expectedTable.columns {
                if let actualColumn = actualTable.column(named: column.name) {
                    if normalizeType(actualColumn.type) != normalizeType(column.type) {
                        typeMismatches.append(TypeDrift(
                            table: tableName,
                            column: column.name,
                            actualType: actualColumn.type,
                            expectedType: column.type
                        ))
                    }
                }
            }
        }

        return DriftReport(
            unexpectedTables: unexpectedTables.sorted(),
            unexpectedColumns: unexpectedColumns,
            missingTables: missingTables.sorted(),
            missingColumns: missingColumns,
            typeMismatches: typeMismatches
        )
    }

    // MARK: - Snapshot Parsing

    /// Parse `CREATE TABLE` statements from a SQL schema dump.
    ///
    /// Handles the format produced by ``formatSnapshot(_:)`` and by
    /// `pg_dump --schema-only`. Only parses table/column names and types.
    ///
    /// - Parameter content: SQL text containing `CREATE TABLE` statements.
    /// - Returns: A parsed ``SchemaSnapshot``.
    public static func parseSnapshot(_ content: String) -> SchemaSnapshot {
        let lines = content.components(separatedBy: .newlines)
        var snapshot = SchemaSnapshot()
        var currentTable: TableInfo?
        var inCreateTable = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip comments and empty lines
            if trimmed.hasPrefix("--") || trimmed.isEmpty { continue }

            // Detect CREATE TABLE "name" (
            if trimmed.uppercased().hasPrefix("CREATE TABLE") {
                let tableName = extractTableName(from: trimmed)
                if !tableName.isEmpty {
                    currentTable = TableInfo(name: tableName)
                    inCreateTable = true
                }
                continue
            }

            // End of CREATE TABLE
            if inCreateTable && (trimmed == ");" || trimmed == ")") {
                if let table = currentTable {
                    snapshot.tables[table.name] = table
                }
                currentTable = nil
                inCreateTable = false
                continue
            }

            // Column definitions inside CREATE TABLE
            if inCreateTable, var table = currentTable {
                if let column = parseColumnDefinition(trimmed) {
                    table.columns.append(column)
                    currentTable = table
                }
            }
        }

        return snapshot
    }

    // MARK: - Snapshot Formatting

    /// Format a schema snapshot as SQL `CREATE TABLE` statements.
    ///
    /// The output is suitable for committing to version control.
    ///
    /// - Parameter snapshot: The schema to format.
    /// - Returns: SQL text with `CREATE TABLE` statements.
    public static func formatSnapshot(_ snapshot: SchemaSnapshot) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var lines: [String] = []
        lines.append("-- Roost Schema Dump")
        lines.append("-- Generated: \(formatter.string(from: Date()))")
        lines.append("-- Update with DriftDetector.saveSnapshot(_:to:) after running migrations")
        lines.append("")

        for (_, table) in snapshot.tables.sorted(by: { $0.key < $1.key }) {
            lines.append("CREATE TABLE \"\(table.name)\" (")

            let columnDefs = table.columns.map { column in
                let nullability = column.nullable ? "" : " NOT NULL"
                return "    \"\(column.name)\" \(column.type)\(nullability)"
            }

            lines.append(columnDefs.joined(separator: ",\n"))
            lines.append(");")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Private Parsing Helpers

    /// Extract table name from a `CREATE TABLE "name"` statement.
    static func extractTableName(from sql: String) -> String {
        // Match both "quoted" and unquoted table names
        // CREATE TABLE "users" (  → users
        // CREATE TABLE users (    → users
        // CREATE TABLE IF NOT EXISTS "users" ( → users
        let cleaned = sql
            .replacingOccurrences(of: "CREATE TABLE", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "IF NOT EXISTS", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)

        // Remove trailing ( if present
        let withoutParen = cleaned.replacingOccurrences(of: "(", with: "").trimmingCharacters(in: .whitespaces)

        // Remove quotes
        return withoutParen
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Parse a column definition line inside a CREATE TABLE.
    ///
    /// Handles lines like:
    /// - `"id" UUID PRIMARY KEY DEFAULT gen_random_uuid(),`
    /// - `"email" TEXT NOT NULL,`
    /// - `"bio" TEXT,`
    static func parseColumnDefinition(_ line: String) -> ColumnInfo? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Must start with a quoted column name
        guard trimmed.hasPrefix("\"") else { return nil }

        // Skip constraint lines (PRIMARY KEY, FOREIGN KEY, UNIQUE, CHECK, CONSTRAINT)
        let upper = trimmed.uppercased()
        let constraintPrefixes = ["CONSTRAINT", "PRIMARY KEY", "FOREIGN KEY", "UNIQUE", "CHECK"]
        for prefix in constraintPrefixes {
            if upper.hasPrefix(prefix) { return nil }
        }

        // Extract column name (between first pair of quotes)
        guard let firstQuoteEnd = trimmed.index(of: "\"", after: trimmed.index(after: trimmed.startIndex)) else {
            return nil
        }

        let columnName = String(trimmed[trimmed.index(after: trimmed.startIndex)..<firstQuoteEnd])
        guard !columnName.isEmpty else { return nil }

        // Everything after the closing quote and space is the type + modifiers
        let afterName = trimmed[trimmed.index(after: firstQuoteEnd)...]
            .trimmingCharacters(in: .whitespaces)

        // Remove trailing comma
        let typeSection = afterName.hasSuffix(",")
            ? String(afterName.dropLast())
            : String(afterName)

        // Extract base type (first word or first word(N))
        let columnType = extractBaseType(from: typeSection)
        let isNullable = !typeSection.uppercased().contains("NOT NULL")

        return ColumnInfo(name: columnName, type: columnType, nullable: isNullable)
    }

    /// Extract the base SQL type from a column definition.
    ///
    /// "UUID PRIMARY KEY DEFAULT gen_random_uuid()" → "UUID"
    /// "TEXT NOT NULL" → "TEXT"
    /// "VARCHAR(255) NOT NULL" → "VARCHAR(255)"
    /// "TIMESTAMPTZ NOT NULL DEFAULT NOW()" → "TIMESTAMPTZ"
    static func extractBaseType(from typeSection: String) -> String {
        let upper = typeSection.uppercased()
        let tokens = typeSection.split(separator: " ", maxSplits: 10)
        guard let first = tokens.first else { return typeSection }

        let firstStr = String(first)

        // If the type has parens (e.g. VARCHAR(255)), include them
        if firstStr.contains("(") && !firstStr.contains(")") {
            // Find closing paren in subsequent tokens
            for i in 1..<tokens.count {
                let combined = tokens[0...i].joined(separator: " ")
                if combined.contains(")") {
                    return combined
                }
            }
        }

        // Common multi-word types
        let multiWordTypes = [
            "DOUBLE PRECISION", "CHARACTER VARYING", "TIME WITH",
            "TIMESTAMP WITH", "TIMESTAMP WITHOUT",
        ]
        for mwt in multiWordTypes {
            if upper.hasPrefix(mwt) {
                return mwt
            }
        }

        return firstStr
    }

    /// Normalize a SQL type for comparison purposes.
    ///
    /// "timestamptz" and "TIMESTAMPTZ" should match.
    static func normalizeType(_ type: String) -> String {
        type.uppercased().trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - String Index Helpers

private extension String {
    /// Find the index of a character after a given start index.
    func index(of char: Character, after start: String.Index) -> String.Index? {
        var idx = start
        while idx < endIndex {
            if self[idx] == char { return idx }
            idx = self.index(after: idx)
        }
        return nil
    }
}

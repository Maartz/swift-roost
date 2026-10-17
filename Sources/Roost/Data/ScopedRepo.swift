import Foundation
import Nexus
import PostgresNIO
import Spectro
import SpectroCommon

/// The records of `Model` that belong to one owner, such as the signed-in user.
///
/// Every read and write goes through the owner column, so a context method
/// can't forget the condition, and another owner's record behaves as if it
/// didn't exist:
///
/// ```swift
/// struct BookmarksContext: Sendable {
///     let bookmarks: ScopedRepo<Bookmark, UUID>
///
///     init(repo: any Repo, reader: ReaderScope) {
///         bookmarks = repo.scoped(\Bookmark.userId, to: reader.userID)
///     }
///
///     func listBookmarks() async throws -> [Bookmark] {
///         try await bookmarks.query().orderBy(\.createdAt, .asc).all()
///     }
///
///     func setRead(id: UUID, read: Bool) async throws {
///         _ = try await bookmarks.update(id, Changes().setting(\.read, to: read))
///     }
/// }
/// ```
///
/// ``update(_:_:)`` and ``delete(_:)`` run one statement that matches both
/// the primary key and the owner, such as
/// `UPDATE "bookmarks" SET … WHERE "id" = $3 AND "user_id" = $4`, so they
/// don't read the record first, and they work inside the transaction a
/// `withTestRollback` test runs in. A scoped repository never changes the
/// owner column.
///
/// A missing record and another owner's record both throw
/// `NexusHTTPError(.notFound)`, which Roost renders as a 404.
public struct ScopedRepo<Model: Schema, Owner: PrimaryKeyType>: Sendable {
    /// The repository the scoped queries and writes run on.
    public let repo: any Repo

    /// The property that holds a record's owner, such as `\Bookmark.userId`.
    public let ownerField: WritableKeyPath<Model, Owner> & Sendable

    /// The owner every record must have.
    public let owner: Owner

    /// Limits `repo` to the records whose `ownerField` is `owner`.
    public init(_ repo: any Repo, _ ownerField: WritableKeyPath<Model, Owner> & Sendable, to owner: Owner) {
        self.repo = repo
        self.ownerField = ownerField
        self.owner = owner
    }

    /// A query for the owner's records. Add conditions, ordering, and limits
    /// as with `repo.query(_:)`.
    public func query() -> Query<Model> {
        repo.query(Model.self).where { $0[dynamicMember: ownerField] == owner }
    }

    /// The owner's record with primary key `id`.
    ///
    /// - Throws: `NexusHTTPError(.notFound)` when the record doesn't exist or
    ///   another owner holds it.
    public func get(_ id: some PrimaryKeyType) async throws -> Model {
        guard let record = try await repo.get(Model.self, id: id), record[keyPath: ownerField] == owner else {
            throw notFound()
        }
        return record
    }

    /// Inserts a new record with `changes` applied, owned by ``owner``.
    ///
    /// - Throws: `SpectroError.invalidSchema` when a changed property isn't a
    ///   column, and Spectro's errors when the insert fails.
    public func insert(_ changes: Changes<Model>) async throws -> Model {
        _ = try changes.columnValues()
        var record = Model()
        changes.apply(to: &record)
        record[keyPath: ownerField] = owner
        return try await repo.insert(record)
    }

    /// Writes `changes` to the owner's record with primary key `id`.
    ///
    /// When `Model` has an `updatedAt` timestamp that `changes` doesn't set,
    /// the update sets it to the current time. A change to the owner field is
    /// ignored.
    ///
    /// - Returns: The updated record.
    /// - Throws: `NexusHTTPError(.notFound)` when the record doesn't exist or
    ///   another owner holds it, and `SpectroError.invalidSchema` when a
    ///   changed property isn't a column.
    public func update(_ id: some PrimaryKeyType, _ changes: Changes<Model>) async throws -> Model {
        let metadata = await SchemaRegistry.shared.register(Model.self)
        let ownerName = Changes<Model>.name(of: ownerField)
        let values = try changes.columnValues(touching: metadata, excluding: ownerName)
        guard !values.isEmpty else { return try await get(id) }
        let statement = try Self.updateStatement(
            metadata, id: id.toPostgresData(), ownerField: ownerName, owner: owner.toPostgresData(), values: values)
        guard let row = try await repo.executeRawQuery(sql: statement.sql, parameters: statement.parameters).first else {
            throw notFound()
        }
        return try await Model.from(row: row)
    }

    /// Deletes the owner's record with primary key `id`. A schema with a
    /// `@SoftDelete` field marks the record deleted instead.
    ///
    /// - Throws: `NexusHTTPError(.notFound)` when the record doesn't exist or
    ///   another owner holds it.
    public func delete(_ id: some PrimaryKeyType) async throws {
        let metadata = await SchemaRegistry.shared.register(Model.self)
        let statement = try Self.deleteStatement(
            metadata, id: id.toPostgresData(), ownerField: Changes<Model>.name(of: ownerField),
            owner: owner.toPostgresData())
        guard try await !repo.executeRawQuery(sql: statement.sql, parameters: statement.parameters).isEmpty else {
            throw notFound()
        }
    }

    private func notFound() -> NexusHTTPError {
        NexusHTTPError(.notFound, message: "\(Model.self) not found")
    }
}

extension Repo {
    /// The records of `Model` whose `ownerField` is `owner`.
    ///
    /// ```swift
    /// let bookmarks = conn.repo().scoped(\Bookmark.userId, to: reader.userID)
    /// let bookmark = try await bookmarks.get(id)  // 404 unless the reader owns it
    /// ```
    public func scoped<Model: Schema, Owner: PrimaryKeyType>(
        _ ownerField: WritableKeyPath<Model, Owner> & Sendable,
        to owner: Owner
    ) -> ScopedRepo<Model, Owner> {
        ScopedRepo(self, ownerField, to: owner)
    }
}

// MARK: - SQL

extension ScopedRepo {
    struct Statement {
        let sql: String
        let parameters: [PostgresData]
    }

    static func updateStatement(
        _ metadata: SchemaMetadata,
        id: PostgresData,
        ownerField: String,
        owner: PostgresData,
        values: [(field: String, value: any Sendable)]
    ) throws -> Statement {
        var parameters: [PostgresData] = []
        var assignments: [String] = []
        for (field, value) in values {
            parameters.append(try SchemaMapper.convertToPostgresData(value))
            assignments.append("\(try column(field, in: metadata)) = $\(parameters.count)")
        }
        let match = try matching(metadata, ownerField: ownerField, firstParameter: parameters.count + 1)
        return Statement(
            sql: "UPDATE \(metadata.tableName.quoted) SET \(assignments.joined(separator: ", ")) "
                + "WHERE \(match) RETURNING *",
            parameters: parameters + [id, owner])
    }

    static func deleteStatement(
        _ metadata: SchemaMetadata,
        id: PostgresData,
        ownerField: String,
        owner: PostgresData
    ) throws -> Statement {
        let match = try matching(metadata, ownerField: ownerField, firstParameter: 1)
        let table = metadata.tableName.quoted
        let primaryKey = try primaryKeyColumn(in: metadata)
        let sql = if let softDelete = metadata.softDeleteField {
            "UPDATE \(table) SET \(softDelete.quoted) = NOW() WHERE \(match) RETURNING \(primaryKey)"
        } else {
            "DELETE FROM \(table) WHERE \(match) RETURNING \(primaryKey)"
        }
        return Statement(sql: sql, parameters: [id, owner])
    }

    /// Matches the primary key and the owner, numbered from `firstParameter`,
    /// and skips soft-deleted records as Spectro's queries do.
    private static func matching(_ metadata: SchemaMetadata, ownerField: String, firstParameter: Int) throws -> String {
        var sql = "\(try primaryKeyColumn(in: metadata)) = $\(firstParameter) "
            + "AND \(try column(ownerField, in: metadata)) = $\(firstParameter + 1)"
        if let softDelete = metadata.softDeleteField {
            sql += " AND \(softDelete.quoted) IS NULL"
        }
        return sql
    }

    private static func primaryKeyColumn(in metadata: SchemaMetadata) throws -> String {
        guard let field = metadata.fields.first(where: \.isPrimaryKey) else {
            throw SpectroError.invalidSchema(reason: "Schema \(Model.self) has no primary key field")
        }
        return field.databaseName.quoted
    }

    private static func column(_ field: String, in metadata: SchemaMetadata) throws -> String {
        guard let info = metadata.fields.first(where: { $0.name == field }) else {
            throw SpectroError.invalidSchema(reason: "Unknown column '\(field)' on \(Model.self)")
        }
        return info.databaseName.quoted
    }
}

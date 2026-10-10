import Foundation
import PostgresNIO
// Imports Spectro without Roost, so `Changeset` is Spectro's changeset, which
// the `Repo` requirements take, rather than Roost's validation changeset.
import Spectro

/// Records what a scoped repository sends, without a database.
final class RecordingRepo: Repo, @unchecked Sendable {
    private let lock = NSLock()
    private var _statements: [(sql: String, parameters: [PostgresData])] = []
    private var _inserted: [any Sendable] = []
    private var _updates: [[String: any Sendable]] = []
    private let stored: (any Sendable)?

    init(stored: (any Sendable)? = nil) { self.stored = stored }

    var statements: [(sql: String, parameters: [PostgresData])] { lock.withLock { _statements } }
    var inserted: [any Sendable] { lock.withLock { _inserted } }
    var updates: [[String: any Sendable]] { lock.withLock { _updates } }

    func executeRawQuery(sql: String, parameters: [PostgresData]) async throws -> [PostgresRow] {
        lock.withLock { _statements.append((sql, parameters)) }
        return []
    }

    func get<T: Schema>(_ schema: T.Type, id: some PrimaryKeyType) async throws -> T? { stored as? T }

    func insert<T: Schema>(_ instance: T, includePrimaryKey: Bool) async throws -> T {
        lock.withLock { _inserted.append(instance) }
        return instance
    }

    func update<T: Schema>(_ schema: T.Type, id: some PrimaryKeyType, changes: [String: any Sendable]) async throws -> T {
        lock.withLock { _updates.append(changes) }
        return T()
    }

    func getOrFail<T: Schema>(_ schema: T.Type, id: some PrimaryKeyType) async throws -> T { fatalError("unused") }
    func all<T: Schema>(_ schema: T.Type) async throws -> [T] { fatalError("unused") }
    func upsert<T: Schema>(_ instance: T, conflictTarget: ConflictTarget, set: [String]?, includePrimaryKey: Bool) async throws -> T { fatalError("unused") }
    func insertAll<T: Schema>(_ instances: [T], includePrimaryKey: Bool) async throws -> [T] { fatalError("unused") }
    func delete<T: Schema>(_ schema: T.Type, id: some PrimaryKeyType) async throws { fatalError("unused") }
    func transaction<T: Sendable>(_ work: @escaping @Sendable (any Repo) async throws -> T) async throws -> T { fatalError("unused") }
    func query<T: Schema>(_ schema: T.Type) -> Query<T> { fatalError("unused") }
    func executeRawSQL(_ sql: String) async throws { fatalError("unused") }
    func insert<T: Schema>(_ changeset: Changeset<T>) async throws -> T { fatalError("unused") }
    func update<T: Schema>(_ changeset: Changeset<T>) async throws -> T { fatalError("unused") }
}

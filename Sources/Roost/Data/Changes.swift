import Foundation
import Spectro

/// Values to write to a `Model`, each named by a key path to one of its properties.
///
/// Spectro's `update(_:id:changes:)` takes a `[String: any Sendable]`
/// dictionary, so a misspelled column or a value of the wrong type fails only
/// when the query runs. `Changes` names each field with a key path, so the
/// compiler checks both:
///
/// ```swift
/// let changes = Changes<Bookmark>().setting(\.read, to: true)
/// try await repo.update(Bookmark.self, id: id, changes)
/// ```
///
/// Decode changes from a request with ``Permitted``, check them with the key
/// path rules of ``ValidatorRule``, and write them with
/// ``Spectro/Repo/update(_:id:_:)`` or a ``ScopedRepo``.
///
/// Field names come from the `_keyPathToColumn` table that `@Schema`
/// generates. A key path missing from that table, such as a computed
/// property, still applies to a record in memory, but writing it to the
/// database throws.
public struct Changes<Model: Schema>: Sendable {
    private struct Change: Sendable {
        var value: any Sendable
        /// Writes `value`, which keeps the type of the property `set` received.
        let apply: @Sendable (inout Model, any Sendable) -> Void
    }

    /// The property names of the changed fields, in the order they were first set.
    public private(set) var fields: [String] = []
    private var changes: [String: Change] = [:]
    private var unmapped: Set<String> = []

    /// Creates an empty set of changes.
    public init() {}

    /// `true` when no field has been set.
    public var isEmpty: Bool { fields.isEmpty }

    /// Sets `field` to `value`, replacing an earlier value for the same field.
    public mutating func set<Value: Sendable>(_ field: WritableKeyPath<Model, Value> & Sendable, to value: Value) {
        let name = Self.name(of: field)
        if Model._keyPathToColumn[field] == nil { unmapped.insert(name) }
        if changes[name] == nil { fields.append(name) }
        changes[name] = Change(value: value) { record, value in
            if let value = value as? Value { record[keyPath: field] = value }
        }
    }

    /// Returns these changes with `field` set to `value`.
    ///
    /// ```swift
    /// let changes = Changes<Bookmark>().setting(\.read, to: true).setting(\.note, to: "")
    /// ```
    public func setting<Value: Sendable>(_ field: WritableKeyPath<Model, Value> & Sendable, to value: Value) -> Changes {
        var copy = self
        copy.set(field, to: value)
        return copy
    }

    /// The value set for `field`, or `nil` when it hasn't been set.
    public subscript<Value>(_ field: KeyPath<Model, Value>) -> Value? {
        changes[Self.name(of: field)]?.value as? Value
    }

    /// `true` when `field` has been set, including to `nil`.
    public func contains(_ field: PartialKeyPath<Model>) -> Bool {
        changes[Self.name(of: field)] != nil
    }

    /// Writes every change to `record`.
    public func apply(to record: inout Model) {
        for name in fields {
            guard let change = changes[name] else { continue }
            change.apply(&record, change.value)
        }
    }

    /// Returns these changes with leading and trailing whitespace and newlines
    /// removed from every `String` and `String?` value.
    public func trimmingWhitespace() -> Changes {
        var copy = self
        for name in fields {
            guard let text = copy.changes[name]?.value as? String else { continue }
            copy.changes[name]?.value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return copy
    }

    /// Checks these changes with `rules`.
    ///
    /// ```swift
    /// let valid = try await changes.validated(using: [
    ///     .required(\.title),
    ///     .length(\.title, max: 160),
    /// ])
    /// ```
    ///
    /// - Returns: These changes, unchanged, when every rule passes.
    /// - Throws: ``ValidationErrors`` naming each failing field.
    public func validated(
        using rules: [ValidatorRule<Changes>],
        strategy: ValidationStrategy = .sequential
    ) async throws -> Changes {
        var changeset = Changeset(data: self)
        await changeset.validate(using: rules, strategy: strategy)
        return try changeset.requireValid()
    }

    /// The property name a key path refers to. A key path `@Schema` didn't
    /// map keeps its description, which can't match a column.
    static func name(of field: AnyKeyPath) -> String {
        Model._keyPathToColumn[field] ?? String(describing: field)
    }

    /// The changes as Spectro's property-name dictionary.
    ///
    /// - Parameters:
    ///   - metadata: Spectro metadata for `Model`. When it lists an `updatedAt`
    ///     timestamp that these changes don't set, and there is something to
    ///     write, the result sets it to the current time.
    ///   - excluded: A field to leave out, such as a scoped repository's owner.
    /// - Throws: `SpectroError.invalidSchema` when a field isn't a column.
    func columnValues(
        touching metadata: SchemaMetadata? = nil,
        excluding excluded: String? = nil
    ) throws -> [(field: String, value: any Sendable)] {
        guard unmapped.isEmpty else {
            throw SpectroError.invalidSchema(
                reason: "\(Model.self) has no column for \(unmapped.sorted().joined(separator: ", ")). "
                    + "Changes can write the properties @Schema lists in _keyPathToColumn."
            )
        }
        var values: [(field: String, value: any Sendable)] = fields.compactMap { name in
            guard name != excluded else { return nil }
            return changes[name].map { (name, $0.value) }
        }
        if let metadata, !values.isEmpty, changes["updatedAt"] == nil,
           metadata.fields.contains(where: { $0.name == "updatedAt" && $0.isTimestamp }) {
            values.append(("updatedAt", Date()))
        }
        return values
    }
}

extension Repo {
    /// Updates the record with primary key `id`, writing only the fields in `changes`.
    ///
    /// ```swift
    /// let changes = Changes<Bookmark>().setting(\.read, to: true)
    /// let bookmark = try await repo.update(Bookmark.self, id: id, changes)
    /// ```
    ///
    /// When `T` has an `updatedAt` timestamp that `changes` doesn't set, the
    /// update sets it to the current time. To limit updates to one owner's
    /// records, use ``ScopedRepo/update(_:_:)`` instead.
    ///
    /// - Throws: `SpectroError.invalidSchema` when a changed property isn't a
    ///   column, and Spectro's errors when no record has primary key `id`.
    public func update<T: Schema>(_ schema: T.Type, id: some PrimaryKeyType, _ changes: Changes<T>) async throws -> T {
        let metadata = await SchemaRegistry.shared.register(schema)
        let values = try changes.columnValues(touching: metadata)
        guard !values.isEmpty else { return try await getOrFail(schema, id: id) }
        return try await update(schema, id: id, changes: Dictionary(values.map { ($0.field, $0.value) }, uniquingKeysWith: { $1 }))
    }
}

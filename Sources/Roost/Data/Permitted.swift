import Foundation
import Nexus
import Spectro

/// The fields of `Model` a request may set, like Ecto's `cast` or Rails'
/// strong parameters.
///
/// List the permitted properties once, then decode them from HTML forms and
/// JSON bodies into ``Changes``:
///
/// ```swift
/// extension Bookmark {
///     static let editable = Permitted<Bookmark>(\.title, \.url, \.note, \.read)
/// }
///
/// static func create(_ conn: Connection) async throws -> Connection {
///     let changes = try conn.permit(Bookmark.editable)
///     ...
/// }
/// ```
///
/// A request can't set a field the list leaves out, such as `userId`. The
/// parameter names are the property names; a JSON body may also use the
/// snake_case names `@Schema` writes, such as `read_at` for `readAt`, so a
/// client can send back a record it read. Each field decodes as its
/// property's type, the way ``Nexus/Connection/permit(_:decoder:)-(T.Type,_)`` decodes a
/// struct with the same properties: an unchecked checkbox is `false`, and a
/// missing field that isn't optional is an error.
///
/// A missing optional field is `nil` in a form, which sends every field it
/// shows. In a JSON body it's left out of the changes, so a partial update
/// keeps the stored value; send `null` to clear it.
public struct Permitted<Model: Schema>: Sendable {
    fileprivate struct Field: Sendable {
        let name: String
        let form: @Sendable (FormValues, inout Changes<Model>) throws -> Void
        let json: @Sendable (KeyedDecodingContainer<FieldKey>, inout Changes<Model>) throws -> Void
    }

    fileprivate let fields: [Field]

    /// Permits the properties `fields` refer to.
    public init<each Value: Decodable & Sendable>(_ fields: repeat WritableKeyPath<Model, each Value> & Sendable) {
        var list: [Field] = []
        for field in repeat each fields {
            list.append(Field(field))
        }
        self.fields = list
    }

    /// The permitted parameter names.
    public var names: [String] { fields.map(\.name) }

    func decode(_ values: FormValues) throws -> Changes<Model> {
        var changes = Changes<Model>()
        var errors = ValidationErrors()
        for field in fields {
            do {
                try field.form(values, &changes)
            } catch let error as ValidationErrors {
                errors.merge(error)
            }
        }
        guard errors.isValid else { throw errors }
        return changes
    }

    fileprivate func decode(from decoder: any Decoder) throws -> Changes<Model> {
        let container = try decoder.container(keyedBy: FieldKey.self)
        var changes = Changes<Model>()
        var errors = ValidationErrors()
        for field in fields {
            do {
                try field.json(container, &changes)
            } catch let error as DecodingError {
                errors.merge(try ValidationErrors(error))
            }
        }
        guard errors.isValid else { throw errors }
        return changes
    }
}

extension Permitted.Field {
    init<Value: Decodable & Sendable>(_ keyPath: WritableKeyPath<Model, Value> & Sendable) {
        let name = Changes<Model>.name(of: keyPath)
        self.name = name
        form = { values, changes in
            changes.set(keyPath, to: try values.decode(name, as: Value.self))
        }
        json = { container, changes in
            guard let key = FieldKey.matching(name, in: container) else {
                // A missing optional keeps the stored value; a missing required field throws.
                if Value.self is any OptionalValue.Type { return }
                changes.set(keyPath, to: try container.decode(Value.self, forKey: FieldKey(name)))
                return
            }
            do {
                changes.set(keyPath, to: try container.decode(Value.self, forKey: key))
            } catch let error as DecodingError {
                // Errors name the property, whichever spelling the body used.
                throw error.renamingField(key.stringValue, to: name)
            }
        }
    }
}

extension Connection {
    /// Decodes the fields `permitted` lists into ``Changes``.
    ///
    /// ```swift
    /// static func update(_ conn: Connection) async throws -> Connection {
    ///     let id: UUID = try conn.requireParam("id")
    ///     let changes = try conn.permit(Bookmark.editable)
    ///     ...
    /// }
    /// ```
    ///
    /// Parameters come from the same places as ``permit(_:decoder:)-(T.Type,_)``: the
    /// body of a JSON request, otherwise the query, form, and path
    /// parameters. Unlike decoding a struct, which stops at the first
    /// problem, every missing or invalid field is reported.
    ///
    /// - Throws: ``ValidationErrors`` naming each missing or invalid field.
    ///   A malformed JSON body throws `NexusHTTPError(.badRequest)`.
    public func permit<Model: Schema>(
        _ permitted: Permitted<Model>,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> Changes<Model> {
        guard isJSONRequest else {
            return try permitted.decode(FormValues(roost_formParameters))
        }
        guard case .buffered(let data) = requestBody, !data.isEmpty else {
            throw NexusHTTPError(.badRequest, message: "Missing request body")
        }
        do {
            return try PermittedDecoding.$fields.withValue(permitted) {
                try decoder.decode(PermittedBody<Model>.self, from: data).changes
            }
        } catch let error as DecodingError {
            throw try ValidationErrors(error)
        }
    }
}

extension FormValues {
    /// Decodes the fields `permitted` lists into ``Changes``, with the same
    /// conversions as ``decode(_:as:)``.
    ///
    /// ```swift
    /// let changes = try FormValues(["title": "Pie", "url": "https://example.com", "note": ""])
    ///     .decode(Bookmark.editable)
    /// ```
    ///
    /// - Throws: ``ValidationErrors`` naming each missing or invalid field.
    public func decode<Model: Schema>(_ permitted: Permitted<Model>) throws -> Changes<Model> {
        try permitted.decode(self)
    }
}

/// The permitted fields of the enclosing `permit` call. `JSONDecoder` only
/// constructs a type, so the fields travel in a task local rather than in the
/// caller's shared decoder's `userInfo`.
private enum PermittedDecoding {
    @TaskLocal static var fields: (any Sendable)?
}

private struct PermittedBody<Model: Schema>: Decodable {
    let changes: Changes<Model>

    init(from decoder: any Decoder) throws {
        guard let fields = PermittedDecoding.fields as? Permitted<Model> else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [], debugDescription: "Decode request bodies with Connection.permit(_:decoder:)."))
        }
        changes = try fields.decode(from: decoder)
    }
}

private struct FieldKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ name: String) { stringValue = name }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }

    /// The key a JSON body uses for the property `name`: the name itself, or
    /// the snake_case form `@Schema` encodes (`user_i_d` for `userID`) or the
    /// usual one (`user_id`).
    static func matching(_ name: String, in container: KeyedDecodingContainer<FieldKey>) -> FieldKey? {
        for candidate in [name, schemaSnakeCase(name), acronymSnakeCase(name)] {
            let key = FieldKey(candidate)
            if container.contains(key) { return key }
        }
        return nil
    }

    /// `@Schema`'s rule: an underscore before every uppercase letter.
    private static func schemaSnakeCase(_ name: String) -> String {
        var result = ""
        for (index, character) in name.enumerated() {
            if character.isUppercase && index > 0 { result += "_" }
            result += character.lowercased()
        }
        return result
    }

    /// An underscore where a lowercase letter or digit meets an uppercase one.
    private static func acronymSnakeCase(_ name: String) -> String {
        var result = ""
        var previous: Character?
        for character in name {
            if character.isUppercase, let previous, previous.isLowercase || previous.isNumber { result += "_" }
            result += character.lowercased()
            previous = character
        }
        return result
    }
}

extension DecodingError {
    /// This error with the top-level field `alias` in its path named `name` instead.
    fileprivate func renamingField(_ alias: String, to name: String) -> DecodingError {
        guard alias != name else { return self }
        func renamed(_ context: Context) -> Context {
            var path = context.codingPath
            if path.first?.stringValue == alias { path[0] = FieldKey(name) }
            return Context(codingPath: path, debugDescription: context.debugDescription,
                           underlyingError: context.underlyingError)
        }
        switch self {
        case .typeMismatch(let type, let context): return .typeMismatch(type, renamed(context))
        case .valueNotFound(let type, let context): return .valueNotFound(type, renamed(context))
        case .keyNotFound(let key, let context): return .keyNotFound(key, renamed(context))
        case .dataCorrupted(let context): return .dataCorrupted(renamed(context))
        @unknown default: return self
        }
    }
}

private protocol OptionalValue {}

extension Optional: OptionalValue {}

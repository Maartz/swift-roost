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
/// parameter names are the property names. Each field decodes as its
/// property's type, the way ``Nexus/Connection/permit(_:decoder:)-(T.Type,_)`` decodes a
/// struct with the same properties: a missing optional field is `nil`, an
/// unchecked checkbox is `false`, and any other missing field is an error.
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
            let key = FieldKey(name)
            // Synthesized `Decodable` treats a missing optional as `nil`.
            if !container.contains(key), let none = (Value.self as? any OptionalValue.Type)?.nilValue as? Value {
                changes.set(keyPath, to: none)
            } else {
                changes.set(keyPath, to: try container.decode(Value.self, forKey: key))
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
}

private protocol OptionalValue {
    static var nilValue: Self { get }
}

extension Optional: OptionalValue {
    fileprivate static var nilValue: Self { nil }
}

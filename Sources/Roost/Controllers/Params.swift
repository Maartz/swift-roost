import Foundation
import Nexus

extension Connection {
    /// Decodes the request's parameters into `T`, which acts as the list of
    /// permitted fields, like Rails' strong parameters or Ecto's `cast`.
    ///
    /// Fields `T` doesn't declare are dropped, so a form can't set `userId` or
    /// `admin` by adding them. Values are converted to the declared types.
    ///
    /// ```swift
    /// struct RecipeParams: Codable, Sendable {
    ///     let title: String
    ///     let servings: Int
    ///     let vegetarian: Bool
    ///     let notes: String?
    /// }
    ///
    /// static func create(_ conn: Connection) async throws -> Connection {
    ///     let params = try conn.permit(RecipeParams.self)
    ///     ...
    /// }
    /// ```
    ///
    /// JSON requests decode the body with `decoder`. Other requests decode
    /// query, form, and path parameters, with path parameters taking
    /// precedence over form fields, and form fields over the query. Form
    /// values follow ``FormValues``: blank optional fields become `nil`, an
    /// unchecked checkbox is `false`, and dates are ISO 8601.
    ///
    /// - Throws: ``ValidationErrors`` naming the first missing or invalid field.
    ///   A malformed JSON body throws `NexusHTTPError(.badRequest)`.
    public func permit<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        guard isJSONRequest else {
            return try FormValues(roost_formParameters).decode(as: T.self)
        }
        guard case .buffered(let data) = requestBody, !data.isEmpty else {
            throw NexusHTTPError(.badRequest, message: "Missing request body")
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch let error as DecodingError {
            throw try ValidationErrors(error)
        }
    }

    /// Query, form, and path parameters; later sources win.
    var roost_formParameters: [String: String] {
        var values = queryParams
        values.merge(bodyParams) { $1 }
        values.merge(params) { $1 }
        return values
    }

    /// Whether the request body is JSON: its content type is `application/json`,
    /// or a JSON-based type such as `application/vnd.api+json`.
    ///
    /// ``permit(_:decoder:)-(T.Type,_)`` decodes the body of a JSON request, and the
    /// query, form, and path parameters of any other.
    public var isJSONRequest: Bool {
        guard let type = request.headerFields[.contentType]?.lowercased() else { return false }
        return type.hasPrefix("application/json") || type.contains("+json")
    }
}

extension ValidationErrors {
    /// The field error a failed JSON decode stands for, as
    /// ``Nexus/Connection/permit(_:decoder:)-(T.Type,_)`` reports it: "can't be blank" for a
    /// missing or `null` value, and "is invalid" for a value of the wrong type or
    /// format. A nested field is named by its path, such as `address.city`, and
    /// an array element by its index, such as `tags.0`.
    ///
    /// ```swift
    /// do {
    ///     return try JSONDecoder().decode(Signup.self, from: data)
    /// } catch let error as DecodingError {
    ///     throw try ValidationErrors(error)
    /// }
    /// ```
    ///
    /// - Throws: `NexusHTTPError(.badRequest)` when the error isn't about a field:
    ///   the data isn't JSON, or isn't the expected kind of value at the top level.
    public init(_ error: DecodingError) throws {
        let path: [any CodingKey]
        let message: String
        let detail: String
        switch error {
        case .keyNotFound(let key, let context):
            path = context.codingPath + [key]
            message = "can't be blank"
            detail = context.debugDescription
        case .valueNotFound(_, let context):
            path = context.codingPath
            message = "can't be blank"
            detail = context.debugDescription
        case .typeMismatch(_, let context), .dataCorrupted(let context):
            path = context.codingPath
            message = "is invalid"
            detail = context.debugDescription
        @unknown default:
            throw NexusHTTPError(.badRequest, message: "Invalid JSON")
        }
        guard !path.isEmpty else {
            throw NexusHTTPError(.badRequest, message: "Invalid JSON: \(detail)")
        }
        self.init()
        add(field: path.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: "."), message)
    }
}

// MARK: - Form decoding

extension FormValues {
    /// Decodes all fields into `T` with the same conversions as
    /// ``decode(_:as:)``. Fields `T` doesn't declare are ignored.
    ///
    /// ```swift
    /// let input = try FormValues(["title": "Pie", "servings": "4"]).decode(as: RecipeParams.self)
    /// ```
    ///
    /// - Throws: ``ValidationErrors`` naming the first missing or invalid field.
    public func decode<T: Decodable>(as type: T.Type) throws -> T {
        try T(from: FormDecoder(values: self))
    }
}

/// Decodes a flat set of form fields with ``FormValues`` conversions.
/// Form parameters have no nesting, so nested containers are unsupported.
private struct FormDecoder: Decoder {
    let values: FormValues
    var codingPath: [any CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(FormContainer(values: values))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer { throw flat() }
    func singleValueContainer() throws -> any SingleValueDecodingContainer { throw flat() }
}

private func flat() -> DecodingError {
    .dataCorrupted(.init(codingPath: [], debugDescription: "Form parameters are flat name-value pairs; decode them into a struct."))
}

private struct FormContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let values: FormValues
    var codingPath: [any CodingKey] { [] }
    var allKeys: [Key] { values.values.keys.compactMap(Key.init(stringValue:)) }

    func contains(_ key: Key) -> Bool { values.values[key.stringValue] != nil }
    func decodeNil(forKey key: Key) throws -> Bool { values.values[key.stringValue]?.isEmpty ?? true }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try values.decode(key.stringValue, as: T.self)
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try values.decode(key.stringValue, as: type) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try values.decode(key.stringValue, as: type) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try values.decode(key.stringValue, as: type) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try values.decode(key.stringValue, as: type) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try values.decode(key.stringValue, as: type) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try values.decode(key.stringValue, as: type) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try values.decode(key.stringValue, as: type) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try values.decode(key.stringValue, as: type) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try values.decode(key.stringValue, as: type) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try values.decode(key.stringValue, as: type) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try values.decode(key.stringValue, as: type) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try values.decode(key.stringValue, as: type) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try values.decode(key.stringValue, as: type) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try values.decode(key.stringValue, as: type) }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> { throw flat() }
    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer { throw flat() }
    func superDecoder() throws -> any Decoder { throw flat() }
    func superDecoder(forKey key: Key) throws -> any Decoder { throw flat() }
}

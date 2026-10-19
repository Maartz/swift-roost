import Foundation

/// Cast URL-encoded form values without discarding the submitted text.
/// Keep `values` when rendering validation errors; never reconstruct invalid input
/// from a partially decoded model. Checkboxes omitted by browsers decode to false.
public struct FormValues: Sendable {
    public let values: [String: String]
    public let errors: ValidationErrors

    public init(_ values: [String: String], errors: ValidationErrors = ValidationErrors()) {
        self.values = values
        self.errors = errors
    }

    /// The original text and errors, suitable for `<.input field={form["title"]} ... />`.
    public subscript(_ name: String) -> FormInput {
        FormInput(name: name, value: values[name] ?? "", errors: errors[name])
    }

    public func decode<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        let raw = values[name]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if raw == nil || raw == "" {
            if let optional = try? decoder.decode(T.self, from: Data("null".utf8)) { return optional }
            if T.self == Bool.self, let unchecked = false as? T { return unchecked }
        }
        if let raw {
            if T.self == Bool.self || T.self == Bool?.self {
                let booleans = ["on": true, "true": true, "1": true, "off": false, "false": false, "0": false]
                if let value = booleans[raw.lowercased()],
                   let decoded = try? decoder.decode(T.self, from: JSONEncoder().encode(value)) { return decoded }
            } else {
                // String, UUID, ISO date and base64 Data are JSON string values.
                if let decoded = try? decoder.decode(T.self, from: JSONEncoder().encode(raw)) { return decoded }
                // Numbers and arrays use JSON's typed representation.
                if let decoded = try? decoder.decode(T.self, from: Data(raw.utf8)) { return decoded }
            }
        }
        var errors = ValidationErrors()
        errors.add(field: name, raw == nil ? "can't be blank" : "is invalid")
        throw errors
    }
}

/// The data an HTML field needs, independent of the model or action that validates it.
/// Resource libraries can conform their own field types to use Roost's components.
public protocol FormFieldRepresentable: Sendable {
    var name: String { get }
    var value: String { get }
    var errors: [String] { get }
    var inputType: String { get }
    var isRequired: Bool { get }
    var minLength: Int? { get }
    var maxLength: Int? { get }
    var isSensitive: Bool { get }
}

extension FormFieldRepresentable {
    public var errors: [String] { [] }
    public var inputType: String { "text" }
    public var isRequired: Bool { false }
    public var minLength: Int? { nil }
    public var maxLength: Int? { nil }
    public var isSensitive: Bool { inputType.lowercased() == "password" }
}

/// A field for ordinary Roost forms. `FormValues["title"]` pairs submitted text
/// with validation errors; an initializer can also supply constraints and defaults.
public struct FormInput: FormFieldRepresentable, Equatable {
    public let name: String
    public let value: String
    public let errors: [String]
    public let inputType: String
    public let isRequired: Bool
    public let minLength: Int?
    public let maxLength: Int?
    public let isSensitive: Bool

    public init(
        name: String, value: String = "", errors: [String] = [], type: String = "text",
        required: Bool = false, minLength: Int? = nil, maxLength: Int? = nil,
        sensitive: Bool = false
    ) {
        self.name = name
        self.isSensitive = sensitive || type.lowercased() == "password"
        self.value = self.isSensitive ? "" : value
        self.errors = errors
        self.inputType = self.isSensitive ? "password" : type
        self.isRequired = required
        self.minLength = minLength
        self.maxLength = maxLength
    }
}

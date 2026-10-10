import Foundation
import Spectro

// MARK: - Rules for Changes

/// Rules for ``Changes`` name each field with a key path, so the field name
/// in ``ValidationErrors`` comes from the schema instead of a repeated string:
///
/// ```swift
/// let valid = try await changes.validated(using: [
///     .required(\.title),
///     .length(\.title, max: 160),
///     .custom(\.url) { $0.hasPrefix("https://") ? nil : "must start with https://" },
/// ])
/// ```
///
/// A rule checks a field only when the changes set it, so a rule for `title`
/// doesn't fail an update that only changes `read`. The `required` rules are
/// the exception: they treat a field the changes don't set as blank.
extension ValidatorRule {

    /// Validates that a string field is set and not blank.
    public static func required<Model>(_ field: KeyPath<Model, String> & Sendable) -> ValidatorRule
    where T == Changes<Model> {
        let rule = ValidatorRule<String>.required(Changes<Model>.name(of: field)) { (value: String) in value }
        return ValidatorRule { changes in await rule.check(changes[field] ?? "") }
    }

    /// Validates that an optional string field is set, not `nil`, and not blank.
    public static func required<Model>(_ field: KeyPath<Model, String?> & Sendable) -> ValidatorRule
    where T == Changes<Model> {
        let rule = ValidatorRule<String?>.required(Changes<Model>.name(of: field)) { (value: String?) in value }
        return ValidatorRule { changes in await rule.check(changes[field] ?? nil) }
    }

    /// Validates that an optional field is set and not `nil`.
    public static func requiredValue<Model, Value: Sendable>(_ field: KeyPath<Model, Value?> & Sendable) -> ValidatorRule
    where T == Changes<Model> {
        let rule = ValidatorRule<Value?>.requiredValue(Changes<Model>.name(of: field)) { $0 }
        return ValidatorRule { changes in await rule.check(changes[field] ?? nil) }
    }

    /// Validates string length with min, max, or exact constraints.
    public static func length<Model>(
        _ field: KeyPath<Model, String> & Sendable,
        min: Int? = nil,
        max: Int? = nil,
        exact: Int? = nil
    ) -> ValidatorRule where T == Changes<Model> {
        checking(field, with: .length(Changes<Model>.name(of: field), { $0 }, min: min, max: max, exact: exact))
    }

    /// Validates the length of an optional string when it isn't `nil`.
    public static func length<Model>(
        _ field: KeyPath<Model, String?> & Sendable,
        min: Int? = nil,
        max: Int? = nil,
        exact: Int? = nil
    ) -> ValidatorRule where T == Changes<Model> {
        checking(field, with: .length(Changes<Model>.name(of: field), { $0 }, min: min, max: max, exact: exact))
    }

    /// Validates that a string matches a regex pattern.
    public static func format<Model>(
        _ field: KeyPath<Model, String> & Sendable,
        pattern: String,
        message: String? = nil
    ) -> ValidatorRule where T == Changes<Model> {
        checking(field, with: .format(Changes<Model>.name(of: field), { $0 }, pattern: pattern, message: message))
    }

    /// Validates that an optional string matches a regex pattern when it isn't `nil`.
    public static func format<Model>(
        _ field: KeyPath<Model, String?> & Sendable,
        pattern: String,
        message: String? = nil
    ) -> ValidatorRule where T == Changes<Model> {
        checking(field, with: .format(Changes<Model>.name(of: field), { $0 }, pattern: pattern, message: message))
    }

    /// Validates email format (case-insensitive).
    public static func email<Model>(_ field: KeyPath<Model, String> & Sendable) -> ValidatorRule
    where T == Changes<Model> {
        checking(field, with: .email(Changes<Model>.name(of: field)) { $0 })
    }

    /// Validates URL format (http/https).
    public static func url<Model>(_ field: KeyPath<Model, String> & Sendable) -> ValidatorRule
    where T == Changes<Model> {
        checking(field, with: .url(Changes<Model>.name(of: field)) { $0 })
    }

    /// Validates that a value is in an allowed set.
    public static func inclusion<Model, Value: Equatable & Sendable>(
        _ field: KeyPath<Model, Value> & Sendable,
        in allowed: [Value],
        message: String? = nil
    ) -> ValidatorRule where T == Changes<Model> {
        checking(field, with: .inclusion(Changes<Model>.name(of: field), { $0 }, in: allowed, message: message))
    }

    /// Validates that a value is not in a disallowed set.
    public static func exclusion<Model, Value: Equatable & Sendable>(
        _ field: KeyPath<Model, Value> & Sendable,
        from disallowed: [Value],
        message: String? = nil
    ) -> ValidatorRule where T == Changes<Model> {
        checking(field, with: .exclusion(Changes<Model>.name(of: field), { $0 }, from: disallowed, message: message))
    }

    /// Validates a numeric value against range constraints.
    public static func number<Model, Number: Comparable & Sendable>(
        _ field: KeyPath<Model, Number> & Sendable,
        greaterThan: Number? = nil,
        greaterThanOrEqual: Number? = nil,
        lessThan: Number? = nil,
        lessThanOrEqual: Number? = nil
    ) -> ValidatorRule where T == Changes<Model> {
        checking(field, with: .number(
            Changes<Model>.name(of: field), { $0 },
            greaterThan: greaterThan, greaterThanOrEqual: greaterThanOrEqual,
            lessThan: lessThan, lessThanOrEqual: lessThanOrEqual))
    }

    /// Validates one field with a closure that returns an error message, or
    /// `nil` when the value is valid.
    ///
    /// ```swift
    /// .custom(\.url) { url in url.hasPrefix("https://") ? nil : "must start with https://" }
    /// ```
    public static func custom<Model, Value: Sendable>(
        _ field: KeyPath<Model, Value> & Sendable,
        _ check: @escaping @Sendable (Value) -> String?
    ) -> ValidatorRule where T == Changes<Model> {
        let name = Changes<Model>.name(of: field)
        return checking(field, with: ValidatorRule<Value> { value in check(value).map { [.field(name, $0)] } ?? [] })
    }

    /// Runs `rule` on the value of `field` when the changes set it.
    private static func checking<Model, Value: Sendable>(
        _ field: KeyPath<Model, Value> & Sendable,
        with rule: ValidatorRule<Value>
    ) -> ValidatorRule where T == Changes<Model> {
        ValidatorRule { changes in
            guard let value = changes[field] else { return [] }
            return await rule.check(value)
        }
    }

    /// Runs `rule` on the value of an optional `field` when the changes set it
    /// to a value other than `nil`.
    private static func checking<Model, Value: Sendable>(
        _ field: KeyPath<Model, Value?> & Sendable,
        with rule: ValidatorRule<Value>
    ) -> ValidatorRule where T == Changes<Model> {
        ValidatorRule { changes in
            guard let value = changes[field] ?? nil else { return [] }
            return await rule.check(value)
        }
    }
}

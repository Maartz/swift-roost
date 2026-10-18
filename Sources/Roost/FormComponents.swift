import ESW

/// A labeled input with constraints, a hint, and field errors. A checkbox uses
/// the same component with `type="checkbox"` (or a field whose inputType is checkbox).
/// Values, labels, hints, and errors are plain text and are escaped.
public struct Input: ESWComponent {
    public static func render(
        field: some FormFieldRepresentable,
        label: String,
        type: String? = nil,
        id: String? = nil,
        `class`: String? = nil,
        labelClass: String? = nil,
        hint: String? = nil,
        placeholder: String? = nil,
        required: Bool? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        attributes: [String: String] = [:]
    ) -> String {
        let type = field.isSensitive ? "password" : (type ?? field.inputType).lowercased()
        let presentation = FieldPresentation(field: field, id: id, hint: hint)
        guard let common = presentation.attributes(
            class: `class`, required: required, minLength: minLength, maxLength: maxLength,
            attributes: attributes
        ) else { return FieldPresentation.invalidAttributes() }
        let checkbox = type == "checkbox"
        let value = type == "password" ? "" : (checkbox ? "true" : field.value)
        let checked = checkbox && ["true", "on", "1"].contains(field.value.lowercased())
        let control = "<input" + ESW.attribute("type", type) + common
            + ESW.attribute("value", value) + ESW.attribute("checked", checked)
            + ESW.attribute("placeholder", placeholder) + ">"
        return presentation.render(control, label: label, labelClass: labelClass, checkbox: checkbox)
    }
}

/// A labeled multiline field. The browser's initial-newline stripping is accounted
/// for, so a submitted value that starts with a newline survives another render.
public struct Textarea: ESWComponent {
    public static func render(
        field: some FormFieldRepresentable,
        label: String,
        id: String? = nil,
        `class`: String? = nil,
        labelClass: String? = nil,
        hint: String? = nil,
        placeholder: String? = nil,
        rows: Int = 4,
        required: Bool? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        attributes: [String: String] = [:]
    ) -> String {
        let presentation = FieldPresentation(field: field, id: id, hint: hint)
        guard let common = presentation.attributes(
            class: `class`, required: required, minLength: minLength, maxLength: maxLength,
            attributes: attributes
        ) else { return FieldPresentation.invalidAttributes() }
        let value = field.isSensitive ? "" : field.value
        let control = "<textarea" + common + ESW.attribute("rows", max(1, rows))
            + ESW.attribute("placeholder", placeholder) + ">"
            + (value.hasPrefix("\n") || value.hasPrefix("\r") ? "\n" : "")
            + ESW.escape(value) + "</textarea>"
        return presentation.render(control, label: label, labelClass: labelClass)
    }
}

private struct FieldPresentation {
    let field: any FormFieldRepresentable
    let id: String
    let hint: String?

    init(field: any FormFieldRepresentable, id: String?, hint: String?) {
        self.field = field
        // Preserve simple names; encode other bytes without collisions or whitespace.
        // Pass an explicit id when the same field appears in multiple forms on a page.
        self.id = id ?? field.name.utf8.map { byte in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 {
                return String(UnicodeScalar(byte))
            }
            return "_" + String(byte, radix: 16)
        }.joined()
        self.hint = hint
    }

    func attributes(
        `class`: String?, required: Bool?, minLength: Int?, maxLength: Int?,
        attributes: [String: String]
    ) -> String? {
        let reserved: Set<String> = [
            "id", "name", "type", "value", "checked", "class", "required", "minlength", "maxlength",
            "rows", "placeholder", "aria-invalid",
        ]
        var extra = ""
        var describedBy: [String] = []
        for (name, value) in attributes.sorted(by: { $0.key < $1.key }) {
            let normalized = name.lowercased()
            guard !reserved.contains(normalized),
                  let first = name.utf8.first, (65...90).contains(first) || (97...122).contains(first),
                  name.utf8.allSatisfy({
                      (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                          || $0 == 45 || $0 == 95 || $0 == 58 || $0 == 46
                  }) else { return nil }
            if normalized == "aria-describedby" {
                describedBy += value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            } else {
                extra += ESW.attribute(name, value)
            }
        }
        if hint != nil { describedBy.append(id + "-hint") }
        if !field.errors.isEmpty { describedBy.append(id + "-errors") }
        return ESW.attribute("id", id) + ESW.attribute("name", field.name)
            + ESW.attribute("class", `class`)
            + ESW.attribute("minlength", minLength ?? field.minLength)
            + ESW.attribute("maxlength", maxLength ?? field.maxLength)
            + ESW.attribute("required", required ?? field.isRequired)
            + ESW.attribute("aria-invalid", !field.errors.isEmpty)
            + (describedBy.isEmpty ? "" : ESW.attribute("aria-describedby", describedBy.joined(separator: " ")))
            + extra
    }

    func render(_ control: String, label: String, labelClass: String?, checkbox: Bool = false) -> String {
        let labelStart = "<label" + ESW.attribute("for", id) + ESW.attribute("class", labelClass) + ">"
        var html = checkbox
            ? labelStart + control + " " + ESW.escape(label) + "</label>"
            : labelStart + ESW.escape(label) + "</label>" + control
        if let hint {
            html += "<p" + ESW.attribute("id", id + "-hint") + " class=\"field-hint\">" + ESW.escape(hint) + "</p>"
        }
        if !field.errors.isEmpty {
            html += "<div" + ESW.attribute("id", id + "-errors") + " class=\"field-errors\" role=\"alert\">"
            for error in field.errors { html += "<p class=\"field-error\">" + ESW.escape(error) + "</p>" }
            html += "</div>"
        }
        return html
    }

    static func invalidAttributes() -> String {
        FormRenderContext.current?.record(.invalidFieldAttribute)
        return "<!-- Roost field omitted: invalid or reserved attribute -->"
    }
}

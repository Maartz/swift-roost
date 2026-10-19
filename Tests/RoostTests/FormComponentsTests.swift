import NexusTest
import Roost
import Testing

@Suite("Form components")
struct FormComponentsTests {
    @Test func submittedTextErrorsAndConstraintsReachCompiledTemplates() {
        var errors = ValidationErrors()
        errors.add(field: "title", "can't contain <markup>")
        let form = FormValues(["title": "  \"<script> &  "], errors: errors)
        let html = #esw(#"""
        <.input field={form["title"]} label="Title" hint="A short name" required={true} maxLength={160} />
        """#)
        #expect(html.contains(#"value="  &quot;&lt;script&gt; &amp;  ""#))
        #expect(html.contains(#"maxlength="160" required"#))
        #expect(html.contains(#"aria-invalid="true""#))
        #expect(html.contains(#"aria-describedby="title-hint title-errors""#))
        #expect(html.contains(#"<label for="title">Title</label>"#))
        #expect(html.contains(#"id="title-hint""#) && html.contains(#"id="title-errors""#))
        #expect(html.contains("&lt;markup&gt;") && !html.contains("<script>"))
        #expect(html.contains(#"role="alert""#))
    }

    @Test func metadataFromOtherLibrariesNeedsNoConversion() {
        struct ResourceField: FormFieldRepresentable {
            let name = "email"
            let value = "person@example.org"
            let inputType = "email"
            let isRequired = true
            let maxLength: Int? = 80
        }
        let field = ResourceField()
        let html = #hesw(#"<.input field={field} label="Email" />"#)
        #expect(html.contains(#"type="email""#) && html.contains(#"maxlength="80" required"#))
        #expect(html.contains(#"value="person@example.org""#))
        #expect(!html.contains("aria-describedby"))
        #expect(!html.contains("field-errors"))
    }

    @Test(arguments: ["true", "TRUE", "on", "1", "false", "", "off", "0"])
    func checkboxUsesTheSameBooleanValuesAsFormDecoding(value: String) throws {
        let form = FormValues(["read": value])
        let html = Input.render(field: form["read"], label: "Read", type: "checkbox", labelClass: "check")
        #expect(html.contains(" checked") == (try form.decode("read", as: Bool.self)))
        #expect(html.contains(#"value="true""#))
        #expect(!html.contains("hidden"))
        #expect(html.hasPrefix(#"<label for="read" class="check"><input"#))
    }

    @Test func omittedCheckboxIsUncheckedOnRetry() throws {
        var errors = ValidationErrors()
        errors.add(field: "title", "can't be blank")
        let submitted = FormValues(["title": ""], errors: errors)
        #expect(try !submitted.decode("read", as: Bool.self))
        #expect(!Input.render(field: submitted["read"], label: "Read", type: "checkbox").contains(" checked"))
    }

    @Test func passwordsAndSensitiveFieldsAreNeverRepopulated() {
        let form = FormValues(["password": "secret"])
        #expect(!Input.render(field: form["password"], label: "Password", type: "PASSWORD").contains("secret"))
        let field = FormInput(name: "token", value: "secret", sensitive: true)
        let html = Input.render(field: field, label: "Token", type: "text")
        #expect(html.contains(#"type="password""#) && !html.contains("secret"))
        #expect(!Textarea.render(field: field, label: "Token").contains("secret"))
    }

    @Test func multilineInputEscapesClosingTagsAndPreservesTheInitialNewline() {
        let field = FormInput(name: "note", value: "\n</textarea><script>alert(1)</script>", errors: ["Too long"])
        let html = #esw(#"<.textarea field={field} label="Note" maxLength={10} />"#)
        #expect(html.contains(">\n\n&lt;/textarea&gt;&lt;script&gt;alert(1)&lt;/script&gt;</textarea>"))
        #expect(html.contains(#"aria-invalid="true" aria-describedby="note-errors""#))
        #expect(html.contains(#"maxlength="10""#))
    }

    @Test func customIDsDescriptionsAndEscapingWorkTogether() {
        let field = FormInput(name: "person[title]", value: "x")
        let html = Input.render(
            field: field, label: "<Title>", id: "edit-title", class: "wide\" data-x=\"no",
            hint: "<Hint>", attributes: ["ARIA-DESCRIBEDBY": "help", "data-kind": "\"<value>"]
        )
        #expect(html.contains(#"for="edit-title""#) && html.contains(#"id="edit-title""#))
        #expect(html.contains(#"name="person[title]""#))
        #expect(html.contains(#"aria-describedby="help edit-title-hint""#))
        #expect(html.contains("&lt;Title&gt;") && html.contains("&lt;Hint&gt;"))
        #expect(html.contains(#"class="wide&quot; data-x=&quot;no""#))
        #expect(html.contains(#"data-kind="&quot;&lt;value&gt;""#))
        let implicit = Input.render(field: field, label: "Title")
        #expect(implicit.contains(#"id="person_5btitle_5d""#))
        #expect(!Input.render(field: FormInput(name: "person_5btitle_5d"), label: "Title")
            .contains(#"id="person_5btitle_5d""#))
    }

    @Test(arguments: ["VALUE", "name", "aria-invalid", "checked", "data-x\" onclick", "a b"])
    func invalidAttributesRejectTheResponse(name: String) {
        struct Page: ESWView {
            let name: String
            func render() -> String {
                Input.render(field: FormInput(name: "title"), label: "Title", attributes: [name: "x"])
            }
        }
        #expect(throws: ViewRenderingError.self) { try TestConnection.build().render(Page(name: name)) }
        #expect(!Page(name: name).render().contains("<input"))
    }
}

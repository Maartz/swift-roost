# Views, layouts, and forms

Render typed ESW views with the current request's layout and CSRF context.

## Overview

Roost re-exports ESW, but file templates need a direct ESW package dependency and
`ESWBuildPlugin` on the application target. `roost new MyApp` configures both.
An app generated with `--no-esw` does not have that setup.

The typed-view APIs are available since ESW 1.6.0. Roost requires ESW 1.7.0
for its live runtime and structured templates; see <doc:LivePages>.

### Define a typed view

Put `WelcomeView.swift` beside `welcome.esw` in the app's `Views/` directory:

```swift
import Roost

@ESWTemplate("welcome.esw")
struct WelcomeView {
    let name: String
}
```

The template begins directly with HTML. Its inputs are the Swift properties:

```html
<main>
  <h1>Hello, <%= name %>.</h1>
  <.form action="/greetings" method="post">
    <label for="name">Your name</label>
    <input id="name" name="name" value="<%= name %>" required>
    <button type="submit">Say hello</button>
  </.form>
</main>
```

ESW generates the renderer at build time and escapes ordinary dynamic output.
Unknown Swift names and incompatible types are compiler errors. The component
`<.form>` resolves to Roost's ``Form``.

### Render through the connection

Use this pattern inside an application whose target includes the ESW build
plugin and the two view files above:

```swift
import Roost

@main
struct WelcomeApp: RoostApp {
    let sessionStore: (any SessionStore)? = MemorySessionStore()

    var plugs: [Plug] {
        [requestId(), roost_requestLogger()] + browserPlugs()
    }

    @RouteBuilder var routes: [Route] {
        GET("/", GreetingController.self, .new)
        POST("/greetings", GreetingController.self, .create)
    }
}

struct GreetingParams: Codable, Sendable {
    let name: String
}

struct GreetingController: Controller {
    enum Action: String, ControllerAction { case new, create }

    static func action(_ action: Action) -> Plug {
        switch action {
        case .new: new
        case .create: create
        }
    }

    static func new(_ conn: Connection) async throws -> Connection {
        try conn.render(WelcomeView(name: "Ada"), title: "Welcome")
    }

    static func create(_ conn: Connection) async throws -> Connection {
        let params = try conn.permit(GreetingParams.self)
        return try conn.render(WelcomeView(name: params.name), title: "Hello")
    }
}
```

`conn.render` creates a request-local rendering scope. Local mutating forms
receive the token prepared by the session and CSRF middleware. A missing token
or invalid form configuration throws ``ViewRenderingError`` instead of emitting
an unprotected form. Directly calling a form view's `render()` bypasses this
response boundary.

GET forms and external forms do not receive a session token. PUT, PATCH, and
DELETE forms submit a POST with a hidden `_method` field. Form actions and
attributes are validated; attribute values are escaped. Component `content`
is already-rendered HTML, so do not pass unescaped visitor input as content.

### Apply one layout

Set `RoostApp.layout` once. Its ``HTMLLayout`` closure receives the connection,
page title, and rendered content:

```swift
var layout: HTMLLayout? {
    { conn, title, content in
        LayoutView(conn: conn, title: title, content: content).render()
    }
}
```

The generator creates `LayoutView` and `layout.esw` for this pattern. Escape the
title and any other plain data in the layout. Insert the already-rendered page
with ESW's explicit raw-output syntax, as the generated layout does, to avoid
escaping the HTML a second time.

### Retain invalid input

Keep `conn.bodyParams` when handling a form error. `conn.permit(_:)` decodes
form values with ``FormValues``, which keeps their original text. An omitted
nonoptional Boolean decodes to `false`; an optional empty value can decode to
`nil`. Decoding failures throw ``ValidationErrors``. Fields the input type
doesn't declare, or a ``Permitted`` list leaves out, are ignored.

The generated resource catches those errors and renders the form again with
the submitted values, field errors, and status `.unprocessableContent` (422).
Its context validates the input as well, so JSON and HTML callers follow the
same rules.

### Render fields without repeating their plumbing

``Input`` and ``Textarea`` render a label, the control, an optional hint, and
validation errors. Use ``FormValues`` to keep submitted text and errors together:

```html
<% let form = FormValues(values, errors: errors) %>
<.form action="/bookmarks" method="post">
  <.input field={form["title"]} label="Title" required={true} maxLength={160} />
  <.input field={form["url"]} label="Link" type="url" />
  <.textarea field={form["note"]} label="Note" hint="Something to remember" />
  <.input field={form["read"]} label="Already read" type="checkbox" />
  <button type="submit">Save</button>
</.form>
```

The field's raw value is escaped, including after a failed submission. Password
inputs are always empty. A checkbox submits `true` when checked and is omitted
when unchecked, as ``FormValues`` expects; no duplicate hidden value is added.
Labels, hints, and error messages are plain text, not raw HTML.

Each control has an ID derived from its name, a matching label, and
`aria-invalid`. `aria-describedby` references only hints and errors actually
present. Supply `id="edit-title"` when the same field appears more than once
on a page; the label, hint, and error IDs follow that override. Error messages
are rendered as supplied, without automatically prefixing the label.

For defaults or metadata, construct a ``FormInput`` directly. Libraries can
conform their own field type to ``FormFieldRepresentable``: the components then
take the input type, required flag, length constraints, value, and errors from
that field. Named component arguments override presentation defaults. Sensitive
fields stay empty even when a component requests another input type.

These components supply HTML, without CSS or JavaScript dependencies. Style
ordinary elements, `.field-hint`, `.field-errors`, and `.field-error` in your app.
`class` styles the control; `labelClass` styles its label. `attributes` adds
HTML attributes such as `autocomplete`, `disabled`, or `data-*`; its names are
validated and values escaped. `aria-describedby` is merged with the generated
references. Reserved control attributes use the named arguments instead.
As with `<.form>`, inline event-handler attribute values are trusted application
code, never visitor input.

Use native HTML for other controls or define an application component to choose
your own markup. For example, an app-local `Input: ESWComponent` can replace the
default `<.input>` while continuing to accept ``FormFieldRepresentable``.
``FormValues/errors`` also retains model-level errors for a form-wide notice;
field components display only the errors associated with their field.

### Use an inline fragment

For a small response that does not contain a request-aware form, an inline
template in the controller action is enough:

```swift
static func fragment(_ conn: Connection) async throws -> Connection {
    let name = conn.queryParams["name"] ?? "world"
    return conn.html(#hesw("<h1>Hello, {name}.</h1>"))
}
```

`conn.html` sends the supplied string directly. It does not apply
`RoostApp.layout` or establish the rendering context used by `Form`.

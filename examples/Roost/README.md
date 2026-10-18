# Roost

The Roost reading-list example, built with the **Roost.** web framework. Save links and notes, mark things as
read, and keep each reader's queue private. The pages are ESW templates; the HTML
forms and JSON API call the same Spectro-backed context. There is no JavaScript
build step.

Pages use ordinary Swift view files, for example `auth/RegisterView.swift`, with
`@ESWTemplate("register.esw")`. The templates start directly with HTML. View structs
hold page data and presentation helpers; routes call `try conn.render(view)`.
`RoostExample.layout` configures the shared layout once. `<.form>` obtains CSRF
protection from the request and generates method overrides, including for logout
and bookmark actions. SwiftPM tracks both the Swift sources and templates.

## Run it

From this directory:

```sh
./dev
```

Open **http://127.0.0.1:4000**. The local demo account is:

```text
Email     reader@roost.test
Password  Read-with-Roost-2026
```

You can also create your own account. It starts with an empty reading queue.

The helper creates `roost_dev` if needed, builds the app, applies migrations,
and starts Roost's development server. Swift and ESW edits trigger a rebuild
and restart; refresh the browser once the rebuild completes. Ctrl-C stops it.
Your development data remains available for the next run.

Prerequisites: Swift 6.3+, Python 3, a local PostgreSQL server, and `psql`,
`createdb`, and `dropdb` on `PATH`. On Linux, Nexus also needs `zlib1g-dev`.

The app requires **Roost from 2.1.0, ESW from 1.6.0, Spectro from 2.3.0, and
Nexus from 2.1.0** and fetches them from GitHub. No local package dependency is required. If you
previously used local dependencies, clear all overrides before starting:

```sh
unset ROOST_FRAMEWORK_PATH ROOST_ESW_PATH ROOST_ECOSYSTEM_PATH
```

The helper builds the CLI from the containing release checkout. The application
itself downloads the framework through SwiftPM, including when opened in an
editor. Contributors can explicitly select a framework checkout with
`ROOST_FRAMEWORK_PATH`, all companion sources with `ROOST_ECOSYSTEM_PATH`, or
ESW alone with `ROOST_ESW_PATH`.

Defaults match a local Postgres.app installation: the current OS user, an empty
password, `localhost:5432`. Override them when needed:

```sh
DB_USER=postgres DB_PASSWORD=postgres ROOST_PORT=4001 ./dev
```

Set `ROOST_DEMO=0` to skip sample data. Demo seeding only runs in the development
environment and leaves an existing demo account alone. Sessions live in memory,
so a server restart requires logging in again. The helpers only connect to local
PostgreSQL; deployment configuration is outside their scope.

## A five-minute tour

1. Log in to the demo to see three unread links and one finished link.
2. Save a link. Leave the title blank or enter an incomplete URL to see a 422
   response with field errors and the entered values preserved.
3. Click the circle beside a link. It moves to **Finished** without changing its
   title, URL, or note. Open **Details** to edit it or move it back.
4. Visit `/api/bookmarks` in the same browser to see the JSON representation.
5. Create another account. Its queue is empty, and the first reader's record
   URLs return 404.
6. Change a heading in `Sources/RoostExample/Views/bookmarks/index.esw`, wait for the
   rebuild, and refresh.

## Start with three generators

The original app was scaffolded with these three generators. After the framework
rename, use `RoostExample` as the Swift module name to keep it separate from the
`Roost` framework module:

```sh
roost new RoostExample
cd RoostExample
roost gen auth
roost gen resource Bookmark title:string url:string note:text read:bool --both --scope user_id
```

The generators supplied the user and token models, authentication context,
ownership-scoped bookmark context, route registration, SQL migrations, HTML and
JSON handlers, templates, and an input test.

Application-specific additions are deliberately visible:

| File | What the app adds |
| --- | --- |
| [App.swift](Sources/RoostExample/App.swift) | Home redirect and opt-in demo seeding. |
| [BookmarksContext.swift](Sources/RoostExample/Contexts/BookmarksContext.swift) | Trimmed input, complete web URL validation, optional notes, and `setRead`. |
| [BookmarksRoutes.swift](Sources/RoostExample/Routes/BookmarksRoutes.swift) | Reading filters and the `POST /bookmarks/:id/read` action. |
| [ReadingQueue.swift](Sources/RoostExample/ReadingQueue.swift) | Three filter values and displayable link domains. |
| [Migrations](Sources/RoostExample/Migrations) | The generated SQL as bundled history, and three Swift migrations written since. |
| [Views](Sources/RoostExample/Views) | The reading queue, shared editor form, details, and account pages. |
| [app.css](Public/css/app.css) | Responsive styling, keyboard focus, and the reading-list identity. |
| [local.py](scripts/local.py) | Local setup and disposable test databases. |

The generated authentication implementation and JSON routes retain their original
behavior. The generated Pico stylesheet was replaced with the app's own CSS.

## Follow one action

The route gets the authenticated identity from the connection, decodes form
values, and calls the context. `setRead` is the application operation:

```swift
func setRead(id: UUID, read: Bool, scopeId: UUID) async throws {
    _ = try await getBookmark(id: id, scopeId: scopeId)
    _ = try await repo.update(Bookmark.self, id: id, changes: [
        "read": read,
        "updatedAt": Date(),
    ])
}
```

The owner check is inside the context, so it also applies to direct callers.
The route's return value sets a one-time flash message and redirects. The form
contains a CSRF token; Roost handles form decoding, session persistence,
method overrides, and flash delivery.

The API provides `GET` and `POST /api/bookmarks`, plus `GET`, `PUT`, and `DELETE
/api/bookmarks/:id`. JSON creates and updates take `title`, `url`, `note`, and
`read`. Mutating requests use the login cookie and an `X-CSRF-Token` header;
the token is present in the HTML forms. Validation returns JSON field errors
with status 422. Client-supplied ownership fields are not part of the input type.

## Evolve the schema

The generators wrote SQL migrations. The app now bundles them unchanged in
`Migrations/SQL` and lists them in `App.swift` with the Swift migrations
written since:

```swift
var migrations: MigrationRegistry? {
    MigrationRegistry {
        SQLMigrations(bundle: .module, directory: "SQL")
        TrackWhenLinksAreRead()
        IndexReadingQueues()
        RequireWebLinks()
    }
}
```

- [TrackWhenLinksAreRead](Sources/RoostExample/Migrations/TrackWhenLinksAreRead.swift)
  adds `read_at` and backfills it inside `Reversible`, because `AlterTable`
  can't drop a column. A trigger then keeps `read_at` in step with `read`, so
  the read button, the edit form, and the JSON API agree. The details page
  shows the date.
- [IndexReadingQueues](Sources/RoostExample/Migrations/IndexReadingQueues.swift)
  replaces the index on `user_id` with one on `(user_id, created_at)`, which
  matches the queue's query.
- [RequireWebLinks](Sources/RoostExample/Migrations/RequireWebLinks.swift)
  makes the database refuse links that aren't http or https, even when the
  context's validation is skipped.

Preview the SQL without a database, in either direction:

```sh
swift run RoostExample migrate plan
swift run RoostExample migrate plan --direction down
```

`./dev` and `./check` apply pending migrations as before, and so does
`roost migrate up`. `roost migrate down` rolls back the newest one.

## Test it

```sh
./check
```

This creates a uniquely named database, runs migrations and `swift test`, then
removes only that database, including when tests fail. It never reuses `DB_NAME`
for its test database.

- [Input tests](Tests/RoostExampleTests/BookmarkInputTests.swift) exercise normalization,
  optional notes, unchecked Boolean input, empty titles, and invalid URL schemes.
- [Workflow tests](Tests/RoostExampleTests/ReadingWorkflowTests.swift) run real PostgreSQL
  operations through `TestApp` and two independent browser cookie jars: signup,
  retained validation input, HTML escaping, flash, CSRF, JSON, reading state,
  editing, ownership, deletion, and logout.
- The transaction test injects one repository into both a context and the HTTP
  pipeline, then verifies rollback. Registration uses its own transaction and
  is exercised separately in the disposable database.

For example, a browser test looks like this:

```swift
let app = try await TestApp(RoostExample.self)
let reader = app.browser()
let page = try await reader.get("/bookmarks/new")
// Extract the CSRF token, post the form, assert the redirect and persisted record.
await app.shutdown()
```

For raw Swift commands, export the `DB_*` variables yourself. The manifest locates
the framework and resolves released companion packages by default.
The helpers set environment variables for their child processes, not your parent shell.

## What this reveals about the DX

The useful part is the continuity: one generator connects routes, persistence,
views, authentication, and tests. Adding a domain action takes a context method,
a route, and a form. A custom input rule immediately applies to HTML and JSON.

The remaining friction is visible in this example:

- Local database creation, seeding, and test database ownership still need an
  app helper. Those are good candidates for first-class CLI commands.
- Routes repeat identity extraction and context construction. A typed authenticated
  scope would reduce this repetition.
- Authentication fixtures and async database cleanup are verbose in tests.
- Generated forms need domain-specific labels and validation. Here, a URL needs
  more than the generated non-empty string rule, while a note is optional.
- The reading filters currently load one user's bookmarks and filter in Swift.
  Larger queues need filtering and pagination in the repository query.
- SwiftPM emits a `swift-syntax` dependency identity warning across the companion
  packages. It does not require using local dependency checkouts.

These files are a small, runnable example of the present framework surface.

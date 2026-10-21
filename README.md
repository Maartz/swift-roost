<div align="center">
  <img src="assets/brand/roost-mark.png" alt="Roost falcon mark" width="156" height="156">
  <h1>roost<img src="assets/brand/orange-dot.svg" alt="." width="9" height="9"></h1>
  <p><strong>A good home for your Swift app.</strong></p>
  <p>A web framework inspired by Phoenix.<br>Built with Nexus, Spectro, and ESW.</p>
  <p>
    <a href="https://roost-framework.github.io/swift-roost/">Website</a> ·
    <a href="https://roost-framework.github.io/swift-roost/playground.html">Playground</a> ·
    <a href="Documentation/README.md">Documentation</a> ·
    <a href="#quickstart">Quickstart</a> ·
    <a href="examples/Roost">Try the reading-list example</a> ·
    <a href="guides/tutorial-todo-app.md">Build a Todo app</a> ·
    <a href="#the-stack">The stack</a> ·
    <a href="Sources/Roost/Roost.docc/ProjectStatus.md">Project status</a>
  </p>
</div>

---

Roost brings the parts of a Swift web application together: routes, data,
templates, forms, authentication, and tests. Keep business operations in contexts,
render HTML and JSON from the same validated input, and let generators connect
the files around them.

**Less wiring. More building.**

Start with an application, its routes, and a controller:

```swift
import Roost

@main
struct Hello: RoostApp {
    @RouteBuilder var routes: [Route] {
        GET("/", PageController.self, .home)
        GET("/hello/:name", PageController.self, .hello)
    }
}

struct PageController: Controller {
    enum Action: String, ControllerAction { case home, hello }

    static func action(_ action: Action) -> Plug {
        switch action {
        case .home: home
        case .hello: hello
        }
    }

    static func home(_ conn: Connection) async throws -> Connection {
        conn.text("Hello, Roost.")
    }

    static func hello(_ conn: Connection) async throws -> Connection {
        try conn.json(value: ["hello": conn.params["name"] ?? "world"])
    }
}
```

**Roost 2.4.0** adds the database and route commands behind `roost db` and
`roost routes`, on top of 2.3's live pages, reusable form fields, typed writes,
migration registries, and key-value stores. Routes name controller actions the compiler
checks; `resources` builds REST routes and controller plugs run before chosen
actions. `conn.permit` decodes only declared fields. Requests are logged and traced
by action with secrets filtered. It uses
published Nexus 2.x (from 2.1.0), Spectro 2.x (from 2.3.1), and ESW 1.7.0. Moving from
Peregrine? Follow the [upgrade guide](guides/renaming-to-roost.md).
[See what is implemented and what remains.](Sources/Roost/Roost.docc/ProjectStatus.md)

<details>
<summary>Contents</summary>

- [What you get](#what-you-get)
- [Try it in the browser](#try-it-in-the-browser)
- [Documentation](#documentation)
- [Quickstart](#quickstart)
- [The stack](#the-stack)
- [Application structure](#application-structure)
- [Configuration](#configuration)
- [CLI reference](#cli-reference)
- [Testing](#testing)
- [Deployment](#deployment)
- [Troubleshooting](#troubleshooting)
- [Current boundaries](#current-boundaries)
- [Contributing](#contributing)

</details>

## What you get

- **Swift throughout.** An application protocol, a route builder, composable
  middleware, typed models, and HTML templates compiled by SwiftPM.
- **Controllers with checked routes.** Routes name controller actions, and the
  compiler rejects a route to an undeclared action or an action without a
  function. `resources` routes REST actions with `only:` and `except:`, and
  controller plugs run before the actions you choose.
- **Permitted parameters and typed changes.** `conn.permit(RecipeParams.self)`
  decodes form, query, path, or JSON parameters into a type, and
  `conn.permit(Recipe.editable)` decodes a model's permitted fields into
  `Changes` named by key path. Undeclared fields can't be mass-assigned, and
  invalid values become 422 responses.
- **Logs and traces per action.** One log line per request names the action,
  route, and parameters, with passwords and tokens filtered. Tracing spans are
  named after routes, with a child span per action.
- **Connected generators.** Create models, contexts, migrations, controllers, views,
  and input tests together. Routes are registered in your app, existing files
  are protected, and migration filenames preserve dependency order.
- **A browser workflow.** Form decoding, method overrides, CSRF protection,
  server-side sessions, one-time flash messages, and 422 validation responses
  that retain submitted values.
- **Authentication and ownership.** Generate registration, login, and logout
  with salted password hashing and revocable session tokens. Scoped resources
  check the authenticated owner on reads, updates, and deletes, and a
  `ScopedRepo` applies that check to every query and write of a context.
- **Key-value stores.** `conn.store` keeps typed values, counters, caches, and
  sessions in memory during development, and on Valkey in production once
  `ROOST_STORE_URL` is set. Tests get a fresh memory store each.
- **Tests close to the application.** Run the application pipeline in-process,
  keep cookies across requests, submit forms, and inject a transaction-owned
  repository for database isolation.

## Try it in the browser

[Open the Roost Playground →](https://roost-framework.github.io/swift-roost/playground.html)

Start with Counter, Greeting, or Toggle. Jump to a supported value, edit the
Swift source, and run the example. The previous preview stays available if an
edit falls outside the lesson.

This is a **browser-only guided preview**: JavaScript simulates the examples;
the page does not compile Swift or upload your code. Copy or download a sample
to keep exploring.

The separate local Roost Playground uses the real Swift compiler and ESW Live.
It supports a one-file app, rebuilds on save, and keeps the working app available
when compilation fails. That companion project still requires development
checkouts and has not been published as a standalone release.

## Documentation

Roost includes native DocC guides and API references for **Roost** and
**RoostTest**, with the same searchable navigator used by ESW's documentation.
Browse the [documentation for the latest release](https://roost-framework.github.io/swift-roost/docs/latest/)
or [pick a release](https://roost-framework.github.io/swift-roost/docs/). In this checkout, start with [Getting started](Sources/Roost/Roost.docc/GettingStarted.md), then
follow the guides for controllers, routes, views and forms, authentication, Spectro migrations,
testing, and deployment.

See [building and browsing the documentation](Documentation/README.md) to generate
the complete reference locally or prepare it for static hosting.

## Quickstart

The [Roost reading-list example](examples/Roost) is a complete app with
authentication, ESW pages, a JSON API, and database-backed tests. With this
checkout and PostgreSQL configured, start it with:

```sh
cd examples/Roost
./dev
```

Its README walks through the generated code and the application-specific additions.

### 1. Install the CLI

You need Swift **6.3 or later**, macOS 14+ or Linux, and PostgreSQL with its client
tools for the database-backed example. On Debian/Ubuntu, install `zlib1g-dev` for
Nexus. No Node.js toolchain is needed for the default Pico CSS setup.

Install the CLI with [Mint](https://github.com/yonaskolb/Mint):

```sh
brew install mint
mint install roost-framework/roost-cli@3.0.0
roost --version
```

Mint builds the CLI from source and links `roost` into `~/.mint/bin`; add that
directory to your `PATH`. The CLI lives in its own small
[roost-cli](https://github.com/roost-framework/roost-cli) package, so it does
not resolve the framework's dependencies.

Without Mint, for example on Linux, build from a checkout:

```sh
git clone --branch 3.0.0 --depth 1 https://github.com/roost-framework/roost-cli.git
cd roost-cli
swift build -c release --product roost
```

Then copy `.build/release/roost` to a directory on your `PATH`.

Generated apps download Roost 2.4.0, Spectro 2.x (from 2.3.1), Nexus 2.x (from 2.1.0),
and ESW 1.7.0 through SwiftPM. No companion source checkouts or dependency overrides are needed.
Roost turns off Nexus's default `Vapor` trait, so SwiftPM skips Vapor and its dependencies.
Existing apps retain their resolved versions until you run `swift package update`.

From Roost 2.3, the `Valkey` trait lets the app's key-value store and sessions
live on a Valkey or Redis server: add `"Valkey"` to the traits and set
`ROOST_STORE_URL=valkey://…`. Without it, SwiftPM doesn't download the Valkey
client. See the Key-value stores guide (`Sources/Roost/Roost.docc/KeyValueStores.md`).

Framework contributors can optionally set `ROOST_FRAMEWORK_PATH` to a checkout.
`ROOST_ECOSYSTEM_PATH` selects the parent of all four repositories; `ROOST_ESW_PATH`
overrides ESW alone. Leave these unset when installing or trying the published release.

### 2. Start with one route

For a first app that needs no database or templates:

```sh
roost new HelloApp --no-db --no-esw
cd HelloApp
roost server --port 8080
```

Open [localhost:8080](http://localhost:8080). Edit
`Sources/HelloApp/Controllers/PageController.swift` and save to rebuild. The generated test is ready
to run with `swift test`. Stop the server with Ctrl-C.

### 3. Generate an authenticated app

For an app with data, generate a separate project. From `HelloApp/`:

```sh
cd ..
roost new TodoApp
cd TodoApp

roost gen auth
roost gen resource Todo title:string done:bool --both --scope user_id
```

This creates HTML pages and a JSON API backed by one context. Ownership comes
from the authenticated user; clients cannot choose another user's `user_id`.

### 4. Configure PostgreSQL and run

The following example uses a local PostgreSQL role matching your macOS username,
as with a typical Postgres.app installation. Set `DB_USER` and `DB_PASSWORD` to
your own local credentials if they differ.

```sh
export DB_USER="$USER"
export DB_PASSWORD=""
export DB_HOST=localhost
export DB_PORT=5432

roost db setup
ROOST_ENV=test roost db setup
swift test
roost server --port 8080
```

Open [localhost:8080/auth/register](http://localhost:8080/auth/register), create an
account, then visit `/todos`. The JSON API lives at `/api/todos`. Mutating
cookie-authenticated JSON requests also require an `X-CSRF-Token` header.

The development server watches Swift and template files. After a successful
rebuild it restarts the app; a compiler error leaves the previous server running.

The [full tutorial](guides/tutorial-todo-app.md) covers a second resource, contexts,
browser tests, and migrations in more detail.

Migration commands use **Spectro's migration manager**, through Roost's application
configuration. SQL files live in `Sources/Migrations/`, with `-- migrate:up`
and `-- migrate:down` sections. Spectro applies them transactionally and records
their versions in `schema_migrations`. An app can also declare a
`MigrationRegistry` that adds Swift migrations to that SQL history; the
reading-list example does.

## The stack

| Layer                                             | Responsibility                                                                             |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| [Nexus](https://github.com/roost-framework/Nexus)     | Connections, routing, middleware, and the Hummingbird HTTP adapter.                        |
| [Spectro](https://github.com/roost-framework/Spectro) | Typed PostgreSQL models, queries, repositories, transactions, and migrations.              |
| [ESW](https://github.com/roost-framework/ESW)         | HTML templates compiled into Swift render functions.                                       |
| Roost                                             | Application lifecycle, conventions, generators, browser integration, and the test harness. |

An HTTP request passes through service injection, session loading, application
middleware, and routing. The controller action calls a context through `conn.repo()`.
Session persistence is awaited before response hooks run. `TestApp` uses the same
pipeline and finalization path as the server.

## Application structure

The generated Todo app keeps domain operations separate from transport and views:

```text
TodoApp/
├── Package.swift
├── Sources/
│   ├── TodoApp/
│   │   ├── App.swift             # Configuration, middleware, and routes
│   │   ├── Models/              # Spectro schemas
│   │   ├── Contexts/            # Repository-backed domain operations
│   │   ├── Controllers/         # HTML and JSON actions
│   │   ├── Routes/              # Route tables split out of App.swift
│   │   ├── Plugs/               # Application middleware
│   │   └── Views/               # ESW layouts and resource templates
│   └── Migrations/              # Ordered SQL migrations
├── Public/                      # CSS and other static assets
└── Tests/TodoAppTests/
```

Contexts accept `any Repo`. Controller actions use the application's repository;
tests can inject a transaction repository. Generated HTML and JSON controllers
permit the same input type, and validation runs in the context too.

## Views and forms

The HTML and auth generators create ordinary Swift view files beside headerless
ESW templates. Edit the view's typed data and presentation helpers; ESWBuildPlugin
generates rendering methods without overwriting your code.

```swift
// Views/auth/RegisterView.swift
import Roost

@ESWTemplate("register.esw")
struct RegisterView {
    var email: String = ""
    var error: String? = nil
}

// In a route:
// return try conn.render(RegisterView(), title: "Register")
```

```html
<.form action="/auth/register" method="post">
    <input type="email" name="email" value="<%= email %>">
    <button type="submit">Create account</button>
</.form>
```

`conn.render` supplies a request-scoped form context and applies `RoostApp.layout`.
New projects include a `LayoutView` and configure this property once. For an
existing app, configure the layout explicitly when adopting typed page views:

```swift
var layout: HTMLLayout? {
    { conn, title, content in
        LayoutView(conn: conn, title: title, content: content).render()
    }
}
```

A legacy layout can call `renderLayout(conn:title:content:)` from the same closure.
`title` defaults to an empty string, and `status` defaults to `.ok`; pass
`status: .unprocessableContent` when displaying validation errors. Without a layout,
`conn.render` returns the view's HTML alone.

The standard form component uses the browser middleware's session token. Page
structs and route calls need no `csrfToken` property. Same-origin POST/PUT/PATCH/
DELETE forms get a hidden CSRF field; GET and external forms do not. PUT/PATCH/
DELETE use POST with `_method`. Token validation remains in `browserPlugs()`.
Set a `sessionStore` on the app and use `browserPlugs()`, as new projects do.
A missing token/context or invalid form configuration makes `conn.render` throw;
the normal error handler returns an error response. Calling a form directly outside
this boundary emits an inert diagnostic comment instead of an unprotected form.
Plain `<form>` elements remain literal HTML and do not receive these features.

For dynamic actions use Swift expressions, such as
`<.form action={"/items/\(item.id)"} method="delete">`. Attributes are declared in
Swift parameter order: `action`, `method`, `id`, `class`, `multipart`, `attributes`.
Additional attributes can use `attributes={["novalidate": "", "data-kind": "editor"]}`.
Values are escaped; reserved structural attributes cannot be overridden by that map.
ESW stays independent of HTTP; request context and this component belong to Roost.

## Live pages

`LivePage` receives the current Roost connection in its mount and event handlers,
so interactive pages reuse the same authenticated scopes and contexts as controllers.
`LiveRoute` connects ESWLive's initial HTML, SSE updates, and POST events, and
runs with the application's services to close streams during shutdown.

The reading-list example updates rows and counts without navigation, retains
native form submissions without JavaScript, and exercises offline recovery,
lost replies, ownership, and logout in its browser suite. The integration uses
ESW 1.7.0; live state remains process-local.
See [Live pages](Sources/Roost/Roost.docc/LivePages.md) and the
[example's instructions](examples/Roost/README.md#live-page-and-browser-regression-tests).

## Configuration

Configuration is expressed in Swift through `RoostApp`. The generated app
also reads these environment variables; export them in your shell or set them in
your process/container environment. `.env` files are not loaded automatically.

| Variable               | Default / behavior                                                                                                                                |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ROOST_ENV`            | `dev`; accepts `dev`, `test`, or `prod`.                                                                                                          |
| `ROOST_HOST`           | `127.0.0.1`; generated containers use `0.0.0.0`.                                                                                                  |
| `ROOST_PORT`           | `8080`.                                                                                                                                           |
| `DB_HOST`              | `localhost`.                                                                                                                                      |
| `DB_PORT`              | `5432`.                                                                                                                                           |
| `DB_USER`              | `postgres`; set it to your PostgreSQL role.                                                                                                       |
| `DB_PASSWORD`          | `postgres`; override for your environment.                                                                                                        |
| `DB_NAME`              | Overrides the database name. Otherwise a configured base gets `_dev` or `_test`; production uses the base name. Set it explicitly for deployment. |
| `ROOST_ECOSYSTEM_PATH` | Optional parent directory of the companion source checkouts, used during SwiftPM resolution.                                                      |
| `ROOST_FRAMEWORK_PATH` | Optional framework checkout; otherwise uses `$ROOST_ECOSYSTEM_PATH/Roost` if set, or the published package.                                                   |
| `ROOST_ESW_PATH`       | Optional ESW checkout path; overrides ESW alone and takes precedence over ecosystem mode.                                                         |

The generated `MemorySessionStore` lasts for one process. Provide a shared,
persistent `SessionStore` for sessions that must survive restarts or work across
multiple app instances. Read the [session guide](guides/server-side-sessions.md)
for lifecycle and storage semantics.

## CLI reference

Run `roost <command> --help` for options.

| Command                                                       | Purpose                                                                         |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `roost new MyApp`                                             | Create an app with PostgreSQL configuration, ESW, and Pico CSS.                 |
| `roost gen auth`                                              | Add and register browser authentication.                                        |
| `roost gen resource Post title:string body:text`              | Generate a complete HTML resource.                                              |
| `roost gen resource Post title:string --json`                 | Generate a JSON resource.                                                       |
| `roost gen resource Post title:string --both --scope user_id` | Generate authenticated HTML and JSON controllers with ownership checks.         |
| `roost gen resource Post title:string --model-only`           | Generate model, context, migration, and input tests.                            |
| `roost gen live Post title:string`                            | Generate an HTML resource whose index is a live page, like `mix phx.gen.live`.  |
| `roost gen migration add_post_index`                          | Create an empty SQL migration.                                                  |
| `roost migrate up\|down\|status`                              | Apply, roll back, or inspect migrations using the app's database configuration. |
| `roost migrate down --step 2`                                 | Roll back the two newest migrations; `--all` rolls back every one.              |
| `roost db setup`                                              | Create the database, migrate it, and run `Seeds/<env>.sql` when it exists.      |
| `roost db create\|drop\|seed\|reset`                          | Create, drop, or seed the database; `reset` drops it and runs `setup`.          |
| `roost routes`                                                | List every route's method and path in matching order.                          |
| `roost server --port 8080`                                    | Build, serve, and watch for changes.                                            |
| `roost build`                                                 | Build the app and configured CSS assets.                                        |
| `roost gen dockerfile`                                        | Generate a multi-stage Linux Dockerfile.                                        |

## Testing

Run the framework tests from the Roost checkout:

```sh
swift test
```

Generated app tests use Swift Testing and `RoostTest`:

```swift
import Testing
import RoostTest
@testable import TodoApp

@Test func homeResponds() async throws {
    let app = try await TestApp(TodoApp.self, database: .some(nil))
    let response = try await app.get("/")
    #expect(response.status == .ok)
    #expect(response.json["message"] as? String == "Welcome to TodoApp")
}
```

`app.browser()` adds a cookie jar and form submission helpers. For database
isolation, `withTestRollback` supplies a repository to inject into the app and
its contexts. Workflows that start their own transactions, such as registration,
need an independently owned test database because nested transactions are not
supported.

The executable acceptance check in [roost-cli](https://github.com/roost-framework/roost-cli) generates an app, migrates an isolated database,
runs its tests, and exercises authentication, HTML, JSON, and two-user ownership
over HTTP:

```sh
# From a roost-cli checkout beside this one, with a local PostgreSQL server running:
unset ROOST_ECOSYSTEM_PATH ROOST_ESW_PATH
python3 scripts/check_generated_app.py --framework ../swift-roost

# Also test an optimized executable from its release directory:
python3 scripts/check_generated_app.py --framework ../swift-roost --release
```

The script creates and removes its own database, retaining diagnostic logs in
the printed workspace. CI checks published dependencies separately from the
generated-app integration.

## Deployment

The compiled application includes its migration command. Build an optimized
executable, configure the target database, and run migrations explicitly:

```sh
swift build -c release
export ROOST_ENV=prod
export DB_NAME=todo_app
# Set DB_HOST, DB_PORT, DB_USER, and DB_PASSWORD for the target database.

.build/release/TodoApp migrate up
.build/release/TodoApp
```

Run from the application directory, or package the executable alongside `Public/`
and `Sources/Migrations/`. An app with a migration registry reads its SQL from
its resource bundle instead: ship the `<Package>_<Target>.resources` directory
(`.bundle` on macOS) from `.build/release` with the executable. Starting the
server does not apply migrations.

`roost gen dockerfile` generates a Swift 6.3.3 build stage and matching slim
runtime, installs zlib, and includes public assets and the SQL files in
`Sources/Migrations/`, but not yet the resource bundle a migration registry
needs. Supply the
`DB_*` variables to the container. Generated Dockerfiles resolve published
dependencies, including Roost 2.4.0; no framework source checkout is required
in the container build context.

## Troubleshooting

- **The compiler cannot find `Roost`.** Require `swift-roost` 2.0.0 or later
  and use the `Roost` product. The 1.x tags contain the earlier Peregrine names.
  Unset stale dependency overrides and run `swift package resolve`.
- **Templates collide or typed views are missing.** Require ESW 1.7.0 or later
  in the app's direct dependency, and run `swift package resolve`. Remove an
  outdated `ROOST_ESW_PATH` or `ROOST_ECOSYSTEM_PATH` override. File templates
  also need `ESWBuildPlugin` on the application target.
- **PostgreSQL refuses the connection.** Confirm the server is running and
  that the exported `DB_*` values match your local role and database.
  Run migrations for both development and test databases.
- **An app called `Roost` is rejected.** That name belongs to the framework
  module. Choose `ReadingRoom`, `TodoApp`, or `RoostExample`.
- **The browser still shows the previous code.** Check the development
  server's build output. Compilation must succeed before the server restarts;
  refresh the browser afterward.

## Current boundaries

The main verified path is a PostgreSQL-backed application with authenticated
HTML and JSON resources. Additional APIs exist for SSE, channels, jobs, mail,
and PubSub, with different levels of implementation:

- PubSub and jobs have in-memory implementations. The Valkey adapter and
  PostgreSQL job queue are unfinished.
- Roost's channel upgrade route and SMTP delivery are stubs.
- TLS and HTTP/2 configuration types exist, but Roost's bootstrap does not
  wire them into the running server.

The framework is now **Roost.** Existing apps should follow the
[rename guide](guides/renaming-to-roost.md) for imports, environment variables,
and session changes.

## Contributing

Keep changes grounded in a runnable workflow. For framework or generator changes,
run `swift test` and the generated-app acceptance check. Include the relevant
companion repository revisions when reporting integration results.

Start with the [Todo tutorial](guides/tutorial-todo-app.md) or
[session lifecycle](guides/server-side-sessions.md). The [specs](specs/README.md)
describe design work; check the implementation and tests for current behavior.

The [Roost mark](assets/brand/README.md) is included in `assets/brand/`.

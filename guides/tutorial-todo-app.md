# Build an authenticated Todo app

This tutorial is exercised by roost-cli's `scripts/check_generated_app.py`. The acceptance
run creates an app with two resources, applies its migrations to an isolated
PostgreSQL database, runs its generated tests, and checks two users over HTTP.

Use Swift 6.3 or later, PostgreSQL, and the `roost` CLI. ESW 1.6.0 includes the
typed views and namespaced templates used below; Spectro 2.x (from 2.0.0) includes the
required database fixes. No companion source checkouts are needed.

Roost requires Spectro 2.x (from 2.0.0) and Nexus 2.0.0. On Debian/Ubuntu, install `zlib1g-dev` before
building. The generated Dockerfile installs the build headers and runtime zlib
package, and CI installs the headers too.

## Install the CLI

Install the Roost CLI with [Mint](https://github.com/yonaskolb/Mint) and add
`~/.mint/bin` to your `PATH`:

```sh
brew install mint
mint install roost-framework/roost-cli@2.2.0
```

Without Mint, build from a checkout as described in the
[README](../README.md#1-install-the-cli).

The generated application resolves Roost and its companions from their releases.
Framework contributors can opt into local sources with `ROOST_FRAMEWORK_PATH`,
`ROOST_ECOSYSTEM_PATH`, or `ROOST_ESW_PATH`.

## Generate and start

```sh
roost new TodoApp
cd TodoApp
roost gen auth
roost gen resource Todo title:string done:bool --both --scope user_id
roost gen resource Note body:text
```

The generators register their routes and middleware in `App.swift`:

```swift
@RouteBuilder var routes: [Route] {
    scope("/auth") { authRoutes() }
    resources("/todos", TodoController.self)
    scope("/api") { resources("/todos", TodoAPIController.self) }
    resources("/notes", NoteController.self)
    // roost:routes
    GET("/", PageController.self, .home)
}
```

Each route names a controller action in `Controllers/`. `authRoutes()` lives in
`Routes/AuthRoutes.swift`, routing to `RegistrationController` and
`SessionController`. The generators refuse to overwrite existing files.
`--scope user_id` takes ownership from the identity loaded by authentication
middleware: `TodoController` runs `requireAuth()` before every action and passes
the signed-in user's ID to the context. Actions decode input with
`conn.permit(CreateTodoInput.self)`, so submitted `user_id` values are ignored.
For other scope types, generate `--model-only` and write the scope resolution for
your domain explicitly.

Create the databases. `roost` runs the app's PostgreSQL in a container,
`roost-todoapp-db`, with Apple's `container` or Docker, and prints its port the
first time a command needs it: `[roost] Postgres: 127.0.0.1:<port>`.

```sh
roost spectro database create todo_app_dev
roost spectro database create todo_app_test
roost migrate
ROOST_ENV=test roost migrate
DB_HOST=127.0.0.1 DB_PORT=<port> swift test
roost server
```

To use a PostgreSQL server you run yourself, export `DB_HOST`, `DB_PORT`,
`DB_USER`, and `DB_PASSWORD` first; `roost` then starts no container.

Visit `/auth/register`, then `/todos`. Register a second user in another browser
profile. Each user should see and modify only their own Todos. `/notes` is the
second, unscoped resource. The shared layout displays one-time flash messages.

The standard browser pipeline parses forms, applies `_method` overrides, loads
flash and checks CSRF. Unchecked Boolean inputs become `false`. Failed validation
returns HTTP 422 with the submitted values and field errors. Cookie-authenticated
JSON routes require an `X-CSRF-Token` header, including `/api/todos`. A bearer-only
API can use a separate pipeline; JSON content type alone does not disable CSRF.

## Where to put application logic

`TodosContext` accepts `any Repo`, so the same operations work from controller
actions, a script, or a transaction-owned test repository:

```swift
let todos = TodosContext(repo: conn.repo())
let records = try await todos.listTodos(scopeId: user.id)
let updated = try await todos.updateTodo(
    id: id,
    with: CreateTodoInput(title: "Ship the app", done: true),
    scopeId: user.id
)
```

The generated ownership column cannot be changed through these operations.
Every read, update and delete checks ownership; missing and foreign-owned IDs
return 404. Input types are declared once in the context and permitted by both
the HTML and JSON controllers. Changeset validation also runs when a caller uses
the context directly.

The server logs one line per request with the action that handled it, such as
`POST /todos → TodoController.create → 303 in 4.2ms`. Its parameters are
attached as metadata, with `password` and `_csrf_token` shown as `[FILTERED]`.

`AccountsContext` uses Roost's salted password hashing. Registration creates
both user and token in one transaction. Only a hash of the login token is kept
in `user_tokens`; the browser session keeps the original token. Authentication
uses a filtered lookup and enforces the token lifetime. Logout revokes the token
and rotates the browser's session ID.

The generated `MemorySessionStore` is for a single running process. Configure a
shared persistent `SessionStore` when deploying multiple instances or when login
sessions must survive restarts.

## Test a request with rollback

Use `TestApp` for the same middleware and request finalizer as the server.
`app.browser()` creates a cookie jar; create two to test user isolation. Form
posts use `browser.post(path, form: values)` and redirects are returned so tests
can assert them before following them.

For database tests, inject the transaction repository into both the context and
`TestApp`:

```swift
try await withTestRollback(repository: client.repository()) { transaction in
    let app = try await TestApp(TodoApp.self, repository: transaction)
    let context = TodosContext(repo: transaction)
    // Create fixtures, make requests, and assert persisted behavior here.
}
```

`withTestRollback` rolls the test's transaction back even on success and propagates
unexpected failures. Spectro does not support nested transactions: test workflows
that open their own transactions, such as registration, in a separately owned
test database. `TestApp` uses a task-local `.test` environment. If it creates its
own database client, close it with `await app.shutdown()`; injected repositories
remain owned by their caller.

## Migrations and release

`roost migrate up|down|status` executes the app's migration entry point. The
server and migrations therefore use the same `Database` configuration, including
`DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, and `DB_NAME`. Migrations are explicit;
starting the server does not migrate a database automatically.

```sh
roost gen dockerfile
# After building a release, the compiled executable also supports:
.build/release/TodoApp migrate status
```

The Dockerfile uses matching Swift 6.3.3 build and runtime images, includes public
assets and migrations, and sets the runtime working directory. See the official
[Swift container images](https://hub.docker.com/_/swift/) for the image variants.

Run the executable acceptance workflow from a roost-cli checkout beside the
framework checkout:

```sh
unset ROOST_ECOSYSTEM_PATH ROOST_ESW_PATH
python3 scripts/check_generated_app.py --framework ../swift-roost
# Also build and exercise an optimized executable:
python3 scripts/check_generated_app.py --framework ../swift-roost --release
```

It uses a unique local database and drops it on success or failure. The printed
workspace retains generated sources and diagnostic logs. With `--release`, it
serves from a separate directory containing only the executable, public assets
and migrations, with `ROOST_ENV=prod`. CI runs the workflow
on Linux and separately tests Roost against published dependencies on macOS
and Linux. CI accepts explicit ecosystem revisions for release coordination.

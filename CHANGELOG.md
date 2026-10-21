# Changelog

## Unreleased

- `ServerConfig(tls:)` serves HTTPS from a PEM certificate chain and key, and
  negotiates HTTP/2 with clients that support it, falling back to HTTP/1.1.
  `tls`, `http2`, `TLSConfig`, and `validate()` are no longer deprecated.
- A missing certificate or key file, or HTTP/2 without TLS, stops the app at
  startup with `ServerConfigError`, before it opens the database.
  `ServerConfig(host:port:http2:)` stays deprecated: HTTP/2 needs TLS.
- Live pages update from the server, like a LiveView's `handle_info`. A `LivePage`
  names its `topics`, and `handleInfo(_:state:conn:)` turns a typed `Info` message
  into new state, with the request of the page's open stream.
  `LiveRoute.broadcast(_:to:)` sends a message to the open pages of a topic in this
  process, skipping the page whose handler broadcasts. Existing pages compile
  unchanged.
- The bookmarks example broadcasts after every write, so a reader's other tabs
  update without reloading.
- `ValkeyPubSub` delivers PubSub messages between servers through a Valkey or
  Redis server, with the `Valkey` trait. Return it from `RoostApp.pubSub`, which
  now runs an adapter that conforms to `Service` with the server. Payloads
  travel as JSON. Without the trait, `ValkeyPubSub` and `PubSub.valkey(url:)` are
  no longer deprecated stubs that stop the process: the app stops at startup
  with an error instead.
- `LiveRoute(_:pubSub:)` sends broadcasts through a PubSub, so they update the
  pages open on every server. The page's `Info` must be `Codable`.
- Roost requires macOS 15 or later on macOS, as swift-jobs does. Linux is
  unaffected.

### Upgrade

On macOS, raise the app's platform to `.macOS(.v15)` in `Package.swift`.
SwiftPM rejects a package that supports an older macOS than one of its
dependencies.

## 2.4.0 — 2026-10-21

The app commands that roost-cli 3.0's `roost db` and `roost routes` run, and SQL
rollbacks of more than one migration. Apps no longer build Spectro's CLI.

- `App db create|drop|seed|setup|reset` manages the database with the server's
  configuration, like `mix ecto.create` and friends. `setup` creates the
  database, runs pending migrations, and runs `Seeds/<env>.sql` when it exists;
  `reset` drops the database first. `drop` and `reset` refuse `ROOST_ENV=prod`.
  The `roost db` command in roost-cli runs them.
- `App routes` lists each route's method and path in matching order, like
  `mix phx.routes`. The `roost routes` command in roost-cli runs it.
- `App migrate down` takes `--step N` and `--all` for SQL migrations too, as it
  already did for a migration registry. A usage error prints the usage and
  exits with status 64, and a database error prints PostgreSQL's message and
  exits with status 1, instead of crashing with "Error raised at top level".
- Roost no longer enables Spectro's `CLI` trait, so apps don't build the
  `spectro` executable or fetch Noora. roost-cli no longer runs it: `roost db`
  and `roost migrate` use the app's own configuration. The `RichTerminal` trait
  has no effect and stays declared, so apps that enable it still resolve.

## 2.3.0 — 2026-10-19

Live pages and reusable form fields join typed data operations, migration registries,
and key-value stores in this release. This includes all changes since 2.1.3.

- `Input` and `Textarea` render escaped values, constraints, labels, hints, and field
  errors from `FormFieldRepresentable`; `FormValues["name"]` supplies ordinary form
  fields. Sensitive values stay empty and controls have accessible error references.
- `LivePage` supplies the current request to mount and event handlers. `LiveRoute`
  serves initial HTML, SSE updates, local JavaScript, and CSRF-protected events,
  binding each instance to its session and authentication identity.
- `RoostApp.services` registers services that shut down before HTTP connections drain.
  Register live routes here and invalidate their instances before login/logout changes
  identity. Live state is process-local and expires; it is not shared by Valkey.
- The bookmarks example updates rows and counts without navigation, with native
  forms as a fallback. Browser regression tests cover offline recovery, lost replies,
  focus, ownership, CSRF, logout, and graceful shutdown.
- ESW's minimum version is now 1.7.0. Swift 6.3+, macOS 14+ or Linux remain supported;
  the optional Valkey backend requires macOS 15+.
- CSS changes refresh stylesheets during development without reloading the page.

### Key-value stores

Apps have a key-value store, `conn.store`, kept in memory during development
and on Valkey in production. One environment variable chooses between them.

- `conn.store` reads and writes typed values through `StoreKey`s, each with
  its own expiry: `get`, `set`, `remove`, `fetch` for caching, and an atomic
  `increment` for counters.
- `RoostApp.store` defaults to `.environment`. `ROOST_STORE_URL=valkey://…`
  selects a Valkey or Redis server; without it the store is in memory, and in
  production it logs a warning the first time it's used. `.memory`,
  `.valkey(url:)`, `.persist(_:)` for a Hummingbird `PersistDriver`, and
  `.custom(_:)` choose in code. Keys are prefixed with the app and
  environment, such as `ReadingRoom:prod:`; `.namespaced(_:)` changes that.
- The `Valkey` trait adds valkey-swift, the only new package an app
  downloads; without the trait, nothing is fetched. Roost connects when the
  server starts and closes the connections after it stops accepting requests.
  While Valkey is unreachable or stops answering, requests that use the store
  fail within a few seconds, then at once, and recover when it's back. Redis
  works from 6.2.
  Error messages hide the URL's credentials, also in a URL that can't be
  parsed.
- `conn.store` throws for a connection that has no store, such as one a
  plug's unit test builds, instead of stopping the process.
- `KeyValueSessionStore()` keeps sessions in the store, whether it's the
  app's `sessionStore` or installed with `session(store:cookieName:ttl:)`.
  Its values must be strings, numbers, booleans, or arrays and dictionaries of
  those. Each session is stored under a hash of its ID, the cookie's value, so
  listing the store's keys doesn't reveal sessions to sign in with.
- `MemoryKeyValueStore` encodes, expires, and increments values the way Valkey
  does. `TestApp` gives each test app a fresh one, readable as `app.store`,
  or takes one with `store:`.
- `rateLimit(max:windowSeconds:)` counts requests in `conn.store`, so with
  Valkey a limit applies to the whole app instead of each instance. Its
  window slides, instead of starting at each client's first request, so a
  client can't send twice the limit around the end of a window. If the store
  fails, requests are allowed and the error is logged at most once a minute;
  a store without atomic counters falls back to each process's memory, and
  isn't asked again. Counters are named by a hash of the client, so an API key
  read with `by: .header(_:)` isn't stored in the clear.
- The JSON body of a 429 escapes the message, so a message with quotes is
  valid JSON.
- `rateLimit(by: .ip)` uses the socket address when a request has neither
  `X-Forwarded-For` nor `X-Real-IP`. Before, such requests weren't limited.

### Upgrade: key-value stores

Nothing changes until an app uses `conn.store` or `KeyValueSessionStore`;
without `ROOST_STORE_URL`, rate limits count in each process's memory, as
before, and don't log the production memory warning. To
keep sessions across restarts and servers, enable the `Valkey` trait, set
`ROOST_STORE_URL`, and replace `MemorySessionStore()` with
`KeyValueSessionStore()`. On macOS, the Valkey client needs macOS 15 or later.

Rate limits change in two ways:

- Limits created at the same place in the code with the same `max` and
  window share counters, such as two limits made by one helper function for
  different routes. Before, each plug counted on its own. Pass `name:` to keep
  them apart.
- An app that receives requests directly, without a proxy, is now limited
  by each client's socket address.

### Typed data, migrations, and request errors

Your own errors can choose their response, and code outside a controller can
read request bodies the way `conn.permit` does. Invalid input is a 422 wherever
it's thrown, a unique violation is recognized inside a transaction too, and
tests can sign a browser in without Roost's session keys.

- An error that conforms to `HTTPErrorConvertible` gives the `NexusHTTPError`
  to respond with, and Roost responds as if the handler had thrown that: with
  its status, and its message in development. A domain error such as "sold out"
  becomes a 409 instead of a 500, without a `catch` in every handler.

  ```swift
  enum OrderError: HTTPErrorConvertible {
      case soldOut

      var httpError: NexusHTTPError {
          NexusHTTPError(.conflict, message: "This item is sold out")
      }
  }
  ```

- `conn.isJSONRequest` is public. It's `true` for a content type of
  `application/json` or a `+json` type such as `application/vnd.api+json`, the
  check `conn.permit` makes to choose between the body and the form fields.
- `ValidationErrors(decodingError)` is public. It turns a `DecodingError` into
  the field error `conn.permit` reports, such as `title: can't be blank`, and
  throws a 400 when the error isn't about a field, such as a body that isn't
  JSON.
- An uncaught `ValidationErrors` responds 422, not 500. A request that sends or
  asks for JSON gets the field errors as its body, the same body
  `conn.json(status: .unprocessableContent, value: errors)` writes. Any other
  request gets the error page, with 422, which lists the errors in development.
  A handler only needs a `catch` to re-render its form.
- `isUniqueConstraintViolation` recognizes PostgresNIO's `PostgresError`, which
  Spectro's queries throw inside a transaction, also when it's wrapped in
  Spectro's `queryExecutionFailed` and `transactionFailed`. It used to recognize
  only `PSQLError`, so a registration racing another one with the same email
  was a 500 instead of "Email is already taken".
- RoostTest signs requests in with a session token:
  - `browser.signIn(token:)`, or `browser.signIn(user, token:)`, stores the
    token in the browser's session with its next request, as
    `conn.loginUser(user, token:)` does, and keeps it for every later one;
  - `TestSession.signedIn(token:)` is the session for a single request:
    `app.get("/bookmarks", session: TestSession.signedIn(token: token))`.

  Tests no longer need Roost's private `_roost_auth_token` key.

Contexts write typed changes and stay inside their owner's records. A model
field is declared in its schema and in one permitted list, instead of in an
input type, its normalization, an insert, and an update dictionary.

- `Changes<Model>` holds the values to write to a model, each named by a key
  path, so the compiler checks the property and the value's type.
  `repo.update(_:id:_:)` writes them. Writes through `Changes` set an
  `updatedAt` timestamp unless the changes set it; empty changes write nothing.
- `Permitted<Model>(\.title, \.url)` lists the fields a request may set.
  `conn.permit(_:)` decodes them from forms and JSON into `Changes` and reports
  every invalid field, not just the first. `FormValues.decode(_:)` does the
  same outside a request. A JSON body may use the snake_case names `@Schema`
  encodes, such as `read_at`, and an optional field it leaves out stays
  unchanged, so a partial update doesn't clear it.
- `ValidatorRule` has key path rules for `Changes`, such as `.required(\.title)`
  and `.length(\.note, max: 2000)`. They name each field after the schema
  property instead of a repeated string.
- `repo.scoped(\Bookmark.userId, to: owner)` returns a `ScopedRepo`, which
  limits `query()`, `get`, `insert`, `update`, and `delete` to one owner's
  records. Updates and deletes are single statements that match the primary key
  and the owner, so a context doesn't read a record before changing it, and
  they work inside `withTestRollback`. Another owner's record is a 404.
- `AuthScope` has a `ScopeID` associated type, so `scopeId` can be a `UUID`.
  Swift infers it from `scopeId`; existing `String` scopes are unchanged.
- `conn.requireScope(_:)` returns the current scope or throws a 401.
  `conn.authContext` reports whether the user signed in with a session or a
  bearer token.
- Roost stores authentication and the scope under typed assign keys. The
  `AuthAssign` string keys still reach the same values, and as in 2.1, any
  value under `AuthAssign.currentUserID` authenticates the request.
- The example app uses all of the above. `BookmarksContext` holds a
  `ScopedRepo`, `ReaderScope` carries the reader's `UUID`, and
  `Bookmark.editable` lists the editable fields once.
- `RoostApp.migrations` takes a `MigrationRegistry` of Swift migrations and
  bundled SQL history, from Spectro's `SpectroMigrations`, which `import Roost`
  now includes. `App migrate` and `roost migrate` then run it through Spectro's
  migration command, and `App migrate plan` prints the SQL without a database.
  `down` still rolls back one migration unless given `--step`, and
  `down --all` rolls back every one. Apps without a registry keep running
  `Sources/Migrations/`.
- The example app bundles its generated SQL and adds three Swift migrations:
  a `read_at` column the database keeps in step with `read`, an index that
  matches the reading queue's query, and a check that links are http or https.
  The details page shows when a link was finished.
- `DriftDetector`'s documentation and output no longer name `roost
  db:schema:dump` or `roost db:drift`, which the CLI doesn't have.

### Upgrade: typed data and migrations

Most apps compile unchanged, with deprecation warnings for:

- `AuthAssign`. Read the state with `currentUser(_:)`, `authenticatedUserID`,
  `authContext`, and `currentScope(_:)`. Roost 3.0 removes the string keys.
- Features that aren't implemented: `ValkeyPubSub` and `PubSub.valkey(url:)`,
  `JobQueue.postgres(spectro:)`, `PostgresJobStore`, `JobWorker`,
  `SMTPDelivery`, `channel(_:)`, and `ServerConfig`'s `tls`, `http2`,
  `TLSConfig`, and `validate()`. Each warning says what the feature does
  instead: stop the process, do nothing, or go unused. Roost 3.0 removes them
  from the stable API until they are implemented.

`AuthScope` has an associated type, which changes code that works with any
scope rather than a concrete one:

- Reading `scopeId` from an `any AuthScope` value gets
  `(any Hashable & Sendable)?` instead of `String?`. Read it from the concrete
  scope type instead.
- Generic code gets `S.ScopeID?`, so `func id<S: AuthScope>(_ scope: S) -> String? { scope.scopeId }`
  no longer compiles. Add `where S.ScopeID == String`, or return `S.ScopeID?`.
- `AuthScope` used as a type is an existential, which Swift 6's `ExistentialAny`
  setting reports. Write `any AuthScope`.

Roost now requires Spectro 2.3.1 or later. Spectro 2.3.0 joined `where`
clauses without parentheses, so an `||` condition on `ScopedRepo.query()`
could return another owner's records. `swift package update` picks it up.

`import Roost` now includes SpectroMigrations, whose public names include
`Migration`, `SQL`, `CreateTable`, `AlterTable`, `DropTable`, `CreateIndex`,
`Reversible`, and `Irreversible`. A type the app declares in its own module
takes precedence and needs no change. A file that imports Roost and another
module, such as a package of the app's or a dependency, that declares one of
these names reports "ambiguous use"; qualify the name with its module, such as
`AppCore.Migration`.

## 2.1.3

`roost spectro` can show Spectro's colors, spinners, and styled tables again.

- Roost has a `RichTerminal` trait that turns on Spectro's. Apps opt in on their
  swift-roost dependency:

  ```swift
  .package(url: "https://github.com/roost-framework/swift-roost", from: "2.1.3",
           traits: [.defaults, "RichTerminal"])
  ```

  Apps created by roost-cli 2.1.1 or later include it. Without it, an app
  downloads no Noora and `roost spectro` prints plain text, as in 2.1.2.
- The trait is off by default because SwiftPM 6.4 can't resolve a dependency
  trait that a non-root package turns on through its own default traits: every
  app depending on Roost would fail with "exhausted attempts to resolve the
  dependencies graph".
- An app that added Spectro as a direct dependency to get the richer output can
  drop that dependency and use the trait.

### Upgrade

Update swift-roost before adding the trait to an existing app. SwiftPM checks
traits against the version an app already resolved, and releases before 2.1.3
declare none, so adding the trait first fails with "enables traits
[RichTerminal, default] on package 'swift-roost' that declares no traits":

```sh
swift package update swift-roost   # with the old dependency line
# then add traits: [.defaults, "RichTerminal"] and run:
swift package resolve
```

## 2.1.2

Roost apps no longer download Noora: an app built on Roost resolves 39 packages
and 448 MB of sources, down from 42 and 536 MB with 2.1.1.

- Roost depends on Spectro 2.3.0 or later with only its `CLI` trait. `roost
  spectro` still builds and runs the app's own `spectro` command, now without
  Noora: it prints plain text instead of colors, spinners, and styled tables.
  An app that depends on Spectro directly keeps its default traits and the
  richer output.

## 2.1.1

Roost apps download about 75 MB less.

- Roost depends on Nexus 2.1.0 or later with its default `Vapor` trait turned
  off. SwiftPM no longer fetches Vapor, routing-kit, multipart-kit,
  console-kit, or websocket-kit for an app built on Roost. An app that depends
  on Nexus directly keeps the trait, so `NexusVapor` keeps working there.
- Spectro keeps its default traits, because `roost spectro` builds and runs the
  app's own `spectro` command.

## 2.1.0

Roost adds Phoenix-style controllers. Routes name a controller action the
compiler checks, actions decode only the parameters they permit, and every
request is logged and traced by action.

### Upgrade

- Closure routes keep working; adopting controllers is optional. See the
  Controllers guide (`Sources/Roost/Roost.docc/Controllers.md`).
- The `roost` CLI moved to [roost-cli](https://github.com/roost-framework/roost-cli)
  and swift-roost no longer has a `roost` executable product. Install it with
  `mint install roost-framework/roost-cli@2.1.0`.
- `pipeline(_:_:)` and `scope(_:pipelines:)` with string names are deprecated.
  An undeclared name now stops the app at startup. Previously it was ignored, so
  its routes were served without the pipeline's plugs, which could include CSRF
  protection or authentication. Declare `NamedPipeline` values and pass them to
  `scope(_:pipelines:)` instead.
- The default `plugs` use `roost_requestLogger()` instead of Nexus's
  `requestLogger()`. It logs through swift-log with the `roost.request` label
  instead of printing. Apps that override `plugs` keep the loggers they list.
- `tracing()` names spans after the matched route (`GET /recipes/:id`) instead of
  the raw path, and reuses the ID from `requestId()` when that plug runs first.
  Update dashboards or alerts that match the old span names.
- Roost requires swift-distributed-tracing 1.3.0 or later.

### Controllers

- `Controller` groups actions. Its `Action` enum names them, and an exhaustive
  `switch` in `action(_:)` maps each one to its function, so a missing function
  or a route to an undeclared action is a compile error.
- `GET`, `POST`, `PUT`, `PATCH`, and `DELETE` take a controller and an action.
- `resources(_:_:only:except:)` routes the REST actions a controller declares:
  `index`, `new`, `create`, `show`, `edit`, `update` (PATCH and PUT), and
  `delete`.
- Controller `plugs` run after routing and before the action, each optionally
  limited with `only:` or `except:`.
- `conn.matchedRoute` reports the route pattern, controller, and action, and is
  kept on error responses.

### Parameters

- `conn.permit(T.self)` decodes a request into a `Decodable` type: the JSON body,
  or query, form, and path parameters with path parameters taking precedence.
  Undeclared fields are dropped. A missing or invalid field throws
  `ValidationErrors` naming it; a malformed JSON body is a 400 response.
- `FormValues.decode(as:)` decodes a whole form into a type with the same rules.

### Logging, tracing, and metrics

- `roost_requestLogger(filterParameters:logger:)` writes one line per request when
  the response is ready, with the action, route, status, duration, request ID,
  and parameters as metadata. Parameters such as passwords, tokens, and keys are
  logged as `[FILTERED]`, including inside JSON bodies. Failed requests are
  logged with their action too.
- `tracing(tracer:)` continues an incoming trace when the tracer understands its
  headers, records `http.route`, `roost.controller`, and `roost.action`, wraps
  each action in a child span named `Controller.action`, and marks server
  errors. Spans started inside an action nest under it.
- The development metrics endpoint groups durations by route pattern.

### Routing

- `scope(_:pipelines:)` accepts `NamedPipeline` values, and a pipeline builder
  accepts a list of plugs such as `browserPlugs()`.

## 2.0.1

Roost, ESW, Spectro, Nexus, and the Roost Playground moved to the
[roost-framework](https://github.com/roost-framework) organization.

### Upgrade

- Point package URLs at `https://github.com/roost-framework/`. The former
  `Maartz/swift-roost` and `Spectro-ORM/*` URLs redirect, but SwiftPM warns when
  one dependency graph reaches a package through both. Apps generated by Roost
  2.0.0 also declare ESW at its former URL; update it together with Roost's.
- The website moved to https://roost-framework.github.io/swift-roost/.

### Changes

- Roost resolves ESW, Spectro, and Nexus from `roost-framework`, and `roost new`
  generates apps that do the same.

## 2.0.0

Roost is the new name for Peregrine. This release connects the generated-app
workflow from authentication and database migrations through HTML, JSON, and tests.

### Upgrade

- Replace the `Peregrine` and `PeregrineTest` products and imports with `Roost`
  and `RoostTest`. Use the `roost` executable and `ROOST_*` environment variables.
- Update application types and functions to their `Roost` / `roost_` names.
  See [Moving to Roost](guides/renaming-to-roost.md) for the complete name mapping.
- Existing browser sessions expire across the rename because the default cookie
  and internal session keys changed. Application records and migration history
  are preserved.
- Use Swift 6.3 or later, macOS 14+ or Linux. The package accepts
  Spectro 2.x starting at 2.0.0, alongside Nexus 2.0.0 and ESW 1.5.0. Linux builds also require zlib development headers.
- Roost's generators retain Spectro's SQL migration workflow. Spectro 2.1
  adds optional Swift migration declarations, which use a separate migration executable;
  they are not generated by `roost gen migration` in this release.

### Application workflow

- New apps resolve published Roost 2.0.0 by default; `roost --version` reports
  the CLI version. Local framework and companion overrides remain optional.
- Resource generators connect models, contexts, input validation, migrations,
  typed ESW views, HTML and JSON routes, and tests. They register routes, refuse
  overwrites, and order dependent migrations even when generated in one second.
- Generated authentication and scoped resources enforce ownership through the
  application context. Browser workflows include CSRF protection, form decoding,
  method overrides, retained invalid input, and one-time flash messages.
- Sessions make changes visible within the request and persist before the
  response is sent. Error handling preserves earlier middleware state.
- Internal tracing header names coexist with current HTTPTypes releases.
- Migration commands use the application's configuration and Spectro's migration
  manager, including the compiled executable's `migrate up`, `down`, and `status`.
- The development server retains the previous running app when a rebuild fails.
- `RoostTest` includes cookie-preserving browser helpers and transaction-scoped
  database tests. A generated-app acceptance script exercises real PostgreSQL
  and HTTP workflows, including isolated users and migration rollback/reapply.

### Try it

- Follow the [quickstart](README.md#quickstart), or run the complete
  [reading-list example](examples/Roost).
- Browse the [website and guided playground](https://roost-framework.github.io/swift-roost/).
- Build the native [DocC guides and API reference](Documentation/README.md).

Channels, SMTP delivery, and persistent PubSub/job adapters remain unfinished.
TLS and HTTP/2 configuration is not yet connected to application bootstrap.
See the [implementation status](Sources/Roost/Roost.docc/ProjectStatus.md).

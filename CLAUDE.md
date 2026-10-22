# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

`swift-roost` is the Roost web framework, a Phoenix-inspired Swift library. It ships two library products, `Roost` and `RoostTest`. It has no executable: the `roost` CLI and its generators live in the separate [roost-cli](https://github.com/roost-framework/roost-cli) repository. Roost connects three companion packages from the same organization:

- **Nexus**: `Connection`, `Plug`, routing, and the Hummingbird adapter
- **Spectro**: PostgreSQL models, repositories, and migrations
- **ESW**: HTML templates compiled to Swift

## Commands

```sh
swift build
swift test                                   # framework tests; no PostgreSQL needed
swift test --filter ControllerTests          # one suite; the regex matches the Swift type name, not the @Suite title
swift test --filter ControllerTests/restRoutes   # one test, by function name
swift test list                              # print test identifiers
VALKEY_URL=valkey://127.0.0.1:6379 swift test --traits Valkey   # also run the store conformance tests against a Valkey server
POSTGRES_URL=postgres://postgres:postgres@localhost:5432/roost_jobs_test swift test --filter PostgresJobQueueTests   # job queue against PostgreSQL; creates and drops scratch databases
python3 scripts/check_local.py               # every ci.yml job on this machine, against the committed checkout; run before pushing
```

- Requires Swift 6.3+ and macOS 15+ or Linux. On Linux, Nexus needs `zlib1g-dev`.
- By default dependencies resolve from GitHub. To develop against local checkouts, set `ROOST_ECOSYSTEM_PATH` to the parent directory of `Nexus`, `Spectro`, and `esw`. `ROOST_ESW_PATH` overrides ESW alone (see `ecosystem()` in `Package.swift`). Unset both before verifying published behaviour, because CI tests against published versions.
- The generated-app acceptance check lives in roost-cli and needs a local PostgreSQL server: `python3 ../roost-cli/scripts/check_generated_app.py --framework ../swift-roost [--release]`. The README asks contributors to run it for framework changes.
- Example app (`examples/Roost`, PostgreSQL required): `./dev` serves it on port 4000 and needs the `roost` CLI on PATH; `./check` runs its tests in a throwaway database.
- DocC: `python3 scripts/build_docs.py [--output /tmp/Roost.doccarchive]`. The script runs `--warnings-as-errors`, so a broken symbol link fails the build. Archives are written outside the checkout. See `Documentation/README.md`.
- Website (`website/`, plain HTML/CSS/JS, no build step): run the checks listed in `website/README.md` (`node --test website/playground/examples.test.mjs`, `python3 website/check.py`, …).
- Formatting uses `.swift-format` (120 columns, 4-space indent). CI does not enforce it.

## Architecture

**Everything is a Nexus `Plug`**, a `(Connection) async throws -> Connection` function. `Connection` is an immutable value. Services travel on it as typed `AssignKey` assigns (`SpectroKey`, `RepositoryKey`, `HTMLLayoutKey`, `PubSubKey`, `JobQueueKey`, …), and Roost adds accessors through `extension Connection` (`conn.repo()`, `conn.render`, `conn.permit`, `conn.matchedRoute`). `Exports.swift` re-exports Nexus, NexusRouter, NexusHummingbird, Spectro, ESW, HTTPTypes, and Foundation, so apps only `import Roost`.

**One pipeline for the server and the tests.** `roost_applicationPipeline` (`RequestPipeline.swift`) builds the full request stack in this order: inject services, load the session (if `sessionStore` is set), run `app.plugs`, then route. `roost_requestPipeline` wraps every plug in error rescue, so an error response keeps the state from the plugs that completed. It also awaits session persistence before response hooks run. Live reload wraps the whole stack. Both `RoostApp.main()` (`RoostApp.swift`) and `RoostTest.TestApp` call this same function. Put request-lifecycle changes there so the two paths cannot drift.

**`RoostApp`** requires only `routes`. Everything else has a protocol-extension default. `main()` handles the `migrate`, `db`, and `routes` subcommands itself, which is how compiled apps run `App migrate up` and `App db setup`. Otherwise it connects Spectro, calls `willStart`, and serves through `NexusHummingbirdAdapter`. `Roost.env` comes from `ROOST_ENV` and defaults to `.dev`, including during `swift test`. Some tests rely on that default.

**Controllers** (`Controllers/`): a route names a `ControllerAction` enum case, and `action(_:)` is an exhaustive `switch`, so the compiler rejects an unknown action. `roost_handler(for:)` filters the controller's `ActionPlug`s with `only:`/`except:` and writes the controller and action into a `MatchedRouteRecorder` before running them. The recorder is a locked reference type, not a value, so plugs that ran *before* the router (the request logger, tracing, metrics) can still read the matched route afterwards, even when an error replaced the connection. `conn.permit(T.self)` (`Params.swift`) decodes only the fields `T` declares and turns invalid input into a 422.

**Pipelines and scopes** (`Pipelines/`): use `NamedPipeline` values with `scope(_:pipelines:)`. String-named pipelines are deprecated. They use global state and stop the app at startup if a name is undeclared. `browserPlugs()` provides body parsing, method override, flash, and CSRF.

**Views** (`ViewRendering.swift`, `Form.swift`): ESW templates sit beside `@ESWTemplate` view structs. `conn.render(view)` sets a task-local `FormRenderContext`, which `<.form>` reads to inject the session CSRF token and the `_method` override. A misconfigured form makes `render` throw instead of emitting an unprotected form.

**Data**: `conn.repo()` returns the `RepositoryKey` override if one is set (tests inject a transaction-owned repository through `withTestRollback`). Otherwise it calls `spectro.repository()`. Contexts take `any Repo`. `Data/` builds typed writes on the `_keyPathToColumn` table `@Schema` generates: `Changes<Model>` (key-path-named values), `Permitted<Model>` with `conn.permit(_:)` (decode a model's permitted fields), and `ScopedRepo` (`repo.scoped(\Model.ownerId, to:)`, whose update and delete are single owner-matching SQL statements, because `TransactionRepo.transaction` throws inside a test transaction). `Store/` is the key-value store: `conn.store` is an `any KeyValueStore`, a protocol on encoded bytes whose typed `StoreKey` methods are JSON-encoding extensions. `main()` resolves `RoostApp.store` (`StoreConfiguration`) into a namespaced store plus `Service`s it passes to Hummingbird's `Application(services:)`. `TestApp` always uses a fresh `MemoryKeyValueStore`, and `roost_applicationPipeline` binds `KeyValueSessionStore()` to the app's store. The Valkey backend is behind the `Valkey` trait (`#if Valkey`). Migrations wrap Spectro's manager (`Migrations/`). `Validations/` provides changesets, key path rules for `Changes`, and maps database errors to field errors.

**Partly implemented features.** Check before relying on these: `PostgresJobQueue` runs jobs through swift-jobs-postgres; `InMemoryJobQueue` runs each job inside `push`, and `TestApp` always uses it. PubSub has in-memory and Valkey (`ValkeyPubSub`, `Valkey` trait) adapters. Channels speak Phoenix's V2 protocol over WebSocket (`ChannelSocketServer`); the server upgrades their socket before routing. SMTP delivery is a stub. Since 2.3 the stubs are `@available(*, deprecated)`, with messages saying what they do instead; keep Roost's own code from referencing them so the framework builds without warnings.

## Conventions

- Tests use Swift Testing (`@Suite`, `@Test`, `#expect`), not XCTest.
- Auth state lives under typed `AssignKey`s named after the 2.1 `AuthAssign` strings (`_roost_current_user`, …), because Nexus stores a typed assign under `String(describing:)` of its key type. Typed and string access share one slot until 3.0 removes `AuthAssign`.
- A `roost_` prefix marks Roost's versions of things Nexus also provides, such as `roost_requestLogger` and `roost_csrfProtection`. It also marks internal helpers on Nexus types (`roost_recordingMatchedRoute`). Cross-module internals shared with `RoostTest` use `package` access.
- Commits follow Conventional Commits (`feat:`, `fix:`, `docs:`, `ci:`, `refactor:`). `CHANGELOG.md` has one section per release, with an **Upgrade** subsection when apps need to change.
- Release version numbers are hard-coded in prose across `README.md`, `Documentation/README.md`, `Sources/Roost/Roost.docc/*.md`, `website/index.html`, and `website/README.md`. Update them together.
- New DocC articles must be added to the `Topics` section of their module's landing page (`Roost.md` / `RoostTest.md`) to appear in the navigator.
- `specs/` holds historical design documents and sprint plans. The `.swift` files there are not compiled and may not match the current API. Treat the sources and tests as the source of truth.
- Releases publish documentation through `.github/workflows/pages.yml`: the `release-docs` job builds each tag's archive and attaches it to the release, then `scripts/publish_docs.py` assembles every version on deploy.

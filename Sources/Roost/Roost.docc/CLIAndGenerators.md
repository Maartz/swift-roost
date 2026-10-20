# CLI and generators

Create connected application files, then make the domain code your own.

## Overview

Install the CLI as shown in <doc:GettingStarted>.

### Generate a reading room

From any directory:

```sh
roost new ReadingRoom
cd ReadingRoom
roost gen auth
roost gen resource Bookmark title:string url:string read:bool --both --scope user_id
```

Use an app name distinct from `Roost`, `RoostTest`, and `RoostCLI`. Those names
belong to framework modules.

The resource command creates a Spectro model, repository-backed context, input
type, SQL migration, ESW views, an HTML `BookmarkController` and a JSON
`BookmarkAPIController`, and input tests. It also registers the routes in the
generated application:

```swift
resources("/bookmarks", BookmarkController.self)
scope("/api") { resources("/bookmarks", BookmarkAPIController.self) }
```

With `--scope user_id`, the HTML controller runs `requireAuth()` before every
action, and both controllers pass the signed-in user's ID to the context. The
controllers decode input with `conn.permit`, so the input type is the list of
fields a request can set. Authentication is generated
first so the ownership foreign key can reference the users table.

### Create the databases

`roost server`, `roost migrate`, and `roost spectro` run the app's PostgreSQL
in a container, `roost-readingroom-db`, with Apple's `container` or Docker. The
first of them starts it and prints `[roost] Postgres: 127.0.0.1:<port>`; the
port stays the same for the app.

```sh
unset DB_NAME
roost spectro database create reading_room_dev
roost spectro database create reading_room_test

roost migrate up
ROOST_ENV=test roost migrate up
DB_HOST=127.0.0.1 DB_PORT=<port> swift test
roost server
```

The `DB_NAME` override is unset here so development and tests select distinct
databases from the generated base name. To use a PostgreSQL server you run
yourself, export `DB_HOST`, `DB_PORT`, `DB_USER`, and `DB_PASSWORD`; `roost`
then starts no container. On macOS, Apple's `container` publishes ports only
after you allow `container-runtime-linux` in System Settings > Privacy &
Security > Local Network.

Register at `/auth/register`, then visit `/bookmarks`. The JSON resource is at
`/api/bookmarks`. Its mutating requests use the session cookie and CSRF token.

### Find the generated code

```text
ReadingRoom/
├── Package.swift
├── Sources/
│   ├── ReadingRoom/
│   │   ├── App.swift
│   │   ├── Models/
│   │   ├── Contexts/
│   │   ├── Controllers/
│   │   ├── Routes/
│   │   ├── Plugs/
│   │   └── Views/
│   └── Migrations/
├── Public/
└── Tests/ReadingRoomTests/
```

Add business rules to the context or shared input type. Add transport behavior
to controllers, and keep routes as the table of endpoints. Change the typed view and template together when their inputs change.
Generators refuse file overwrites; after generation, the files are yours to edit.

The local `examples/Roost` reading-list app demonstrates this structure with
validation, filtering, private reading queues, and PostgreSQL workflow tests.
Its `./dev` and `./check` helpers own local setup and disposable test databases.

### Choose the output you need

| Command or option | Result |
| --- | --- |
| `new MyApp` | App with database configuration, ESW, and Pico CSS. |
| `new MyAPI --no-db --no-esw` | Starter without database setup or file templates. |
| `new MyApp --tailwind` | Tailwind configuration instead of Pico. |
| `gen resource Post title:string` | HTML CRUD resource. |
| `gen resource Post title:string --json` | JSON resource. |
| `gen resource Post title:string --both` | Both transports sharing one context. |
| `gen resource Post title:string --model-only` | Model, context, migration, and input tests. |
| `gen migration add_post_index` | Empty SQL migration to fill in. |
| `migrate up / down / status` | App-configured migration operations. |
| `spectro database create my_app_dev` | Any `spectro` command, run with the app's resolved Spectro version. |
| `server --port 8080` | Build, serve, and watch for edits. |
| `build` | Build the app and its configured CSS assets. |
| `gen dockerfile` | Generate the Linux container build and runtime recipe. |

Run `roost <command> --help` for the command's supported options.
`roost spectro` runs the `spectro` executable from the app's own dependencies,
so its version always matches `Package.resolved`. Use it to create or drop
databases. There is no seed command.

Generated apps depend on swift-roost with `traits: [.defaults, "RichTerminal"]`,
which gives `roost spectro` colors, spinners, and styled tables. Without the
trait, `spectro` prints the same information as plain text and SwiftPM doesn't
download Noora. Add the trait to an app created before roost-cli 2.1.1 the same
way, with `from: "2.1.3"` or later.

Update swift-roost before adding the trait to an existing app. SwiftPM checks
traits against the version an app already resolved, and releases before 2.1.3
declare none, so adding the trait first fails with "enables traits
[RichTerminal, default] on package 'swift-roost' that declares no traits":

```sh
swift package update swift-roost   # with the old dependency line
# then add traits: [.defaults, "RichTerminal"] and run:
swift package resolve
```

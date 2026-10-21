# Configuration and deployment

Configure the application explicitly and ship its runtime files with the executable.

## Overview

Application configuration lives in Swift through ``RoostApp``. Environment
variables select runtime values; Roost does not automatically load `.env` files.

### Select the runtime environment

``Roost/Roost/env`` defaults to `dev`. Set `ROOST_ENV` to `dev`, `test`, or `prod`.
The process value is read once; the test harness uses a task-local override
without mutating global process variables.

| Variable | Behavior |
| --- | --- |
| `ROOST_HOST` | Default `127.0.0.1`. Use `0.0.0.0` when a container must accept connections from outside itself. |
| `ROOST_PORT` | Default `8080`. |
| `DB_HOST` | Default `localhost`. |
| `DB_PORT` | Default `5432`. |
| `DB_USER` | Default `postgres`. Set your actual database role. |
| `DB_PASSWORD` | Default `postgres`. Set your actual database password. |
| `DB_NAME` | Explicit database name; bypasses environment suffixes. |
| `ROOST_STORE_URL` | The key-value store, such as `valkey://cache.internal:6379`. Unset, the store is in memory. Needs the `Valkey` trait; see <doc:KeyValueStores>. |

Explicit host, port, username, and password arguments to
`Database.postgres(...)` take precedence over the corresponding variables.
`DB_NAME` takes precedence over the supplied base database name. Without it,
a supplied base receives `_dev` or `_test` in those environments and remains
unchanged in production. With neither a base nor `DB_NAME`, development and
tests use `roost_dev` and `roost_test`; production fails.

### Keep build overrides separate

| Variable | Build-time purpose |
| --- | --- |
| `ROOST_FRAMEWORK_PATH` | Framework checkout used by generated manifests. |
| `ROOST_ESW_PATH` | Optional ESW development checkout, taking precedence over ecosystem mode. |
| `ROOST_ECOSYSTEM_PATH` | Optional parent directory containing all companion source checkouts. |

Leave all three overrides unset to resolve published Roost,
ESW, Spectro, and Nexus. These values affect SwiftPM resolution, not database
selection.

### Build and package a release

From an application root:

```sh
swift build -c release
export ROOST_ENV=prod
export ROOST_HOST=0.0.0.0
export ROOST_PORT=8080
export DB_NAME=reading_room
# Export DB_HOST, DB_PORT, DB_USER, and DB_PASSWORD for the target database.

.build/release/ReadingRoom migrate up
.build/release/ReadingRoom
```

Run migrations explicitly before starting the app. Ship `Public/` and
`Sources/Migrations/` with the executable and run from the directory containing
them. Preserve any additional SwiftPM resource bundles your application uses.
An app with a ``RoostApp/migrations`` registry carries its SQL history in its
resource bundle instead of `Sources/Migrations/`: ship the
`<Package>_<Target>.resources` directory (`.bundle` on macOS) that SwiftPM
builds next to the executable, or `App migrate` stops with "unable to find
bundle". The Dockerfile `roost gen dockerfile` writes doesn't copy it yet.

`roost gen dockerfile` creates a Swift 6.3.3 build stage and matching slim
runtime, installs Linux zlib dependencies, and copies the public assets and
migrations. The default recipe resolves published Roost 2.0.1 and its companion
packages without additional framework checkouts in the build context.

### Understand server and storage boundaries

``ServerConfig`` controls the running server's host, port, and TLS. Without
TLS the server speaks HTTP/1.1, which suits an app behind an HTTPS terminator.
To serve HTTPS directly, pass a PEM certificate chain and key; the server then
negotiates HTTP/2 with clients that support it and falls back to HTTP/1.1:

```swift
var server: ServerConfig {
    ServerConfig(host: "0.0.0.0", port: 443, tls: .init(
        certificatePath: "/etc/ssl/app/fullchain.pem",
        keyPath: "/etc/ssl/app/privkey.pem"
    ))
}
```

A missing certificate or key file, or HTTP/2 requested without TLS, stops the
app at startup with ``ServerConfigError`` before it opens the database. The
certificate is read once at startup, so restart the app after renewing it.

The memory session store does not survive restarts or span replicas. Use
``KeyValueSessionStore`` with a Valkey `ROOST_STORE_URL` before relying on
persistent sessions. In production, an app whose key-value store fell back to
memory logs a warning the first time it uses it.
Likewise, inspect the implementation status of channels, jobs, and mail in
<doc:ProjectStatus> before depending on an external adapter.

### Share PubSub between servers

``InMemoryPubSub`` delivers messages within one process. ``ValkeyPubSub``
delivers them between the servers that share a Valkey or Redis server. Like a
Valkey store, it needs Roost's `Valkey` trait. Keep one instance in a static
property, so live routes can share it, and return it from ``RoostApp/pubSub``,
so it runs with the server:

```swift
// Valkey when PUBSUB_URL is set, such as in production; memory otherwise.
static let pubSub: any RoostPubSub = ProcessInfo.processInfo.environment["PUBSUB_URL"]
    .map { PubSub.valkey(url: $0) } ?? PubSub.inMemory()

var pubSub: (any RoostPubSub)? { Self.pubSub }
```

Servers share messages through one Valkey channel, named after the executable
and environment by default, such as `ReadingRoom:prod:pubsub`. Payload values
must be JSON: strings, numbers, booleans, arrays, and dictionaries. A server
disconnected from Valkey misses the messages published meanwhile, and
subscribes again once it reconnects.

### Run startup work deliberately

`RoostApp.configure(for:)` runs during bootstrap. `willStart(spectro:)` runs
after the configured database client is created and before serving requests;
it is skipped when there is no configured client. Keep migrations in the
explicit migration command rather than adding them to every server startup.

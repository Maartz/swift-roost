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
resource bundle instead of `Sources/Migrations/`.

`roost gen dockerfile` creates a Swift 6.3.3 build stage and matching slim
runtime, installs Linux zlib dependencies, and copies the public assets and
migrations. The default recipe resolves published Roost 2.0.1 and its companion
packages without additional framework checkouts in the build context.

### Understand server and storage boundaries

``ServerConfig`` currently controls the running server's host and port. Its
TLS and HTTP/2 fields are configuration data; bootstrap does not apply them to
Hummingbird. Use a separately configured HTTPS terminator for a deployed app
until that integration is implemented.

The default memory session store does not survive restarts or span replicas.
Supply a suitable ``SessionStore`` before relying on persistent sessions.
Likewise, inspect the implementation status of channels, jobs, mail, and
PubSub in <doc:ProjectStatus> before depending on an external adapter.

### Run startup work deliberately

`RoostApp.configure(for:)` runs during bootstrap. `willStart(spectro:)` runs
after the configured database client is created and before serving requests;
it is skipped when there is no configured client. Keep migrations in the
explicit migration command rather than adding them to every server startup.

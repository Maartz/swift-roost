# Key-value stores

Keep counters, caches, and sessions in memory during development and on Valkey in production.

## Overview

Every Roost app has a key-value store, ``Nexus/Connection/store``. During
development and in tests it lives in memory. In production, set one
environment variable and it lives on a Valkey or Redis server, shared by every
instance of the app and kept across restarts:

```sh
ROOST_STORE_URL=valkey://cache.internal:6379 .build/release/ReadingRoom
```

The app's code doesn't change between the two.

### Declare keys

A ``StoreKey`` names a value, its type, and how long it's kept. Declare keys
as static members, so every caller uses the same name, type, and expiry:

```swift
extension StoreKey where Value == Draft {
    static func draft(_ userID: UUID) -> Self {
        .init("draft:\(userID)", expiringAfter: .seconds(3600))
    }
}

extension StoreKey where Value == Int {
    static var signups: Self { .init("signups") }
}
```

A constrained extension of a generic type can't hold a stored `static let`,
so declare fixed keys as computed `static var` properties.

### Read and write values

```swift
try await conn.store.set(.draft(user.id), to: draft)
let saved = try await conn.store.get(.draft(user.id))  // Draft?
try await conn.store.remove(.draft(user.id))

let signups = try await conn.store.increment(.signups)

let forecast = try await conn.store.fetch(.forecast(city)) {
    try await weather.forecast(for: city)
}
```

Values are encoded as JSON. `increment` adds to a counter atomically, even
across servers, and a new counter starts its expiry when it's created.
`fetch` returns a stored value or computes, stores, and returns a new one; a
stored value of an older type counts as missing.

Every request a Roost app or `TestApp` handles has a store. A connection built
another way, such as one a plug's unit test makes, has none until you assign
one, and `conn.store` throws.

Contexts take `any KeyValueStore`, as they take `any Repo`, so a test can pass
its own ``MemoryKeyValueStore``:

```swift
struct DraftsContext: Sendable {
    let store: any KeyValueStore

    func save(_ draft: Draft, for userID: UUID) async throws {
        try await store.set(.draft(userID), to: draft)
    }
}

// In a controller:
try await DraftsContext(store: conn.store).save(draft, for: user.id)
```

### Keep sessions in the store

``KeyValueSessionStore`` keeps sessions in the app's store, so with Valkey
they survive deploys and work behind a load balancer:

```swift
let sessionStore: (any SessionStore)? = KeyValueSessionStore()
```

It also works when the app installs `session(store:cookieName:ttl:)` itself
to choose the cookie or the TTL. Each session is stored under a hash of its
ID, which is the cookie's value, so someone who can list the store's keys
can't sign in with them.

Session values must be strings, numbers, booleans, or arrays and dictionaries
of those. Store a `UUID` or a `Date` as a string. Saving another type throws,
with every store, so the mistake shows up during development.

### Run on Valkey in production

Valkey support is behind Roost's `Valkey` trait, so apps without it don't
download the client. Enable it on the swift-roost dependency:

```swift
.package(url: "https://github.com/roost-framework/swift-roost", from: "2.3.0",
         traits: [.defaults, "Valkey"])
```

Then set `ROOST_STORE_URL`:

| URL | Connects to |
| --- | --- |
| `valkey://cache.internal` | Port 6379, database 0 |
| `valkey://cache.internal:6380/2` | Port 6380, database 2 |
| `valkey://:password@cache.internal` | With a password, as the `default` user |
| `valkey://app:password@cache.internal` | As the user `app` |
| `valkeys://cache.internal` | With TLS |

`redis://` and `rediss://` work the same way, with Redis 6.2 or later.
Percent-encode special characters in a password, such as `%40` for `@`; error
messages hide the credentials either way. On macOS, the Valkey client needs
macOS 15 or later; Linux has no such requirement.

Roost connects when the server starts and closes the connections after the
server stops accepting requests. If Valkey becomes unreachable, the first
request that uses the store fails after two seconds, the next ones fail at
once, and the store recovers by itself when Valkey is back.

Roost prefixes every key with the app's type name and the environment, such
as `ReadingRoom:prod:`, so several apps and environments can share a server.

In production, an app without `ROOST_STORE_URL` keeps its store in memory and
logs a warning the first time it uses it: its values are lost on restart and
aren't shared between instances.

### Share rate limits between servers

``rateLimit(max:windowSeconds:by:message:name:fileID:line:)`` counts requests
in the app's store, so with Valkey a limit of 100 requests a minute is 100 for
the whole app, not for each instance:

```swift
var plugs: [Plug] {
    [rateLimit(max: 100, windowSeconds: 60)] + browserPlugs()
}
```

The window slides, so a client can't send twice the limit around the moment
one window ends and the next begins. Limits created at the same place in the
code, with the same `max` and window, share counters, even when a helper
creates them for different routes; pass `name:` to keep them apart. Counters
are named by a hash of the client, so a key such as an API key read with
`by: .header(_:)` isn't stored in the clear. If the store fails, requests are
allowed and the error is logged, so a Valkey outage doesn't take the app down.

### Choose the store in code

``RoostApp/store`` defaults to ``StoreConfiguration/environment``. Override it
to choose the store in code instead:

```swift
var store: StoreConfiguration { .valkey(url: "valkey://cache.internal") }
```

- ``StoreConfiguration/memory`` declares a single-process app; it keeps
  values in memory without the production warning.
- ``StoreConfiguration/persist(_:)`` adapts a Hummingbird `PersistDriver`,
  such as one from hummingbird-redis or hummingbird-postgres.
- ``StoreConfiguration/custom(_:)`` uses your own ``KeyValueStore``.
- ``StoreConfiguration/namespaced(_:)`` replaces the app and environment
  prefix.

### Test with the store

`TestApp` gives each test app its own ``MemoryKeyValueStore``, whatever the
app's configuration says, so tests don't share values or need a server. Read
it after a request, or pass one in with values already set:

```swift
let store = MemoryKeyValueStore()
try await store.set(.signups, to: 41)
let app = try await TestApp(ReadingRoom.self, store: store)
_ = try await app.post("/signup", json: form)
#expect(try await app.store.get(.signups) == 42)
```

The memory store encodes values, expires them, and increments counters the
same way Valkey does, so tests exercise the behavior production sees.

### Add a backend

Conform to ``KeyValueStore`` and implement its four requirements, which work
on encoded bytes; the typed methods come with the protocol. A store that
can't increment atomically can leave out
``KeyValueStore/increment(_:by:expiringAfter:)``, which then throws. A store
that conforms to `Service` runs with the server. Pass it to
``StoreConfiguration/custom(_:)``.

## Topics

### Reading and writing

- ``KeyValueStore``
- ``StoreKey``
- ``Nexus/Connection/store``

### Configuration

- ``StoreConfiguration``
- ``RoostApp/store``

### Stores

- ``MemoryKeyValueStore``
- ``KeyValueSessionStore``

### Errors

- ``KeyValueStoreError``

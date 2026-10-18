# Authentication and sessions

Load a trusted identity, scope domain operations to it, and persist session changes.

## Overview

Use the generated authentication workflow when building a conventional browser
app. The lower-level APIs let you supply your own user model, token lookup, and
session store; they do not replace credential validation in your application.

### Configure one session store

```swift
let sessionStore: (any SessionStore)? = KeyValueSessionStore()

var plugs: [Plug] {
    [requestId(), roost_requestLogger()] + browserPlugs()
}
```

These properties belong on your ``RoostApp``. The store is created once for the
application. Bootstrap installs its session middleware before application
middleware, and `RoostTest.TestApp` follows the same rule.

To customize cookie name or TTL, install `session(store:cookieName:ttl:)`
directly in `plugs` instead of configuring `sessionStore`. Choose one method;
`KeyValueSessionStore()` uses the app's store either way. The defaults are
`_roost_session` and 24 hours.

``KeyValueSessionStore`` keeps sessions in the app's key-value store. That
store is in memory until you set `ROOST_STORE_URL`; with Valkey, sessions
survive restarts and are shared between replicas. See <doc:KeyValueStores>.
Session values must then be strings, numbers, booleans, or arrays and
dictionaries of those.

``MemorySessionStore`` is process-local and accepts any value. Sessions
disappear on restart and are not shared between replicas. Implement
``SessionStore`` when you need another persistence model.

### Generate browser authentication

After the CLI setup in <doc:GettingStarted>, run this from an app root:

```sh
roost gen auth
```

The generator adds user and token models, migrations, credential handling,
`RegistrationController` and `SessionController` with their routes in
`Routes/AuthRoutes.swift`, templates, and current-user loading. After migrations, registration and
login are at `/auth/register` and `/auth/login`.

Password hashing uses the framework's ``Auth`` helpers. Successful login stores
a random session token, persists its digest for later lookup, and rotates the
session ID. Logout removes authentication from the session and deletes the
corresponding token record through the generated context.

### Distinguish loading from requiring a user

A fetch-user plug validates a token and sets the current user before a protected
route runs. `requireAuth()` then redirects a missing identity to the login page.
It does not load a user or validate a password by itself.

`optionalAuth()` is a pass-through marker; it also does not perform token lookup.
For bearer authentication, use a preceding bearer-token loader before
`requireApiAuth()`. That requirement plug checks the resulting identity and
returns 401 when absent.

``Authenticatable`` gives a user a stable `authID`. The low-level
`conn.loginUser` helper establishes session identity but does not write your
application's token table. If you use it directly, persist the token digest
and implement revocation yourself.

### Scope each domain operation

Use `conn.authenticatedUserID` after authentication middleware has established
an identity. `conn.authUserID` is only the raw session hint; it is not a
replacement for validated identity.

An ``AuthScope`` gives that identity a type. Its ``AuthScope/scopeId`` has the
type of the owner's primary key, so a `UUID` key needs no string conversion:

```swift
struct ReaderScope: AuthScope {
    let userID: UUID
    var scopeId: UUID? { userID }
}
```

Set the scope in the plug that loads the user, and require it where a request
needs one. ``Nexus/Connection/requireScope(_:)`` throws a 401 when no scope is
set:

```swift
// In the fetch-user plug:
return conn.setCurrentUser(user).setScope(ReaderScope(userID: user.id))

// In a controller:
let reader = try conn.requireScope(ReaderScope.self)
let context = BookmarksContext(repo: conn.repo(), reader: reader)
```

The context then limits every query and write to the reader's records with a
``ScopedRepo``; see <doc:DataAndMigrations>.

The resource generator accepts `--scope user_id`. Its handlers obtain the
owner from authentication, and its contexts check that owner on reads,
updates, and deletes. A submitted `user_id` cannot choose someone else's scope.

Read the authentication state with ``Nexus/Connection/currentUser(_:)``,
``Nexus/Connection/authenticatedUserID``, ``Nexus/Connection/authContext``, and
``Nexus/Connection/currentScope(_:)``. Roost stores it under typed assign keys.
The string keys of `AuthAssign` still reach the same values, but they are
deprecated and Roost 3.0 removes them.

Browser cookies also authenticate JSON requests in this workflow. Mutating
requests must supply the current CSRF token, including an `X-CSRF-Token` header
when submitting JSON. See <doc:ViewsAndForms> for token-aware forms.

### Understand session persistence

Session helpers return an updated connection. Keep and return that value:

```swift
return conn
    .putSessionValue("onboardingStep", 2)
    .putFlash(.info, "Saved")
    .redirect(to: "/next")
```

Later middleware sees mutations immediately. Roost awaits persistence when the
pipeline finishes, before synchronous response hooks and cookie emission.
Redirects and halted responses use the same finalization path.

Nexus string helpers (`getSession`, `putSession`, `deleteSession`) and Roost's
typed helpers share the same session state. Authentication, CSRF, and flash
therefore operate on one store.

If you embed `session(store:)` in a standalone Nexus pipeline, await
`conn.flushSession()` before `runBeforeSend()`. Roost applications and their test
harness already do this; no sleeps or manual flush are needed in request tests.

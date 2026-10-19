# Troubleshooting

Resolve common setup, compilation, and browser-workflow problems.

## Overview

### The compiler cannot find Roost

Require `swift-roost` 2.0.0 or later and select the `Roost` or `RoostTest`
product. The 1.x tags contain the earlier Peregrine names. Unset stale
`ROOST_FRAMEWORK_PATH` and `ROOST_ECOSYSTEM_PATH` overrides, then run
`swift package resolve`. An app itself cannot be named `Roost`.

### A route or controller doesn't compile

`type 'RecipeController.Action' has no member 'publish'` means a route names an
action the controller's `Action` enum doesn't declare. `switch must be
exhaustive` in `action(_:)` means an action has no function. Add the case and
its function together.

If the app stops at startup with `resources(...) can't route`, its `only:` list
names an action that isn't one of the seven REST actions. Route that action with
`GET`, `POST`, `PUT`, `PATCH`, or `DELETE` instead. `uses pipeline "…", which
was not declared` means a deprecated string pipeline was used before its
`pipeline(_:)` declaration; declare it as a `NamedPipeline` value instead.

### Templates collide or typed views are missing

Require ESW 1.7.0 or later in the app's direct dependency and run
`swift package resolve`. Unset `ROOST_ESW_PATH` and `ROOST_ECOSYSTEM_PATH` if
they select an older source checkout. File templates also require
`ESWBuildPlugin` on the app target.

### A form returns a CSRF or rendering error

Configure one session store, include ``browserPlugs()``, and render the typed
view through `conn.render`. Direct `view.render()` does not establish the request
scope required by mutating local forms. Check that the next request carries
the session cookie and the token from that session.

Cookie-authenticated JSON requests need CSRF protection too. Supply
`X-CSRF-Token` for mutations rather than switching the request's content type
to try to bypass the browser pipeline.

### The app cannot connect to PostgreSQL

Check the server, role, password, and selected database. An explicit `DB_NAME`
overrides environment suffixes, including in tests. Create the database before
running migrations, then inspect `roost migrate status`. Without a
``RoostApp/migrations`` registry, migration files are resolved from
`Sources/Migrations/` relative to the app's working directory. With one, they
are in the app's resource bundle, and a release binary copied without it
stops with "unable to find bundle".

### A request test works once and then fails

Use `app.browser()` to carry cookies through a browser workflow. Create separate
browsers to model different users. Follow redirects explicitly. Await app
shutdown when it owns a client, and keep database-owning tests isolated.

Do not wrap a workflow that starts its own transaction in `withTestRollback`;
Spectro rejects nested transactions. Use a disposable test database instead.

### The previous page remains after an edit

The development server keeps the working app when compilation fails. Read the
compiler diagnostics, correct the source or template, and wait for a successful
rebuild. Refresh the browser after the restart. The separate local Roost
Playground has its own reload behavior.

### An API exists but its integration does not work

Check <doc:ProjectStatus>. In particular, SMTP, the external PubSub and job
adapters, and network channel upgrades remain incomplete. Server TLS and HTTP/2
configuration is not yet applied during bootstrap.

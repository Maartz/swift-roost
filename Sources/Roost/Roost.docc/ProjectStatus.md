# Project status

Distinguish the implemented application workflow from development integrations.

## Overview

This catalog documents Roost 2.4.0, including live pages, reusable form fields, and the `db` and `routes` app commands. Releases before 2.0.0 use the earlier Peregrine module and executable names.

The core development path is a PostgreSQL-backed app with authentication,
ownership-scoped resources, HTML and JSON responses, Spectro migrations,
and in-process tests.

### Dependency and release boundaries

The framework and generated applications use published Nexus 2.x starting at 2.1.0,
Spectro 2.x starting at 2.3.1, and ESW 1.7.0 for the live runtime. ESW includes
typed views and namespaced generated output. Roost 2.0.0 is the first release with the renamed modules and CLI;
follow <doc:GettingStarted> to create an app using released dependencies.

The acceptance check in [roost-cli](https://github.com/roost-framework/roost-cli)
generates an app, migrates an isolated PostgreSQL database, runs the app's tests,
and exercises authentication, HTML, JSON, and two-user ownership over HTTP. CI
runs it on Linux against published companion packages. A documentation build
does not run that check or establish production readiness.

### Service implementation status

| Area | Current boundary |
| --- | --- |
| Key-value store | Memory and Valkey stores work; Valkey needs the `Valkey` trait. Hummingbird persist drivers can back it, without atomic counters. |
| Sessions | `KeyValueSessionStore` persists sessions in the key-value store; `MemorySessionStore` works within one process. |
| PubSub | `InMemoryPubSub` delivers within one process; `ValkeyPubSub` delivers between servers with the `Valkey` trait. |
| Jobs | `PostgresJobQueue` runs jobs in the background from the app's database, with retries and cron schedules; `InMemoryJobQueue` runs each job inside `push`. See <doc:BackgroundJobs>. |
| Mail | Logger and test deliveries are available; SMTP delivery is a stub. |
| Channels | Clients connect over WebSocket with Phoenix's JavaScript client, and its `Presence` follows who's online. Broadcasts reach every server through the app's PubSub; presence covers each server's own sockets. See <doc:Channels>. |
| TLS / HTTP/2 | `ServerConfig(tls:)` serves HTTPS and negotiates HTTP/2, falling back to HTTP/1.1, except in an app with channels. HTTP/2 without TLS is rejected at startup. |
| Live pages | `LivePage` and `LiveRoute` integrate ESWLive over SSE and POST, with session ownership, CSRF, reconnects, and shutdown. `broadcast(_:to:)` updates other open pages, on every server when the route has a PubSub. Page state is process-local; see <doc:LivePages>. |

Reference pages include these public declarations so you can inspect their
contracts. Their presence in the navigator does not mean their external
transport or storage adapter is complete.

Roost 2.3 deprecates the stubs: `JobQueue.postgres(spectro:)`, `PostgresJobStore`, `JobWorker`, `SMTPDelivery`,
and `channel(_:)`. Their deprecation warnings say what each one does instead.
They remain through 2.x, and Roost 3.0 removes them from the stable API until
they are implemented.

``DriftDetector`` compares schema snapshots, but the `roost` CLI has no command
that runs it; call it from a test or a CI script.

### Browser and local playgrounds

The [website playground](https://roost-framework.github.io/swift-roost/playground.html)
runs three guided JavaScript previews of Swift examples. It does not compile or
execute arbitrary Swift.

The separate local Roost Playground compiles Swift and integrates ESW Live.
Its setup depends on companion development checkouts. It is a different
execution environment from the website, and successful rebuilds reset live
state.

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
| PubSub | In-memory implementation is available; the Valkey adapter is unfinished. |
| Jobs | In-memory queue is available; the PostgreSQL store is a stub. |
| Mail | Logger and test deliveries are available; SMTP delivery is a stub. |
| Channels | In-process registry and test helpers exist; the HTTP upgrade route is a stub. |
| TLS / HTTP/2 | `ServerConfig(tls:)` serves HTTPS and negotiates HTTP/2, falling back to HTTP/1.1. HTTP/2 without TLS is rejected at startup. |
| Live pages | `LivePage` and `LiveRoute` integrate ESWLive over SSE and POST, with session ownership, CSRF, reconnects, and shutdown. State is process-local; see <doc:LivePages>. |

Reference pages include these public declarations so you can inspect their
contracts. Their presence in the navigator does not mean their external
transport or storage adapter is complete.

Roost 2.3 deprecates the stubs: `ValkeyPubSub` and `PubSub.valkey(url:)`,
`JobQueue.postgres(spectro:)`, `PostgresJobStore`, `JobWorker`, `SMTPDelivery`,
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

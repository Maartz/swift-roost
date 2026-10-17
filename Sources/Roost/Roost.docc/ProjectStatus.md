# Project status

Distinguish the implemented application workflow from development integrations.

## Overview

This catalog documents Roost 2.1.3 and its generators. Releases before 2.0.0
use the earlier Peregrine module and executable names.

The core development path is a PostgreSQL-backed app with authentication,
ownership-scoped resources, HTML and JSON responses, Spectro migrations,
and in-process tests.

### Dependency and release boundaries

The framework and generated applications use published Nexus 2.x starting at 2.1.0,
Spectro 2.x starting at 2.3.0, and ESW 1.6.0. ESW's release includes typed views and namespaced generated
output. Roost 2.0.0 is the first release with the renamed modules and CLI;
follow <doc:GettingStarted> to create an app using released dependencies.

The acceptance check in [roost-cli](https://github.com/roost-framework/roost-cli)
generates an app, migrates an isolated PostgreSQL database, runs the app's tests,
and exercises authentication, HTML, JSON, and two-user ownership over HTTP. CI
runs it on Linux against published companion packages. A documentation build
does not run that check or establish production readiness.

### Service implementation status

| Area | Current boundary |
| --- | --- |
| Sessions | Memory store works within one process; persistent or shared storage needs another implementation. |
| PubSub | In-memory implementation is available; the Valkey adapter is unfinished. |
| Jobs | In-memory queue is available; the PostgreSQL store is a stub. |
| Mail | Logger and test deliveries are available; SMTP delivery is a stub. |
| Channels | In-process registry and test helpers exist; the HTTP upgrade route is a stub. |
| TLS / HTTP/2 | Configuration types exist; application bootstrap does not wire them into the server. |
| Live views | The separate local Roost Playground integrates ESW Live; this is not a Phoenix LiveView implementation. |

Reference pages include these public declarations so you can inspect their
contracts. Their presence in the navigator does not mean their external
transport or storage adapter is complete.

Roost 2.2 deprecates the stubs: `ValkeyPubSub` and `PubSub.valkey(url:)`,
`JobQueue.postgres(spectro:)`, `PostgresJobStore`, `JobWorker`, `SMTPDelivery`,
`channel(_:)`, and the TLS and HTTP/2 settings of ``ServerConfig``. Their
deprecation warnings say what each one does instead. They remain through 2.x,
and Roost 3.0 removes them from the stable API until they are implemented.

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

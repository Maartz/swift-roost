# ``Roost``

Build a Swift web application with routes, typed data, compiled HTML, and tests.

## Overview

Roost connects Nexus for HTTP, Spectro for PostgreSQL, and ESW for templates.
Define an application with ``RoostApp``, keep domain operations in
repository-backed contexts, and expose them through HTML pages or JSON routes.

Start with <doc:GettingStarted>. For a complete workflow, follow
<doc:CLIAndGenerators> through authentication and an ownership-scoped resource.

These pages document Roost 2.4.0 with Nexus 2.x (from 2.1.0), Spectro 2.x (from 2.3.1), and ESW 1.7.0.
Generated apps resolve published packages directly. See <doc:ProjectStatus>
for the current implementation boundaries.

## Topics

### Build an application

- <doc:GettingStarted>
- <doc:Controllers>
- <doc:RoutingAndMiddleware>
- <doc:ViewsAndForms>
- <doc:DataAndMigrations>
- <doc:KeyValueStores>
- <doc:AuthenticationAndSessions>
- <doc:CLIAndGenerators>

### Run and maintain it

- <doc:ConfigurationAndDeployment>
- <doc:TestingYourApp>
- <doc:Troubleshooting>
- <doc:ProjectStatus>

### Application and configuration

- ``RoostApp``
- ``Roost/Roost``
- ``Environment``
- ``ServerConfig``
- ``Database``
- ``HTMLLayout``

### Controllers and requests

- ``Controller``
- ``ControllerAction``
- ``ActionPlug``
- ``MatchedRoute``

### Browser requests and validation

- ``browserPlugs()``
- ``Form``
- ``FormValues``
- ``ViewRenderingError``
- ``Flash``
- ``FlashLevel``
- ``Changeset``
- ``ChangesetAction``
- ``ValidationErrors``
- ``ValidationMessage``
- ``ValidationStrategy``
- ``ValidatorRule``

### Data and ownership

- ``Changes``
- ``Permitted``
- ``ScopedRepo``

### Key-value stores

- ``KeyValueStore``
- ``StoreKey``
- ``StoreConfiguration``
- ``MemoryKeyValueStore``
- ``KeyValueSessionStore``
- ``KeyValueStoreError``

### Identity and sessions

- ``Authenticatable``
- ``Auth``
- ``AuthError``
- ``AuthScope``
- ``AuthContext``
- ``SessionStore``
- ``MemorySessionStore``
- ``RoostToken``

### Database migrations

- ``RoostMigrator``
- ``MigrationGenerator``
- ``RoostMigrationInfo``
- ``RoostMigrationReport``

### Streaming and application services

- <doc:LivePages>
- ``LivePage``
- ``LiveRoute``
- ``ServerSentEvent``
- ``SSEBroadcaster``
- ``RoostPubSub``
- ``InMemoryPubSub``
- ``ValkeyPubSub``
- ``RoostJob``
- ``InMemoryJobQueue``
- ``Email``
- ``MailDelivery``
- ``TestDelivery``

### Channels and presence

- ``Channel``
- ``ChannelRouter``
- ``ChannelSocket``
- ``ChannelRegistry``
- ``Presence``

### Extended libraries

- ``Nexus``

The channel transport, external service adapters, and deployment limitations are
described in <doc:ProjectStatus>. A reference page does not imply that its
integration is complete.

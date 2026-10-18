import Foundation
import HTTPTypes
import Nexus
import NexusRouter
import NexusTest
import Roost
import Spectro

// MARK: - PresenceAccessor

/// Provides access to the presence list for a given `ChannelRegistry`.
/// Obtained via `TestApp.presence`.
public struct PresenceAccessor: Sendable {
    private let registry: ChannelRegistry

    init(registry: ChannelRegistry) {
        self.registry = registry
    }

    /// Returns the current presence list for the given topic, sorted by `online_at`.
    public func list(_ topic: String) async -> [PresenceEntry] {
        registry.listPresence(topic: topic)
    }
}

// MARK: - Shared channel registry per App type

/// Thread-safe storage for per-App.Type channel registries.
/// Allows multiple `TestApp<ChatApp>` instances to share the same `ChannelRegistry`
/// so sockets from different instances can exchange broadcasts.
private enum SharedChannelRegistry {
    nonisolated(unsafe) static var lock = NSLock()
    nonisolated(unsafe) static var registries: [ObjectIdentifier: ChannelRegistry] = [:]

    static func registry(for typeID: ObjectIdentifier, router: ChannelRouter) -> ChannelRegistry {
        lock.withLock {
            if let existing = registries[typeID] { return existing }
            let r = ChannelRegistry(router: router)
            registries[typeID] = r
            return r
        }
    }
}

// MARK: - TestApp

/// A test harness that runs requests through a ``/Roost/RoostApp`` pipeline
/// without starting a server.
///
/// For a database-free application named `HelloApp`:
///
/// ```swift
/// @Test func homeResponds() async throws {
///     let app = try await TestApp(HelloApp.self, database: .some(nil))
///     let response = try await app.get("/")
///     #expect(response.status == .ok)
///     await app.shutdown()
/// }
/// ```
public struct TestApp<App: RoostApp>: Sendable {

    private let plug: Plug
    private let ownedClient: SpectroClient?

    /// The PubSub adapter injected into the pipeline, if configured.
    /// Use this in tests to subscribe or broadcast directly.
    public let pubSub: (any RoostPubSub)?

    /// The channel registry shared across all `TestApp<App>` instances.
    /// Use `app.channels.broadcast(topic:event:payload:)` to push server-initiated events.
    public let channels: ChannelRegistry

    /// Provides access to the presence list for this app's channel registry.
    public var presence: PresenceAccessor { PresenceAccessor(registry: channels) }

    /// Socket assigns injected into every `ChannelSocket` created via `connectSocket`.
    public let socketAssigns: SocketAssigns

    /// The key-value store behind `conn.store`, for setting up or checking values.
    ///
    /// It's a fresh `MemoryKeyValueStore` for each test app unless the
    /// initializer receives one, whatever `RoostApp.store` says, so
    /// tests don't share state or need a server.
    public let store: any KeyValueStore

    /// The in-memory job queue for this test app.
    /// Use `app.jobs.pending(_:)`, `app.jobs.discarded(_:)`, and `app.jobs.failedAttempts(_:)` to inspect state.
    public let jobs: InMemoryJobQueue

    /// The channel router from the app (for creating `TestChannelSocket` instances).
    private let channelRouter: ChannelRouter

    /// Creates a test harness for the given app type.
    ///
    /// Builds the same pipeline as `main()` but skips server boot.
    ///
    /// - Parameters:
    ///   - type: The `RoostApp` type to test.
    ///   - database: Override database config. Pass `.some(nil)` for no DB, or omit to use the app's default.
    ///   - assigns: Socket assigns to inject into every socket created via `connectSocket(_:)`.
    ///   - runJobsInline: When `true` (default), jobs execute synchronously inside `push()`. Set to `false` to inspect the queue without executing.
    ///   - repository: A caller-owned repository, usually from `withTestRollback`. Skips creating a database client.
    ///   - store: The store behind `conn.store`. Defaults to a new `MemoryKeyValueStore`.
    public init(_ type: App.Type, database: Database?? = nil, assigns: SocketAssigns = [:], runJobsInline: Bool = true, repository: (any Repo)? = nil, store: (any KeyValueStore)? = nil) async throws {
        let app = Roost.$environmentOverride.withValue(.test) {
            let app = App()
            app.configure(for: .test)
            return app
        }

        // PubSub setup (call once to get a stable shared instance)
        let pubSubAdapter = app.pubSub
        self.pubSub = pubSubAdapter

        // Channel setup — shared registry per App.Type so cross-instance broadcasts work
        let router = app.channels
        let registry = SharedChannelRegistry.registry(
            for: ObjectIdentifier(App.self),
            router: router
        )
        self.channels = registry
        self.channelRouter = router
        self.socketAssigns = assigns

        // Job queue setup — always use an in-memory queue in tests
        let jobQueue = InMemoryJobQueue(runInline: runJobsInline)
        jobQueue.registerSchedule(app.scheduledJobs)
        self.jobs = jobQueue

        // Database setup
        var spectro: SpectroClient?
        let dbConfig = Roost.$environmentOverride.withValue(.test) { database ?? app.database }
        if let dbConfig, repository == nil {
            let client = try SpectroClient(
                hostname: dbConfig.hostname,
                port: dbConfig.port,
                username: dbConfig.username,
                password: dbConfig.password,
                database: dbConfig.database
            )
            spectro = client
            do { try await app.willStart(spectro: client) }
            catch {
                await client.shutdown()
                throw error
            }
        }

        let store = store ?? MemoryKeyValueStore()
        self.store = store
        self.ownedClient = spectro
        self.plug = Roost.$environmentOverride.withValue(.test) {
            roost_applicationPipeline(app, spectro: spectro, repository: repository, store: store,
                channels: registry, jobs: jobQueue, pubSub: pubSubAdapter)
        }
    }

    /// Closes a database client created by this harness. Injected repositories are caller-owned.
    public func shutdown() async { await ownedClient?.shutdown() }

    // MARK: - Channel Methods

    /// Creates an in-process channel socket connected to the given path.
    ///
    /// The socket is pre-loaded with the `assigns` provided at `TestApp` init time.
    /// Use the returned `TestChannelSocket` to join topics, push events, and receive broadcasts.
    public func connectSocket(_ path: String) async throws -> TestChannelSocket {
        let socket = ChannelSocket(assigns: socketAssigns, registry: channels)
        return TestChannelSocket(socket: socket, registry: channels, router: channelRouter)
    }

    // MARK: - SSE Methods

    /// Connects to an SSE endpoint, establishes the subscription, then runs `action`,
    /// and collects `count` events before disconnecting.
    ///
    /// Uses the `assigns` injected at `TestApp` init time (e.g. `currentUser`).
    /// The subscription is **guaranteed to be established before `action` runs** —
    /// safe to call `broadcaster.publish(...)` inside `action`.
    ///
    /// ```swift
    /// let events = try await app.collectSSE("/live/orders", count: 1) {
    ///     await MyApp.broadcaster.publish(event)
    /// }
    /// ```
    public func collectSSE(
        _ path: String,
        count: Int,
        timeout: Duration = .seconds(5),
        then action: @Sendable () async throws -> Void = {}
    ) async throws -> [ServerSentEvent] {
        var conn = TestConnection.build(method: .get, path: path, body: .empty, headers: HTTPFields())

        for (key, value) in socketAssigns {
            conn = conn.assign(key: key, value: value)
        }

        // Run the route — subscription is established inside the handler.
        var result = try await Roost.$environmentOverride.withValue(.test) { try await plug(conn) }
        result = result.runBeforeSend()

        guard case .stream(let bodyStream) = result.responseBody else {
            return []
        }

        // Pipe body stream into an AsyncStream so we can race with a timeout below.
        let (resultStream, resultContinuation) = AsyncStream<ServerSentEvent>.makeStream()
        let consumeTask = Task {
            do {
                for try await chunk in bodyStream {
                    if let event = ServerSentEvent.parse(chunk) {
                        resultContinuation.yield(event)
                    }
                }
            } catch { /* stream ended or task cancelled */ }
            resultContinuation.finish()
        }

        // Run caller's action (e.g. publish events) with subscription already set up.
        do {
            try await action()
        } catch {
            consumeTask.cancel()
            throw error
        }

        // Collect up to `count` events, racing against the timeout.
        let events = try await withThrowingTaskGroup(of: [ServerSentEvent].self) { group in
            group.addTask {
                var collected: [ServerSentEvent] = []
                for await event in resultStream {
                    collected.append(event)
                    if collected.count >= count { break }
                }
                return collected
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return []
            }
            let collected = (try await group.next()) ?? []
            group.cancelAll()
            return collected
        }

        consumeTask.cancel()
        return events
    }

    // MARK: - Request Methods

    /// Sends a HEAD request through the pipeline (returns headers, no body).
    public func head(
        _ path: String,
        headers: [String: String] = [:],
        assigns: [String: any Sendable] = [:],
        session: [String: String]? = nil
    ) async throws -> TestResponse {
        try await request(method: .head, path: path, headers: headers, assigns: assigns, session: session)
    }

    /// Sends a GET request through the pipeline.
    public func get(
        _ path: String,
        headers: [String: String] = [:],
        assigns: [String: any Sendable] = [:],
        session: [String: String]? = nil
    ) async throws -> TestResponse {
        try await request(method: .get, path: path, headers: headers, assigns: assigns, session: session)
    }

    /// Sends a POST request with a JSON body through the pipeline.
    public func post(
        _ path: String,
        json: any Encodable & Sendable,
        headers: [String: String] = [:],
        assigns: [String: any Sendable] = [:],
        session: [String: String]? = nil
    ) async throws -> TestResponse {
        let data = try JSONEncoder().encode(json)
        var h = headers
        h["Content-Type"] = "application/json"
        return try await request(method: .post, path: path, body: data, headers: h, assigns: assigns, session: session)
    }

    /// Sends a PUT request with a JSON body through the pipeline.
    public func put(
        _ path: String,
        json: any Encodable & Sendable,
        headers: [String: String] = [:],
        assigns: [String: any Sendable] = [:],
        session: [String: String]? = nil
    ) async throws -> TestResponse {
        let data = try JSONEncoder().encode(json)
        var h = headers
        h["Content-Type"] = "application/json"
        return try await request(method: .put, path: path, body: data, headers: h, assigns: assigns, session: session)
    }

    /// Sends a DELETE request through the pipeline.
    public func delete(
        _ path: String,
        headers: [String: String] = [:],
        assigns: [String: any Sendable] = [:],
        session: [String: String]? = nil
    ) async throws -> TestResponse {
        try await request(method: .delete, path: path, headers: headers, assigns: assigns, session: session)
    }

    /// Sends a request with the given method through the pipeline.
    public func request(
        method: HTTPRequest.Method,
        path: String,
        body: Data? = nil,
        headers: [String: String] = [:],
        assigns: [String: any Sendable] = [:],
        session: [String: String]? = nil
    ) async throws -> TestResponse {
        var fields = HTTPFields()
        for (key, value) in headers {
            if let name = HTTPField.Name(key) {
                fields[name] = value
            }
        }

        let requestBody: RequestBody = body.map { .buffered($0) } ?? .empty

        var conn = TestConnection.build(
            method: method,
            path: path,
            body: requestBody,
            headers: fields
        )

        // Inject assigns
        for (key, value) in assigns {
            conn = conn.assign(key: key, value: value)
        }

        // Inject session
        if let session {
            conn = conn.assign(TestSessionSeedKey.self, value: session)
                .assign(key: Connection.sessionKey, value: session)
        }

        // Run pipeline
        var result = try await Roost.$environmentOverride.withValue(.test) { try await plug(conn) }
        result = result.runBeforeSend()

        // Extract response
        let responseData: Data
        switch result.responseBody {
        case .empty:
            responseData = Data()
        case .buffered(let data):
            responseData = data
        case .stream:
            responseData = Data()
        default:
            throw UnsupportedResponseBody()
        }

        return TestResponse(
            status: result.response.status,
            headers: result.response.headerFields,
            body: responseData
        )
    }
}

private struct UnsupportedResponseBody: Error, CustomStringConvertible {
    var description: String { "This response body requires a streaming transport; use an HTTP integration test." }
}

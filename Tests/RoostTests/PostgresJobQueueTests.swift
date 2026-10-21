import Foundation
import Logging
import PostgresNIO
import ServiceLifecycle
import Testing

@testable import Roost

/// `POSTGRES_URL=postgres://user:password@host:port/database` runs the tests
/// that need a PostgreSQL server.
enum PostgresTestDatabase {
    static let database: Database? = ProcessInfo.processInfo.environment["POSTGRES_URL"]
        .flatMap(URLComponents.init(string:))
        .map { url in
            Database(hostname: url.host ?? "localhost", port: url.port ?? 5432, username: url.user ?? "postgres",
                     password: url.password ?? "", database: String(url.path.dropFirst()))
        }
}

/// The parameters the test jobs ran with.
private final class JobRuns: @unchecked Sendable {
    static let shared = JobRuns()
    private let lock = NSLock()
    private var values: [String] = []

    func record(_ value: String) { lock.withLock { values.append(value) } }

    func count(_ value: String) -> Int { lock.withLock { values.count(where: { $0 == value }) } }

    func wait(for value: String) async throws {
        while count(value) == 0 { try await Task.sleep(for: .milliseconds(50)) }
    }
}

private struct Greeting: RoostJob {
    struct Parameters: Codable, Sendable { let name: String }

    func execute(parameters: Parameters, context: JobContext) async throws {
        JobRuns.shared.record(parameters.name)
    }
}

private struct Flaked: Error {}

/// Fails its first attempt for each name.
private struct FlakyGreeting: RoostJob {
    struct Parameters: Codable, Sendable { let name: String }

    static var retryStrategy: RetryStrategy { .exponentialJitter(maxAttempts: 2) }

    func execute(parameters: Parameters, context: JobContext) async throws {
        JobRuns.shared.record("attempt:\(parameters.name)")
        guard JobRuns.shared.count("attempt:\(parameters.name)") > 1 else { throw Flaked() }
        JobRuns.shared.record(parameters.name)
    }
}

/// Takes a second, so the app can stop while it runs.
private struct SlowGreeting: RoostJob {
    struct Parameters: Codable, Sendable { let name: String }

    func execute(parameters: Parameters, context: JobContext) async throws {
        JobRuns.shared.record("started:\(parameters.name)")
        try await Task.sleep(for: .seconds(1))
        JobRuns.shared.record(parameters.name)
    }
}

private struct Report: RoostJob {
    struct Parameters: Codable, Sendable { let name: String }

    func execute(parameters: Parameters, context: JobContext) async throws {
        JobRuns.shared.record(parameters.name)
    }
}

private let anyDatabase = Database(hostname: "localhost", port: 1, username: "u", password: "", database: "d")

@Suite("PostgreSQL job queue")
struct PostgresJobQueueTests {
    @Test func theQueueNeedsTheAppDatabase() async throws {
        let error = await #expect(throws: RoostJobQueueError.self) {
            try await JobQueue.postgres(Greeting.self).prepare(database: nil, schedule: [])
        }
        #expect(error?.description.contains("RoostApp.database") == true)
    }

    @Test func scheduledJobsNeedACronExpression() async throws {
        let entry = schedule(Report.self, parameters: .init(name: "weekly"), every: .seconds(7 * 86_400))
        let error = await #expect(throws: RoostJobQueueError.self) {
            try await JobQueue.postgres().prepare(database: anyDatabase, schedule: [entry])
        }
        #expect(error?.description.contains("cron:") == true)
    }

    @Test func anInvalidCronExpressionStopsTheApp() async throws {
        let entry = schedule(Report.self, parameters: .init(name: "never"), cron: "every monday")
        let error = await #expect(throws: RoostJobQueueError.self) {
            try await JobQueue.postgres().prepare(database: anyDatabase, schedule: [entry])
        }
        #expect(error?.description.contains("every monday") == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func pushingBeforeTheAppRunsTheQueueFails() async throws {
        let error = await #expect(throws: RoostJobQueueError.self) {
            try await JobQueue.postgres(Greeting.self).push(Greeting.self, parameters: .init(name: "early"))
        }
        #expect(error?.description.contains("RoostApp.jobs") == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func pushingAJobTheQueueDoesntListFails() async throws {
        let queue = JobQueue.postgres(Greeting.self)
        try await queue.prepare(database: anyDatabase, schedule: [])
        let error = await #expect(throws: RoostJobQueueError.self) {
            try await queue.push(Report.self, parameters: .init(name: "unlisted"))
        }
        #expect(error?.description.contains("JobQueue.postgres(Report.self") == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func theAppStopsWhileTheDatabaseIsUnreachable() async throws {
        let queue = JobQueue.postgres(Greeting.self)
        try await queue.prepare(database: anyDatabase, schedule: [])
        let app = ServiceGroup(services: [queue], logger: Logger(label: "test"))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await app.run() }
            try await Task.sleep(for: .milliseconds(200))
            await app.triggerGracefulShutdown()
            try await group.next()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aPushWaitingForTheDatabaseFailsWhenTheAppStops() async throws {
        let queue = JobQueue.postgres(Greeting.self)
        try await queue.prepare(database: anyDatabase, schedule: [])
        let app = ServiceGroup(services: [queue], logger: Logger(label: "test"))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await app.run() }
            let push = Task { try await queue.push(Greeting.self, parameters: .init(name: "stranded")) }
            try await Task.sleep(for: .milliseconds(200))
            await app.triggerGracefulShutdown()
            await #expect(throws: RoostJobQueueError.self) { try await push.value }
            try await group.next()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aPushFailsWhenTheDatabaseDoesntAnswer() async throws {
        let queue = JobQueue.postgres(Greeting.self)
        try await queue.prepare(database: anyDatabase, schedule: [])
        let app = ServiceGroup(services: [queue], logger: Logger(label: "test"))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await app.run() }
            let error = await #expect(throws: RoostJobQueueError.self) {
                try await queue.push(Greeting.self, parameters: .init(name: "unanswered"))
            }
            #expect(error?.description.contains("didn't answer") == true)
            await app.triggerGracefulShutdown()
            try await group.next()
        }
    }

    // MARK: - PostgreSQL

    /// Runs `queue` as the app does, on a queue name of its own.
    private func run(
        _ queue: PostgresJobQueue, schedule: [ScheduledJobEntry] = [],
        _ body: () async throws -> Void
    ) async throws {
        guard let database = PostgresTestDatabase.database else { return }
        try await queue.prepare(database: database, schedule: schedule)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await queue.run() }
            defer { group.cancelAll() }
            try await body()
        }
    }

    /// Runs `body` with a client of the test database.
    private func withClient<T: Sendable>(_ body: (PostgresClient) async throws -> T) async throws -> T {
        let base = try #require(PostgresTestDatabase.database)
        let client = PostgresClient(configuration: .init(
            host: base.hostname, port: base.port, username: base.username, password: base.password,
            database: base.database, tls: .disable))
        return try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            defer { group.cancelAll() }
            return try await body(client)
        }
    }

    /// Runs `body` with a database of its own, which it drops afterwards.
    private func withNewDatabase(_ body: (Database) async throws -> Void) async throws {
        let base = try #require(PostgresTestDatabase.database)
        let name = "roost_jobs_\(UUID().uuidString.prefix(8).lowercased())"
        try await withClient { admin in
            try await admin.query("CREATE DATABASE \(unescaped: name)")
            do {
                try await body(Database(hostname: base.hostname, port: base.port, username: base.username,
                                        password: base.password, database: name))
            } catch {
                _ = try? await admin.query("DROP DATABASE \(unescaped: name) WITH (FORCE)")
                throw error
            }
            try await admin.query("DROP DATABASE \(unescaped: name) WITH (FORCE)")
        }
    }

    @Test(.timeLimit(.minutes(1)), .enabled(if: PostgresTestDatabase.database != nil))
    func serversStartingTogetherOnANewDatabaseCreateTheTablesOnce() async throws {
        try await withNewDatabase { database in
            let servers = (0..<3).map { _ in PostgresJobQueue(jobs: [Greeting.self]) }
            for server in servers { try await server.prepare(database: database, schedule: []) }
            let name = UUID().uuidString
            try await withThrowingTaskGroup(of: Void.self) { group in
                for server in servers { group.addTask { try await server.run() } }
                defer { group.cancelAll() }
                for server in servers { try await server.push(Greeting.self, parameters: .init(name: name)) }
                while JobRuns.shared.count(name) < servers.count { try await Task.sleep(for: .milliseconds(50)) }
            }
        }
    }

    @Test(.timeLimit(.minutes(1)), .enabled(if: PostgresTestDatabase.database != nil))
    func pushedJobsRunInTheBackground() async throws {
        let queue = PostgresJobQueue(jobs: [Greeting.self], queueName: UUID().uuidString)
        let name = UUID().uuidString
        try await run(queue) {
            try await queue.push(Greeting.self, parameters: .init(name: name))
            try await JobRuns.shared.wait(for: name)
        }
    }

    @Test(.timeLimit(.minutes(1)), .enabled(if: PostgresTestDatabase.database != nil))
    func aJobRunningWhenTheAppStopsFinishesOnce() async throws {
        guard let database = PostgresTestDatabase.database else { return }
        let queueName = UUID().uuidString
        let name = UUID().uuidString
        let stopping = PostgresJobQueue(jobs: [SlowGreeting.self], queueName: queueName)
        try await stopping.prepare(database: database, schedule: [])
        let app = ServiceGroup(services: [stopping], logger: Logger(label: "test"))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await app.run() }
            try await stopping.push(SlowGreeting.self, parameters: .init(name: name))
            try await JobRuns.shared.wait(for: "started:\(name)")
            await app.triggerGracefulShutdown()
            try await group.next()
        }
        #expect(JobRuns.shared.count(name) == 1)
        // Otherwise a server would run the job again once its worker's lock expires.
        let processing = try await withClient { client in
            try await client.query("SELECT count(*) FROM swift_jobs.jobs WHERE queue_name = \(queueName) AND status = 1")
                .decode(Int.self).first(where: { _ in true })
        }
        #expect(processing == 0)
    }

    @Test(.timeLimit(.minutes(1)), .enabled(if: PostgresTestDatabase.database != nil))
    func aFailedJobRunsAgainUnderItsRetryStrategy() async throws {
        let queue = PostgresJobQueue(jobs: [FlakyGreeting.self], queueName: UUID().uuidString)
        let name = UUID().uuidString
        try await run(queue) {
            try await queue.push(FlakyGreeting.self, parameters: .init(name: name))
            try await JobRuns.shared.wait(for: name)
        }
        #expect(JobRuns.shared.count("attempt:\(name)") == 2)
    }

    @Test(.timeLimit(.minutes(1)), .enabled(if: PostgresTestDatabase.database != nil))
    func scheduledJobsCanBePushedWithoutBeingListed() async throws {
        let queue = PostgresJobQueue(jobs: [], queueName: UUID().uuidString)
        let name = UUID().uuidString
        try await run(queue, schedule: [schedule(Report.self, parameters: .init(name: "daily"), cron: "0 8 * * *")]) {
            try await queue.push(Report.self, parameters: .init(name: name))
            try await JobRuns.shared.wait(for: name)
        }
    }
}

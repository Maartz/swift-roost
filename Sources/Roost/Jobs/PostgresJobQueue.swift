import Foundation
import Jobs
import JobsPostgres
import Logging
import PostgresMigrations
import PostgresNIO
import ServiceLifecycle
import Spectro

/// Background jobs in the app's PostgreSQL database, through swift-jobs.
///
/// Jobs survive restarts, and every server that shares the database runs
/// them. Return the queue from ``RoostApp/jobs``, with every job type the app
/// pushes, so the app runs its workers:
///
/// ```swift
/// var jobs: (any RoostJobQueue)? {
///     JobQueue.postgres(WelcomeEmailJob.self, ReceiptJob.self)
/// }
/// ```
///
/// A server runs only the job types its queue lists or ``RoostApp/scheduledJobs``
/// schedules, so list every type a server may find in the database. Pushing a
/// type the queue doesn't list throws.
///
/// At startup the queue creates its tables in the `swift_jobs` schema of
/// ``RoostApp/database``. Each server then runs up to 16 jobs at a time. A job
/// that throws, or runs longer than its ``RoostJob/timeout``, runs again after a
/// backoff while its ``RoostJob/retryStrategy`` allows. When the app stops,
/// running jobs have 30 seconds to finish.
///
/// Scheduled jobs need a cron expression, in the server's time zone. One server
/// at a time pushes them.
public final class PostgresJobQueue: RoostJobQueue, Service, @unchecked Sendable {
    private struct Prepared {
        let client: PostgresClient
        let migrations: DatabaseMigrations
        let queue: Jobs.JobQueue<JobsPostgres.PostgresJobQueue>
        let schedule: JobSchedule
        let names: Set<String>
        let logger: Logger
    }

    private let jobs: [any RoostJob.Type]
    private let queueName: String
    private let lock = NSLock()
    private var prepared: Prepared?
    private var _spectro: SpectroClient?
    /// Whether pushes can reach the queue's tables: `nil` until ``run()`` has
    /// created them, or has failed or stopped.
    private var readiness: Result<Void, any Error>?

    init(jobs: [any RoostJob.Type], queueName: String = "default") {
        self.jobs = jobs
        self.queueName = queueName
    }

    /// The app's database client, for ``JobContext/spectro``.
    var spectro: SpectroClient? {
        get { lock.withLock { _spectro } }
        set { lock.withLock { _spectro = newValue } }
    }

    /// Registers the jobs and schedule on a client for `database`, before the
    /// server starts. Nothing connects until ``run()``.
    ///
    /// - Throws: ``RoostJobQueueError`` without a database, or for a scheduled
    ///   job without a valid cron expression.
    func prepare(
        database: Database?, schedule entries: [ScheduledJobEntry], logger: Logger = Logger(label: "roost.jobs")
    ) async throws {
        guard let database else {
            throw RoostJobQueueError("PostgresJobQueue keeps jobs in the app's database: return one from RoostApp.database")
        }
        let schedule = JobSchedule(try entries.map { entry in
            guard let cron = entry.cron else {
                throw RoostJobQueueError(
                    "PostgresJobQueue schedules jobs with cron expressions: schedule \(entry.jobTypeName) with cron: instead of every:")
            }
            do { return entry.element(try .crontab(cron)) }
            catch { throw RoostJobQueueError("\(entry.jobTypeName) has an invalid cron expression \"\(cron)\": \(error)") }
        })
        let client = PostgresClient(
            configuration: .init(host: database.hostname, port: database.port, username: database.username,
                                 password: database.password, database: database.database, tls: .disable),
            backgroundLogger: logger
        )
        let migrations = DatabaseMigrations()
        let queue = await Jobs.JobQueue(
            .postgres(client: client, migrations: migrations, configuration: .init(queueName: queueName), logger: logger),
            logger: logger
        )
        var names = Set<String>()
        for type in jobs + entries.compactMap({ $0.jobType as? any RoostJob.Type }) where names.insert(type.name).inserted {
            register(type, on: queue)
        }
        lock.withLock {
            prepared = Prepared(client: client, migrations: migrations, queue: queue, schedule: schedule,
                                names: names, logger: logger)
        }
    }

    private func register<J: RoostJob>(_ type: J.Type, on queue: Jobs.JobQueue<JobsPostgres.PostgresJobQueue>) {
        queue.registerJob(
            name: JobName(J.name, parameters: J.Parameters.self),
            retryStrategy: J.retryStrategy.jobs,
            timeout: J.timeout
        ) { parameters, context in
            do {
                try await J().execute(parameters: parameters, context: JobContext(spectro: self.spectro, queue: self))
            } catch {
                // swift-jobs logs failures at debug level only.
                context.logger.error("Job failed", metadata: [
                    "attempt": .stringConvertible(context.attempt), "error": .string(String(describing: error)),
                ])
                throw error
            }
        }
    }

    public func push<J: RoostJob>(_ jobType: J.Type, parameters: J.Parameters) async throws {
        guard let prepared = lock.withLock({ prepared }) else {
            throw RoostJobQueueError("PostgresJobQueue isn't running: return it from RoostApp.jobs")
        }
        guard prepared.names.contains(J.name) else {
            throw RoostJobQueueError("PostgresJobQueue runs only the jobs it lists: JobQueue.postgres(\(J.name).self, …)")
        }
        try await ready()
        try await prepared.queue.push(JobName(J.name, parameters: J.Parameters.self), parameters: parameters)
    }

    public func run() async throws {
        guard let prepared = lock.withLock({ prepared }) else {
            throw RoostJobQueueError("PostgresJobQueue isn't running: return it from RoostApp.jobs")
        }
        // PostgresClient closes when graceful shutdown starts, but running jobs
        // still record their results, so it runs detached and closes after the workers.
        let connections = Task.detached { await prepared.client.run() }
        do {
            try await work(prepared)
        } catch {
            settle(.failure(error))
            connections.cancel()
            await connections.value
            throw error
        }
        settle(.failure(RoostJobQueueError("PostgresJobQueue has stopped with the app")))
        connections.cancel()
        await connections.value
    }

    private func work(_ prepared: Prepared) async throws {
        do {
            try await cancelWhenGracefulShutdown { try await self.migrate(prepared) }
        } catch where Task.isShuttingDownGracefully {
            return  // The app stopped before the database answered.
        }
        settle(.success(()))
        var services: [any Service] = [prepared.queue.processor()]
        // A scheduler without jobs would return at once and stop the workers.
        if !prepared.schedule.isEmpty {
            services.append(await prepared.schedule.scheduler(
                on: prepared.queue, options: .init(schedulerLock: .acquire(every: .seconds(60), for: .seconds(90)))))
        }
        try await ServiceGroup(services: services, logger: prepared.logger).run()
    }

    /// Waits until ``run()`` has created the queue's tables, for 10 seconds at
    /// most: the server waits for requests before the queue hears the app stop.
    // ponytail: polls while the app starts; keep continuations if pushes pile up there.
    private func ready() async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            if let readiness = lock.withLock({ readiness }) { return try readiness.get() }
            guard .now < deadline else {
                throw RoostJobQueueError("PostgresJobQueue isn't ready: its database didn't answer within 10 seconds")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func settle(_ result: Result<Void, any Error>) {
        lock.withLock { readiness = result }
    }

    /// Applies the queue's migrations. Servers that start together, such as on
    /// a first deploy, take turns, because postgres-migrations doesn't lock.
    private func migrate(_ prepared: Prepared) async throws {
        try await prepared.client.withConnection { connection in
            // A session lock, released when the connection closes too. The key is Roost's own.
            try await connection.query("SELECT pg_advisory_lock(\(Self.migrationLock))", logger: prepared.logger)
            do {
                try await prepared.migrations.apply(
                    client: prepared.client, groups: [.jobQueue], logger: prepared.logger, dryRun: false)
            } catch {
                _ = try? await connection.query("SELECT pg_advisory_unlock(\(Self.migrationLock))", logger: prepared.logger)
                throw error
            }
            try await connection.query("SELECT pg_advisory_unlock(\(Self.migrationLock))", logger: prepared.logger)
        }
    }

    private static let migrationLock: Int64 = 0x526F_6F73_744A_6F62  // "RoostJob"
}

/// A job queue the app can't use as configured, such as one without a
/// database, or a push of a job type the queue doesn't list.
public struct RoostJobQueueError: Error, Sendable, CustomStringConvertible {
    public let description: String

    init(_ description: String) { self.description = description }
}

extension RetryStrategy {
    fileprivate var jobs: any JobRetryStrategy {
        switch self {
        case .none: .dontRetry as NoRetryJobRetryStrategy
        case .exponentialJitter(let maxAttempts): .exponentialJitter(maxAttempts: maxAttempts) as ExponentialJitterJobRetryStrategy
        }
    }
}

import Foundation
import Jobs
import Nexus
import Spectro

// MARK: - Public inspection types (for tests)

/// A job that was enqueued but not yet executed.
public struct PendingJob<J: RoostJob>: Sendable {
    public let parameters: J.Parameters
}

/// A job that was discarded after exhausting all retry attempts.
public struct DiscardedJob<J: RoostJob>: Sendable {
    public let parameters: J.Parameters
}

// MARK: - ScheduledJobEntry

/// A registered recurring job (cron or interval-based).
public struct ScheduledJobEntry: @unchecked Sendable {
    /// The Swift type name of the job, used for identity matching.
    public let jobTypeName: String
    /// Cron expression, e.g. `"0 8 * * 1-5"`.
    public let cron: String?
    /// Fixed interval between executions.
    public let interval: Duration?

    let execute: @Sendable (JobContext) async throws -> Void
    /// The job on a swift-jobs schedule, for ``PostgresJobQueue``.
    let element: @Sendable (Schedule) -> JobSchedule.Element

    /// A type-erased reference to the job's type, for test comparison.
    public var jobType: Any.Type { _jobType }
    private let _jobType: Any.Type

    /// Returns `true` when this entry corresponds to `type`.
    public func isJob<J: RoostJob>(_ type: J.Type) -> Bool {
        jobTypeName == String(describing: J.self)
    }

    init<J: RoostJob>(_ type: J.Type, parameters: J.Parameters, cron: String?, interval: Duration?) {
        self.jobTypeName = String(describing: J.self)
        self.cron = cron
        self.interval = interval
        self.execute = { ctx in try await J().execute(parameters: parameters, context: ctx) }
        self.element = { JobSchedule.Element(JobName(J.name, parameters: J.Parameters.self), parameters: parameters, schedule: $0) }
        self._jobType = J.self
    }
}

// MARK: - RoostJobQueue

/// The minimal protocol required of every job queue driver.
public protocol RoostJobQueue: Sendable {
    /// Enqueues a job for execution.
    func push<J: RoostJob>(_ jobType: J.Type, parameters: J.Parameters) async throws
}

// MARK: - Internal type-erased storage

private struct AnyJobRecord: Sendable {
    let jobTypeName: String
    let parametersData: Data
}

// MARK: - InMemoryJobQueue

/// In-process job queue for development and testing.
///
/// When `runInline` is `true` (the default in test mode) jobs execute
/// synchronously inside `push()`—no background workers needed.
/// When `false`, jobs are stored and can be inspected via `pending(_:)`.
public final class InMemoryJobQueue: RoostJobQueue, @unchecked Sendable {

    // MARK: - Configuration

    public var runInline: Bool
    public var spectro: SpectroClient?
    /// Arbitrary test fixtures passed into `JobContext.userInfo` for every execution.
    public var userInfo: [String: any Sendable] = [:]

    // MARK: - State

    private let lock = NSLock()
    private var pendingJobs: [AnyJobRecord] = []
    private var discardedJobs: [String: [Data]] = [:]
    private var _failedAttempts: [String: Int] = [:]
    private var _scheduledEntries: [ScheduledJobEntry] = []

    // MARK: - Init

    public init(runInline: Bool) {
        self.runInline = runInline
    }

    // MARK: - RoostJobQueue

    public func push<J: RoostJob>(_ jobType: J.Type, parameters: J.Parameters) async throws {
        let typeName = String(describing: J.self)
        let data     = try JSONEncoder().encode(parameters)
        let ctx      = makeContext()

        if runInline {
            let job         = J()
            let maxAttempts = J.retryStrategy.maxAttempts

            for attempt in 1...maxAttempts {
                do {
                    try await job.execute(parameters: parameters, context: ctx)
                    return
                } catch {
                    lock.withLock { _failedAttempts[typeName, default: 0] += 1 }
                    if attempt == maxAttempts {
                        lock.withLock { discardedJobs[typeName, default: []].append(data) }
                    }
                }
            }
        } else {
            lock.withLock { pendingJobs.append(AnyJobRecord(jobTypeName: typeName, parametersData: data)) }
        }
    }

    // MARK: - Inspection

    /// Returns all pending (not-yet-executed) jobs of the given type.
    public func pending<J: RoostJob>(_ jobType: J.Type) -> [PendingJob<J>] {
        let typeName = String(describing: J.self)
        return lock.withLock {
            pendingJobs
                .filter { $0.jobTypeName == typeName }
                .compactMap { record in
                    guard let params = try? JSONDecoder().decode(J.Parameters.self, from: record.parametersData)
                    else { return nil }
                    return PendingJob(parameters: params)
                }
        }
    }

    /// Returns all discarded jobs (exhausted retries) of the given type.
    public func discarded<J: RoostJob>(_ jobType: J.Type) -> [DiscardedJob<J>] {
        let typeName = String(describing: J.self)
        return lock.withLock {
            (discardedJobs[typeName] ?? []).compactMap { data in
                guard let params = try? JSONDecoder().decode(J.Parameters.self, from: data)
                else { return nil }
                return DiscardedJob(parameters: params)
            }
        }
    }

    /// Total number of failed (retried) execution attempts for the given type.
    public func failedAttempts<J: RoostJob>(_ jobType: J.Type) -> Int {
        let typeName = String(describing: J.self)
        return lock.withLock { _failedAttempts[typeName] ?? 0 }
    }

    // MARK: - Scheduled jobs

    /// The registered recurring schedule for this queue.
    public var schedule: [ScheduledJobEntry] {
        lock.withLock { _scheduledEntries }
    }

    /// Immediately executes the scheduled job of the given type.
    public func triggerScheduled<J: RoostJob>(_ jobType: J.Type) async throws {
        let typeName = String(describing: J.self)
        let entry    = lock.withLock { _scheduledEntries.first { $0.jobTypeName == typeName } }
        guard let entry else { return }
        try await entry.execute(makeContext())
    }

    // MARK: - Internal

    public func registerSchedule(_ entries: [ScheduledJobEntry]) {
        lock.withLock { _scheduledEntries = entries }
    }

    func reset() {
        lock.withLock {
            pendingJobs      = []
            discardedJobs    = [:]
            _failedAttempts  = [:]
        }
    }

    private func makeContext() -> JobContext {
        JobContext(spectro: spectro, queue: self, userInfo: userInfo)
    }
}

// MARK: - Factory

/// Namespace for job queue factory methods.
public enum JobQueue {
    /// Creates an in-process queue. `runInline: true` executes jobs immediately (default for tests).
    public static func inMemory(runInline: Bool = true) -> InMemoryJobQueue {
        InMemoryJobQueue(runInline: runInline)
    }

    /// A queue in the app's PostgreSQL database that runs `jobs` in the
    /// background. See ``PostgresJobQueue``.
    public static func postgres(_ jobs: any RoostJob.Type...) -> PostgresJobQueue {
        PostgresJobQueue(jobs: jobs)
    }

    /// A stub that stops the process.
    @available(*, deprecated, message: "This stub stops the process. Use JobQueue.postgres(_:) with the app's job types. Roost 3.0 removes it.")
    public static func postgres(spectro: SpectroClient) -> any RoostJobQueue {
        fatalError("Postgres job queue not yet implemented — use JobQueue.inMemory() for tests")
    }
}

// MARK: - Scheduled Job DSL

/// Schedules a job to run on a cron expression (e.g. `"0 8 * * 1-5"`).
public func schedule<J: RoostJob>(
    _ type: J.Type,
    parameters: J.Parameters,
    cron: String
) -> ScheduledJobEntry {
    ScheduledJobEntry(type, parameters: parameters, cron: cron, interval: nil)
}

/// Schedules a job to run at a fixed interval (e.g. `.seconds(7 * 24 * 3600)`).
public func schedule<J: RoostJob>(
    _ type: J.Type,
    parameters: J.Parameters,
    every interval: Duration
) -> ScheduledJobEntry {
    ScheduledJobEntry(type, parameters: parameters, cron: nil, interval: interval)
}

// MARK: - Connection injection

public enum JobQueueKey: AssignKey {
    public typealias Value = any RoostJobQueue
}

extension Connection {
    /// The job queue injected into this connection's pipeline.
    public var jobs: any RoostJobQueue {
        guard let queue = self[JobQueueKey.self] else {
            fatalError("No job queue configured. Set `jobs` in your RoostApp.")
        }
        return queue
    }
}

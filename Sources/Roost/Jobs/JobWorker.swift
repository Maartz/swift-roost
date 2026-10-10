import Foundation
import Spectro

// MARK: - JobWorker

/// Background worker actor that polls for and executes pending jobs.
///
/// Manages concurrent job execution via `Task` groups, retry with
/// exponential backoff, and graceful shutdown.
///
/// > Note: This is a stub implementation. The worker is wired into the
/// lifecycle but the polling/execution loop is not yet connected.
@available(*, deprecated, message: "JobWorker is a stub: it never runs a job. Roost 3.0 removes it from the stable API until it is implemented.")
public actor JobWorker {
    private let store: PostgresJobStore
    private let spectro: SpectroClient
    private let queue: any RoostJobQueue
    private var isRunning = false
    private var task: Task<Void, Error>?

    // MARK: - Init

    /// Creates a new background job worker.
    /// - Parameters:
    ///   - store: The Postgres job store to poll for pending jobs.
    ///   - spectro: Database client injected into job context.
    ///   - queue: Job queue facade for enqueueing follow-up work.
    public init(
        store: PostgresJobStore,
        spectro: SpectroClient,
        queue: any RoostJobQueue
    ) {
        self.store = store
        self.spectro = spectro
        self.queue = queue
    }

    // MARK: - Lifecycle

    /// Starts the background worker polling loop.
    /// - Parameter pollInterval: How often to check for new jobs. Defaults to 5 seconds.
    public func start(pollInterval: Duration = .seconds(5)) {
        guard !isRunning else { return }
        isRunning = true

        task = Task {
            while !Task.isCancelled {
                if let record = try? await store.claimNextJob() {
                    await executeJob(record)
                }
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    /// Stops the background worker, allowing the current job to finish.
    public func stop() {
        isRunning = false
        task?.cancel()
        task = nil
    }

    // MARK: - Internal

    private func executeJob(_ record: JobRecord) async {
        // TODO: Decode job type, look up RoostJob protocol witness,
        // execute with retry + exponential backoff, then markCompleted/markFailed
        //
        // let job = try lookupJob(record.jobType)
        // let params = try JSONDecoder().decode(job.parametersType, from: record.parameters)
        // let context = JobContext(spectro: spectro, queue: queue)
        //
        // for attempt in 1...job.maxAttempts {
        //     do {
        //         try await job.execute(params, context)
        //         try? await store.markCompleted(id: record.id)
        //         return
        //     } catch {
        //         try? await store.markFailed(id: record.id, error: error.localizedDescription)
        //     }
        // }
    }
}

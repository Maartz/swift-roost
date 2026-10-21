import Foundation
import Spectro

// MARK: - PostgresJobStore

/// Postgres-backed job store for durable job execution.
///
/// Stores jobs in a `roost_jobs` table with atomic claim semantics
/// via `SELECT ... FOR UPDATE SKIP LOCKED` to support concurrent workers.
///
/// > Note: This is a stub implementation. The `JobQueue.postgres(spectro:)`
/// factory already returns a fatal error. When a Postgres client is available,
/// this store will provide:
/// - Auto-creation of the `roost_jobs` table on first use
/// - Atomic job claiming with `FOR UPDATE SKIP LOCKED`
/// - Exponential backoff retry with jitter
/// - Cleanup of expired completed jobs
@available(*, deprecated, message: "PostgresJobStore is a stub: its methods store and return nothing. Use PostgresJobQueue. Roost 3.0 removes it.")
public actor PostgresJobStore {
    private let client: SpectroClient

    /// Creates a new Postgres-backed job store.
    /// - Parameter client: The Spectro database client to use.
    public init(client: SpectroClient) {
        self.client = client
    }

    // MARK: - Table Setup

    /// Creates the `roost_jobs` table if it does not already exist.
    /// Call once during application startup.
    public func createTableIfNotExists() async throws {
        // TODO: Implement table creation with Spectro
        // CREATE TABLE IF NOT EXISTS roost_jobs (
        //   id BIGSERIAL PRIMARY KEY,
        //   job_type TEXT NOT NULL,
        //   parameters JSONB NOT NULL,
        //   status TEXT NOT NULL DEFAULT 'pending',
        //   max_attempts INT NOT NULL DEFAULT 1,
        //   attempt_count INT NOT NULL DEFAULT 0,
        //   error TEXT,
        //   created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        //   updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        //   scheduled_at TIMESTAMPTZ,
        //   completed_at TIMESTAMPTZ
        // )
    }

    // MARK: - Job Operations

    /// Enqueues a job by inserting a row in 'pending' state.
    public func enqueue<J: RoostJob>(
        _ jobType: J.Type,
        parameters: J.Parameters
    ) async throws {
        // TODO: INSERT INTO roost_jobs (job_type, parameters, max_attempts)
        // VALUES (typeName, jsonb, maxAttempts)
    }

    /// Atomically claims the next pending job, marking it 'running'.
    /// Uses `SELECT ... FOR UPDATE SKIP LOCKED` for safe concurrent workers.
    public func claimNextJob() async throws -> JobRecord? {
        // TODO: SELECT id, job_type, parameters FROM roost_jobs
        // WHERE status = 'pending' AND (scheduled_at IS NULL OR scheduled_at <= now())
        // ORDER BY created_at ASC LIMIT 1 FOR UPDATE SKIP LOCKED
        // Then UPDATE SET status = 'running', updated_at = now()
        return nil
    }

    /// Marks a job as completed.
    public func markCompleted(id: Int64) async throws {
        // TODO: UPDATE roost_jobs
        // SET status = 'completed', updated_at = now(), completed_at = now()
        // WHERE id = id
    }

    /// Marks a job as failed, incrementing attempt count.
    /// If max_attempts reached, sets status to 'failed'.
    public func markFailed(id: Int64, error: String) async throws {
        // TODO: UPDATE roost_jobs
        // SET attempt_count = attempt_count + 1, error = error, updated_at = now(),
        //     status = CASE WHEN attempt_count + 1 >= max_attempts THEN 'failed' ELSE 'pending' END
        // WHERE id = id
    }

    /// Removes completed/failed jobs older than the given age.
    public func cleanup(olderThan: Duration = .seconds(7 * 86_400)) async throws {
        // TODO: DELETE FROM roost_jobs
        // WHERE status IN ('completed', 'failed')
        //   AND completed_at < now() - interval
    }
}

// MARK: - JobRecord

/// A job fetched from the database, ready for execution.
public struct JobRecord: Sendable {
    public let id: Int64
    public let jobType: String
    public let parameters: Data

    public init(id: Int64, jobType: String, parameters: Data) {
        self.id = id
        self.jobType = jobType
        self.parameters = parameters
    }
}

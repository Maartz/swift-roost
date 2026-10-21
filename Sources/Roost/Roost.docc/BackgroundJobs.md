# Background jobs

Run work after a request returns, again after a failure, or on a schedule.

## Overview

A job is a type that conforms to ``RoostJob``. Its parameters are `Codable`,
because the queue stores them until a worker runs the job:

```swift
struct WelcomeEmailJob: RoostJob {
    struct Parameters: Codable, Sendable {
        let userID: UUID
    }

    static var retryStrategy: RetryStrategy { .exponentialJitter(maxAttempts: 3) }

    func execute(parameters: Parameters, context: JobContext) async throws {
        guard let repo = context.spectro?.repository() else { return }
        // Load the user and send the email.
    }
}
```

``JobContext`` carries the app's database client and the queue, for follow-up
jobs. A job runs with a fresh value from `init()`, so it keeps no state between
runs.

## Run jobs from PostgreSQL

Return a ``PostgresJobQueue`` from ``RoostApp/jobs``, with every job type the
app pushes:

```swift
var jobs: (any RoostJobQueue)? {
    JobQueue.postgres(WelcomeEmailJob.self, ReceiptJob.self)
}
```

Push a job from a controller, a context, or another job:

```swift
try await conn.jobs.push(WelcomeEmailJob.self, parameters: .init(userID: user.id))
```

`push` returns once the job is stored. Jobs survive restarts, and every server
that shares ``RoostApp/database`` runs them, up to 16 at a time per server.
The queue stores jobs through its own connection, not the request's
transaction: push a job after the transaction that creates its data commits,
or the job may run before that data exists.

A job that throws, or runs longer than its ``RoostJob/timeout``, runs again
after a backoff while its ``RoostJob/retryStrategy`` allows, and its failures
are logged. When the app stops, running jobs have 30 seconds to finish.

`JobQueue.inMemory()` keeps nothing: it runs each job inside `push`, in the
request that pushes it, and doesn't run scheduled jobs.

## Schedule recurring jobs

Return the schedule from ``RoostApp/scheduledJobs``. ``PostgresJobQueue``
accepts cron expressions, in the server's time zone:

```swift
var scheduledJobs: [ScheduledJobEntry] {
    [schedule(DailyReportJob.self, parameters: .init(), cron: "0 8 * * 1-5")]
}
```

One server at a time pushes scheduled jobs, and any server may run them. A
schedule with `every:` or an invalid cron expression stops the app at startup.
A scheduled job type doesn't need to be listed in `JobQueue.postgres(…)`.

## Deploy

At startup the queue creates its tables in a `swift_jobs` schema and records
them in a `_hb_pg_migrations` table, so the database user needs permission to
create them. Servers that start together take turns.

A server runs only the job types it lists. A job of a type the server doesn't
list, or whose parameters it can't decode, fails. During a rolling deploy, add a
new job type in one release and push it in the next, and keep parameter changes
decodable by both versions, such as with new optional properties.

## Test jobs

`TestApp` always uses an in-memory queue, so app tests don't need the job tables.
Jobs run inside `push` by default; pass `runJobsInline: false` to inspect
`app.jobs.pending(_:)` instead, and call `app.jobs.triggerScheduled(_:)` to run a
scheduled job.

## Topics

- ``RoostJob``
- ``JobContext``
- ``RetryStrategy``
- ``PostgresJobQueue``
- ``InMemoryJobQueue``
- ``RoostJobQueueError``
- ``ScheduledJobEntry``

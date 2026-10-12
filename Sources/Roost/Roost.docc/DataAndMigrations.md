# Data, contexts, and migrations

Use Spectro repositories for domain operations and Spectro migrations for schema changes.

## Overview

Configure a database on ``RoostApp``:

```swift
let database: Database? = Database.postgres(database: "reading_room")
```

With no `DB_NAME` override, that becomes `reading_room_dev` in development,
`reading_room_test` in tests, and `reading_room` in production. Set `DB_NAME`
explicitly for deployment. See <doc:ConfigurationAndDeployment> for the full
configuration precedence.

### Give contexts a repository

Generated contexts store `any Repo`. Request handlers obtain it with
`conn.repo()`, which honors a repository injected by the test harness before
falling back to the application's Spectro client.

`conn.spectro` accesses the application's concrete client. Prefer `conn.repo()`
in contexts and routes that should support transaction-owned repositories in
tests. A database must be configured, or a repository injected, before calling
these helpers.

### Scope a context to its owner

A ``ScopedRepo`` limits a repository to the records one owner holds. Build it
once, when the context is created, and every method of the context inherits the
ownership rule:

```swift
struct BookmarksContext: Sendable {
    let bookmarks: ScopedRepo<Bookmark, UUID>

    init(repo: any Repo, reader: ReaderScope) {
        bookmarks = repo.scoped(\Bookmark.userId, to: reader.userID)
    }

    func listBookmarks() async throws -> [Bookmark] {
        try await bookmarks.query().orderBy(\.createdAt, .asc).all()
    }

    func updateBookmark(id: UUID, with changes: Changes<Bookmark>) async throws -> Bookmark {
        try await bookmarks.update(id, Bookmark.validate(changes))
    }

    func deleteBookmark(id: UUID) async throws {
        try await bookmarks.delete(id)
    }
}
```

This snippet assumes the `Bookmark` generated in <doc:CLIAndGenerators> and the
`ReaderScope` from <doc:AuthenticationAndSessions>. `query()` and `get(_:)` only
return the owner's records. `update(_:_:)` and `delete(_:)` match the primary
key and the owner in one SQL statement, so a method doesn't read a record
before changing it. Another owner's record and a missing one are both a 404.
`insert(_:)` sets the owner itself, so a request can't choose it.

Contexts generated before Roost 2.2 pass the owner to each method and keep the
ownership predicate in every query. That style still works; a scoped
repository removes the need to repeat it.

### Write typed changes

``Changes`` holds the values to write to a model, each named by a key path, so
the compiler checks the property name and the value's type:

```swift
let changes = Changes<Bookmark>().setting(\.read, to: true)
try await repo.update(Bookmark.self, id: id, changes)
```

Writes through ``Changes`` set an `updatedAt` timestamp to the current time
unless the changes set it themselves. Spectro's `update(_:id:changes:)` takes a
dictionary keyed by property name instead; a misspelled key fails only when the
query runs.

### Permit and validate at the domain boundary

Declare the fields a request may set once, as a ``Permitted`` value, and decode
them from both HTML forms and JSON bodies with
``Nexus/Connection/permit(_:decoder:)-(Permitted<Model>,_)``:

```swift
extension Bookmark {
    static let editable = Permitted<Bookmark>(\.title, \.url, \.note, \.read)

    static func validate(_ changes: Changes<Bookmark>) async throws -> Changes<Bookmark> {
        try await changes.trimmingWhitespace().validated(using: [
            .required(\.title),
            .length(\.title, max: 160),
            .length(\.note, max: 2000),
        ])
    }
}

// In a controller action:
let bookmark = try await context.createBookmark(conn.permit(Bookmark.editable))
```

Each field decodes as its property's type. Fields the list leaves out, such as
`userId`, are ignored. The key path rules of ``ValidatorRule`` name each field
after the schema property, and ``ValidationErrors`` uses that name, which is
also the form field's name. A rule checks only the fields the changes set,
except `required`, which treats a missing field as blank. Adding a column then
means changing the schema, the permitted list, and any rule for the field.

For input that isn't a model, such as a login form, decode a struct with
``Nexus/Connection/permit(_:decoder:)-(T.Type,_)``, and check it with a
``Changeset`` whose rules name fields with strings:

```swift
var changeset = Changeset(data: credentials)
await changeset.validate(using: [.email("email") { $0.email }])
let valid = try changeset.requireValid()
```

Normalize input deliberately before validation. Never accept an ownership field
from the submitted body in place of the authenticated identity.

### Write a migration

``RoostMigrator`` delegates execution, status, and rollback to Spectro's
migration manager. It is not a separate migration engine.

SQL files live in `Sources/Migrations/`. The CLI generates ordered filenames
so referenced tables can be created before their dependents. Each file has an
up and a down section:

```sql
-- migrate:up
CREATE TABLE "reading_tags" (
    "id" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    "name" TEXT NOT NULL
);

-- migrate:down
DROP TABLE "reading_tags";
```

Create an empty migration with:

```sh
roost gen migration create_reading_tags
```

Fill in both sections of the generated file. Spectro applies each migration
transactionally and tracks its version in `schema_migrations`.

### Write migrations in Swift

An app can declare its history as a `MigrationRegistry` from Spectro's
`SpectroMigrations` module, which `import Roost` includes. List the SQL
history and the Swift migrations in ``RoostApp/migrations``:

```swift
var migrations: MigrationRegistry? {
    MigrationRegistry {
        SQLMigrations(bundle: .module, directory: "SQL")
        AddReadAtToBookmarks()
    }
}
```

Move the SQL files into the app target, unchanged, and bundle them with
`resources: [.copy("Migrations/SQL")]` in `Package.swift`. Their IDs stay the
same, so a database that already applied them doesn't run them again. Then
declare new changes in Swift:

```swift
struct AddReadAtToBookmarks: Migration {
    static let id = "1791704720_add_read_at_to_bookmarks"

    var change: MigrationPlan {
        AlterTable("bookmarks") { table in
            table.add("read_at", .timestamptz)
        }
        CreateIndex("bookmarks_user_id_read_at_index", on: "bookmarks", columns: ["user_id", "read_at"])
    }
}
```

Spectro derives the rollback: this one drops the index, then the column.
Use `Reversible` for a change it can't invert, `SQL(up:down:)` for anything
outside the typed operations, and `Irreversible` for a change that loses data.
[Spectro's migration guide](https://github.com/roost-framework/Spectro/blob/2.3.0/docs/MIGRATIONS.md)
covers every operation.

With a registry, `App migrate` runs Spectro's migration command, and
`roost migrate up`, `down`, and `status` keep working. `App migrate plan`
prints the SQL of every migration without connecting to a database;
`plan --direction down` prints the rollbacks. `down` rolls back only the
newest migration unless you pass `--step`. `roost gen migration` still writes
SQL to `Sources/Migrations/`, which a registry doesn't read: write Swift
migrations by hand for now.

### Run against the app's configuration

From the generated app root:

```sh
roost migrate up
roost migrate status
ROOST_ENV=test roost migrate up
```

The CLI invokes the app's migration command, so the CLI and server use the same
database configuration. Create the development and test databases first.
Starting a server does not apply migrations automatically.

For a disposable development database, `roost migrate down` rolls back
the latest migration. It executes the file's down section, which may remove
data; inspect that SQL before using it.

### Run the release binary

A compiled application also accepts the migration command:

```sh
ROOST_ENV=prod DB_NAME=reading_room .build/release/ReadingRoom migrate up
```

Supply the target database credentials in the environment. Run from the
application directory, or ship `Sources/Migrations/` beside the executable.
See <doc:ConfigurationAndDeployment> and <doc:TestingYourApp>.

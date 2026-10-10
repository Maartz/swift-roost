import Foundation
import Nexus
import NexusTest
import Testing

@testable import Roost

// MARK: - Fixtures

@Schema("notes")
struct Note {
    @ID var id: UUID
    @ForeignKey var ownerId: UUID
    @Column var title: String
    @Column var body: String?
    @Column var pinned: Bool
    @Column var rating: Int
    @Timestamp var updatedAt: Date
}

extension Note {
    static let editable = Permitted<Note>(\.title, \.body, \.pinned, \.rating)

    /// Writable, but not a column.
    var shoutedTitle: String {
        get { title.uppercased() }
        set { title = newValue }
    }
}

@Schema("archived_notes")
struct ArchivedNote {
    @ID var id: UUID
    @ForeignKey var ownerId: UUID
    @Column var title: String
    @SoftDelete var deletedAt: Date?
}

private func isNotFound(_ error: any Error) -> Bool {
    (error as? NexusHTTPError)?.status == .notFound
}

// MARK: - Changes

@Suite("Changes")
struct ChangesTests {

    @Test("Fields are set and read by key path, in the order first set")
    func setAndRead() {
        var changes = Changes<Note>()
        #expect(changes.isEmpty)
        changes.set(\.title, to: "Draft")
        changes.set(\.body, to: nil)
        changes.set(\.title, to: "Final")

        #expect(changes.fields == ["title", "body"])
        #expect(changes[\.title] == "Final")
        #expect(changes.contains(\.body))
        #expect(changes[\.body] == .some(nil))
        #expect(!changes.contains(\.rating))
        #expect(changes[\.rating] == nil)
    }

    @Test("apply writes every change to a record")
    func apply() {
        var note = Note()
        note.rating = 2
        Changes<Note>().setting(\.title, to: "Plan").setting(\.body, to: "Notes").setting(\.pinned, to: true)
            .apply(to: &note)
        #expect(note.title == "Plan")
        #expect(note.body == "Notes")
        #expect(note.pinned)
        #expect(note.rating == 2)
    }

    @Test("trimmingWhitespace trims String and String? values")
    func trimming() {
        var note = Note()
        let changes = Changes<Note>()
            .setting(\.title, to: "  Plan \n")
            .setting(\.body, to: " text ")
            .setting(\.rating, to: 3)
            .trimmingWhitespace()
        changes.apply(to: &note)
        #expect(note.title == "Plan")
        #expect(note.body == "text")
        #expect(changes[\.body] == "text")
        #expect(note.rating == 3)
        #expect(Changes<Note>().setting(\.body, to: nil).trimmingWhitespace()[\.body] == .some(nil))
    }

    @Test("Writes set updatedAt unless the changes do")
    func touchesUpdatedAt() async throws {
        let metadata = await SchemaRegistry.shared.register(Note.self)
        let touched = try Changes<Note>().setting(\.title, to: "Plan").columnValues(touching: metadata)
        #expect(touched.map(\.field) == ["title", "updatedAt"])

        let date = Date(timeIntervalSince1970: 0)
        let explicit = try Changes<Note>().setting(\.updatedAt, to: date).columnValues(touching: metadata)
        #expect(explicit.map(\.field) == ["updatedAt"])
        #expect(explicit.first?.value as? Date == date)

        let archived = await SchemaRegistry.shared.register(ArchivedNote.self)
        #expect(try Changes<ArchivedNote>().setting(\.title, to: "Old").columnValues(touching: archived).map(\.field) == ["title"])
    }

    @Test("A property that isn't a column applies in memory but can't be written")
    func unmappedProperty() async throws {
        let changes = Changes<Note>().setting(\.shoutedTitle, to: "Loud")
        var note = Note()
        changes.apply(to: &note)
        #expect(note.title == "Loud")
        #expect(throws: SpectroError.self) { try changes.columnValues() }
        await #expect(throws: SpectroError.self) {
            try await RecordingRepo().update(Note.self, id: UUID(), changes)
        }
    }

    @Test("Repo.update sends Spectro the property names")
    func typedUpdate() async throws {
        let repo = RecordingRepo()
        _ = try await repo.update(Note.self, id: UUID(), Changes().setting(\.pinned, to: true))
        let sent = try #require(repo.updates.first)
        #expect(Set(sent.keys) == ["pinned", "updatedAt"])
        #expect(sent["pinned"] as? Bool == true)
    }
}

// MARK: - Permitted

@Suite("Permitted")
struct PermittedTests {

    @Test("Form values decode the permitted fields and ignore the rest")
    func formFields() throws {
        let changes = try FormValues([
            "title": "Plan", "body": "", "pinned": "on", "rating": "3", "ownerId": UUID().uuidString,
        ]).decode(Note.editable)
        #expect(changes.fields == ["title", "body", "pinned", "rating"])
        #expect(changes[\.title] == "Plan")
        #expect(changes[\.body] == .some(nil))
        #expect(changes[\.pinned] == true)
        #expect(changes[\.rating] == 3)
        #expect(!changes.contains(\.ownerId))
        #expect(Note.editable.names == ["title", "body", "pinned", "rating"])
    }

    @Test("An unchecked checkbox is false and a missing optional field is nil")
    func formDefaults() throws {
        let changes = try FormValues(["title": "Plan", "rating": "1"]).decode(Note.editable)
        #expect(changes[\.pinned] == false)
        #expect(changes[\.body] == .some(nil))
    }

    @Test("Every missing or invalid form field is reported")
    func formErrors() {
        #expect {
            try FormValues(["rating": "many"]).decode(Note.editable)
        } throws: { error in
            let errors = error as? ValidationErrors
            return errors?["title"] == ["can't be blank"] && errors?["rating"] == ["is invalid"]
        }
    }

    @Test("conn.permit reads query, form, and path parameters")
    func connectionForm() throws {
        let conn = TestConnection.build(method: .post, path: "/notes?title=Query&rating=1")
            .assign(BodyParamsKey.self, value: ["title": "Form", "pinned": "true"])
        let changes = try conn.permit(Note.editable)
        #expect(changes[\.title] == "Form")
        #expect(changes[\.rating] == 1)
        #expect(changes[\.pinned] == true)
    }

    @Test("conn.permit decodes JSON bodies; a missing optional is nil")
    func connectionJSON() throws {
        let conn = TestConnection.buildJSON(json: #"{"title": "Plan", "pinned": true, "rating": 4, "ownerId": "x"}"#)
        let changes = try conn.permit(Note.editable)
        #expect(changes[\.title] == "Plan")
        #expect(changes[\.body] == .some(nil))
        #expect(changes[\.pinned] == true)
        #expect(changes[\.rating] == 4)
        #expect(!changes.contains(\.ownerId))
    }

    @Test("JSON errors name every field; a body that isn't an object is a bad request")
    func connectionJSONErrors() {
        #expect {
            try TestConnection.buildJSON(json: #"{"title": 5, "body": null, "rating": "x"}"#).permit(Note.editable)
        } throws: { error in
            let errors = error as? ValidationErrors
            return errors?["title"] == ["is invalid"] && errors?["pinned"] == ["can't be blank"]
                && errors?["rating"] == ["is invalid"] && errors?["body"] == []
        }
        #expect {
            try TestConnection.buildJSON(json: "[1]").permit(Note.editable)
        } throws: { error in
            (error as? NexusHTTPError)?.status == .badRequest
        }
    }
}

// MARK: - Validation

@Suite("Changes validation")
struct ChangesValidationTests {

    private let rules: [ValidatorRule<Changes<Note>>] = [
        .required(\.title),
        .length(\.title, max: 5),
        .length(\.body, max: 3),
        .number(\.rating, lessThanOrEqual: 5),
        .custom(\.rating) { $0 == 0 ? "can't be zero" : nil },
    ]

    @Test("Rules name each field after the schema property")
    func fieldNames() async {
        let changes = Changes<Note>().setting(\.title, to: "Too long").setting(\.body, to: "Long").setting(\.rating, to: 0)
        await #expect {
            try await changes.validated(using: rules)
        } throws: { error in
            let errors = error as? ValidationErrors
            return errors?["title"] == ["should be at most 5 characters"]
                && errors?["body"] == ["should be at most 3 characters"]
                && errors?["rating"] == ["can't be zero"]
        }
    }

    @Test("Rules skip fields the changes don't set, except required")
    func absentFields() async throws {
        let partial = Changes<Note>().setting(\.pinned, to: true)
        await #expect {
            try await partial.validated(using: rules)
        } throws: { error in
            (error as? ValidationErrors)?.fieldErrors == ["title": ["can't be blank"]]
        }
        let valid = try await partial.validated(using: [.length(\.title, max: 5), .number(\.rating, lessThan: 2)])
        #expect(valid[\.pinned] == true)
    }

    @Test("A nil optional passes its rules unless required")
    func optionalFields() async throws {
        let empty = Changes<Note>().setting(\.body, to: nil)
        _ = try await empty.validated(using: [.length(\.body, min: 2), .format(\.body, pattern: "^x")])
        await #expect(throws: ValidationErrors.self) { try await empty.validated(using: [.required(\.body)]) }
    }
}

// MARK: - ScopedRepo

@Suite("ScopedRepo")
struct ScopedRepoTests {

    let owner = UUID()
    let id = UUID()

    @Test("update matches the primary key and the owner in one statement")
    func updateStatement() async throws {
        let repo = RecordingRepo()
        let notes = repo.scoped(\Note.ownerId, to: owner)
        await #expect(performing: {
            try await notes.update(id, Changes().setting(\.title, to: "Plan").setting(\.ownerId, to: UUID()))
        }, throws: isNotFound)

        let statement = try #require(repo.statements.first)
        #expect(statement.sql == #"UPDATE "notes" SET "title" = $1, "updated_at" = $2 WHERE "id" = $3 AND "owner_id" = $4 RETURNING *"#)
        #expect(statement.parameters.count == 4)
        #expect(statement.parameters[0].string == "Plan")
        #expect(statement.parameters[2].uuid == id)
        #expect(statement.parameters[3].uuid == owner)
    }

    @Test("delete matches the primary key and the owner, and soft deletes when the schema does")
    func deleteStatements() async throws {
        let repo = RecordingRepo()
        await #expect(performing: { try await repo.scoped(\Note.ownerId, to: owner).delete(id) }, throws: isNotFound)
        await #expect(performing: { try await repo.scoped(\ArchivedNote.ownerId, to: owner).delete(id) }, throws: isNotFound)
        await #expect(performing: {
            try await repo.scoped(\ArchivedNote.ownerId, to: owner).update(id, Changes().setting(\.title, to: "Old"))
        }, throws: isNotFound)

        #expect(repo.statements.map(\.sql) == [
            #"DELETE FROM "notes" WHERE "id" = $1 AND "owner_id" = $2 RETURNING "id""#,
            #"UPDATE "archived_notes" SET "deleted_at" = NOW() WHERE "id" = $1 AND "owner_id" = $2 AND "deleted_at" IS NULL RETURNING "id""#,
            #"UPDATE "archived_notes" SET "title" = $1 WHERE "id" = $2 AND "owner_id" = $3 AND "deleted_at" IS NULL RETURNING *"#,
        ])
        #expect(repo.statements[0].parameters.map(\.uuid) == [id, owner])
    }

    @Test("get returns only the owner's record")
    func get() async throws {
        var note = Note()
        note.ownerId = owner
        note.title = "Mine"
        #expect(try await RecordingRepo(stored: note).scoped(\Note.ownerId, to: owner).get(id).title == "Mine")
        await #expect(performing: { try await RecordingRepo(stored: note).scoped(\Note.ownerId, to: UUID()).get(id) },
                      throws: isNotFound)
        await #expect(performing: { try await RecordingRepo().scoped(\Note.ownerId, to: owner).get(id) },
                      throws: isNotFound)
    }

    @Test("insert assigns the owner, whatever the changes say")
    func insert() async throws {
        let repo = RecordingRepo()
        let created = try await repo.scoped(\Note.ownerId, to: owner)
            .insert(Changes().setting(\.title, to: "Plan").setting(\.ownerId, to: UUID()))
        #expect(created.ownerId == owner)
        #expect(created.title == "Plan")
        #expect((repo.inserted.first as? Note)?.ownerId == owner)
    }
}

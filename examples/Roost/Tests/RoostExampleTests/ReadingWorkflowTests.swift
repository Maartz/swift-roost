import Roost
import RoostTest
import Testing
@testable import RoostExample

private func csrf(_ response: TestResponse) throws -> String {
    let pattern = #/name="_csrf_token" value="([^"]+)"/#
    return String(try #require(response.text.firstMatch(of: pattern)).output.1)
}

/// A bookmark as the JSON API receives it.
private func linkJSON(url: String = "https://swift.org") throws -> Data {
    try JSONSerialization.data(withJSONObject: ["title": "API link", "url": url, "note": "", "read": false])
}

private func link(_ title: String) -> Changes<Bookmark> {
    Changes().setting(\.title, to: title).setting(\.url, to: "https://swift.org").setting(\.note, to: "").setting(\.read, to: false)
}

private func register(_ browser: TestBrowser<RoostExample>) async throws {
    let token = try csrf(await browser.get("/auth/register"))
    let response = try await browser.post("/auth/register", form: [
        "email": "reader-\(UUID())@example.test", "password": "a-test-password", "_csrf_token": token,
    ])
    #expect(response.status == .seeOther)
}

@Test("A reader can save, validate, finish, edit and remove links; another reader cannot access them")
func readingWorkflow() async throws {
    let app = try await TestApp(RoostExample.self)
    do {
        let alice = app.browser()
        let bob = app.browser()
        try await register(alice)
        try await register(bob)
        let token = try csrf(await alice.get("/bookmarks/new"))
        let bobToken = try csrf(await bob.get("/bookmarks/new"))

        // The same context validation serves HTML forms and JSON requests.
        let invalid = try await alice.post("/bookmarks", form: [
            "title": "Keep this title", "url": "javascript:alert(1)", "note": "Keep my note", "_csrf_token": token,
        ])
        #expect(invalid.status == .unprocessableContent)
        #expect(invalid.text.contains("Enter a complete http:// or https:// link"))
        #expect(invalid.text.contains("Keep this title"))
        #expect(invalid.text.contains("Keep my note"))
        let payload = try linkJSON()
        let blocked = try await alice.request(method: .post, path: "/api/bookmarks", body: payload,
            headers: ["Content-Type": "application/json"])
        #expect(blocked.status == .forbidden)
        let invalidJSON = try await alice.request(method: .post, path: "/api/bookmarks",
            body: linkJSON(url: "javascript:alert(1)"),
            headers: ["Content-Type": "application/json", "X-CSRF-Token": token])
        #expect(invalidJSON.status == .unprocessableContent)

        let saved = try await alice.post("/bookmarks", form: [
            "title": "Swift <notes> & ideas", "url": "https://swift.org", "note": "A note for later", "_csrf_token": token,
        ])
        #expect(saved.status == .seeOther)
        let location = try #require(saved.headers[.location])
        let id = try #require(location.split(separator: "/").last)
        let apiPath = "/api/bookmarks/\(id)"
        let detail = try await alice.get(location)
        #expect(detail.text.contains("Swift &lt;notes&gt; &amp; ideas"))
        #expect(detail.text.contains("Link saved"))
        #expect(try await !alice.get(location).text.contains("Link saved"))

        let finished = try await alice.post(location + "/read", form: ["read": "true", "_csrf_token": token])
        #expect(finished.status == .seeOther)
        let changed = try await alice.get(apiPath)
        #expect(changed.json["read"] as? Bool == true)
        #expect(changed.json["note"] as? String == "A note for later")
        #expect(try await !alice.get("/bookmarks").text.contains("Swift &lt;notes&gt;"))
        #expect(try await alice.get("/bookmarks?filter=finished").text.contains("Swift &lt;notes&gt;"))

        // HTML method override and JSON share the same owner-scoped context.
        #expect(try await bob.get(location).status == .notFound)
        #expect(try await bob.get(apiPath).status == .notFound)
        let foreignEdit = try await bob.post(location, form: [
            "_method": "PUT", "title": "Stolen", "url": "https://example.com", "note": "", "_csrf_token": bobToken,
        ])
        #expect(foreignEdit.status == .notFound)
        #expect(try await bob.post(location + "/read", form: ["read": "false", "_csrf_token": bobToken]).status == .notFound)
        #expect(try await bob.post(location, form: ["_method": "DELETE", "_csrf_token": bobToken]).status == .notFound)
        #expect(try await bob.request(method: .delete, path: apiPath, headers: ["X-CSRF-Token": bobToken]).status == .notFound)
        let foreignJSON = try await bob.request(method: .put, path: apiPath, body: payload,
            headers: ["Content-Type": "application/json", "X-CSRF-Token": bobToken])
        #expect(foreignJSON.status == .notFound)
        #expect(try await alice.get(apiPath).json["read"] as? Bool == true)

        let edited = try await alice.post(location, form: [
            "_method": "PUT", "title": "Edited title", "url": "https://swift.org/documentation/", "note": "", "_csrf_token": token,
        ])
        #expect(edited.status == .seeOther)
        #expect(try await alice.get(apiPath).json["read"] as? Bool == false)
        let apiCreated = try await alice.request(method: .post, path: "/api/bookmarks", body: payload,
            headers: ["Content-Type": "application/json", "X-CSRF-Token": token])
        #expect(apiCreated.status == .created)
        #expect(try await bob.get("/api/bookmarks").text == "[]")
        #expect(try await alice.post(location, form: ["_method": "DELETE", "_csrf_token": token]).status == .seeOther)
        #expect(try await alice.get(apiPath).status == .notFound)
        #expect(try await alice.post("/auth/logout", form: ["_method": "DELETE", "_csrf_token": token]).status == .seeOther)
        #expect(try await alice.get("/bookmarks").status == .seeOther)
    } catch {
        await app.shutdown()
        throw error
    }
    await app.shutdown()
}

@Test("A context and the HTTP pipeline see the same transaction; fixtures roll back")
func contextRollback() async throws {
    let config = Database.postgres(database: "roost")
    let client = try SpectroClient(hostname: config.hostname, port: config.port,
        username: config.username, password: config.password, database: config.database)
    let repo = client.repository()
    let email = "rollback-\(UUID())@example.test"
    do {
        try await withTestRollback(repository: repo) { transaction in
            var fixture = User()
            fixture.email = email
            fixture.hashedPassword = "unused by this test"
            let user = try await transaction.insert(fixture)
            let token = Auth.generateToken()
            var session = UserToken()
            session.userId = user.id
            session.token = Auth.sha256Hex(token)
            session.context = "session"
            _ = try await transaction.insert(session)
            let context = BookmarksContext(repo: transaction, reader: ReaderScope(userID: user.id))
            let bookmark = try await context.createBookmark(link("Inside the transaction"))
            let app = try await TestApp(RoostExample.self, repository: transaction)
            let page = try await app.get("/bookmarks/\(bookmark.id)", session: ["_roost_auth_token": token])
            #expect(page.status == .ok)
            #expect(page.text.contains("Inside the transaction"))
            try await context.setRead(id: bookmark.id, read: true)
            #expect(try await context.getBookmark(id: bookmark.id).read)

            // Scoped writes are single statements, so they check the owner inside the transaction too.
            let stranger = BookmarksContext(repo: transaction, reader: ReaderScope(userID: UUID()))
            await #expect(throws: NexusHTTPError.self) { try await stranger.setRead(id: bookmark.id, read: false) }
            await #expect(throws: NexusHTTPError.self) { try await stranger.deleteBookmark(id: bookmark.id) }
            #expect(try await context.getBookmark(id: bookmark.id).read)
        }
        #expect(try await repo.query(User.self).where { $0.email == email }.first() == nil)
    } catch {
        await client.shutdown()
        throw error
    }
    await client.shutdown()
}

@Test("An OR condition on a scoped query stays inside the owner's records")
func scopedQueryWithOr() async throws {
    let config = Database.postgres(database: "roost")
    let client = try SpectroClient(hostname: config.hostname, port: config.port,
        username: config.username, password: config.password, database: config.database)
    let repo = client.repository()
    do {
        try await withTestRollback(repository: repo) { transaction in
            var readers: [User] = []
            for name in ["alice", "bob"] {
                var fixture = User()
                fixture.email = "\(name)-\(UUID())@example.test"
                fixture.hashedPassword = "unused by this test"
                readers.append(try await transaction.insert(fixture))
            }
            for reader in readers {
                _ = try await transaction.scoped(\Bookmark.userId, to: reader.id)
                    .insert(link("Read by \(reader.email)").setting(\.read, to: true))
            }
            // Spectro before 2.3.1 joined clauses without parentheses: owner AND title OR read.
            let found = try await transaction.scoped(\Bookmark.userId, to: readers[0].id).query()
                .where { $0.title == "nothing" || $0.read == true }
                .all()
            #expect(found.count == 1)
            #expect(found.allSatisfy { $0.userId == readers[0].id })
        }
    } catch {
        await client.shutdown()
        throw error
    }
    await client.shutdown()
}

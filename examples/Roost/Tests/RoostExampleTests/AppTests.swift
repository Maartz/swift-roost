import Testing
import RoostTest
import Roost
@testable import RoostExample

@Test("Visitors are guided to login and can open the registration form without a database")
func publicPages() async throws {
    let app = try await TestApp(RoostExample.self, database: .some(nil))
    let home = try await app.get("/")
    #expect(home.status == .seeOther)
    #expect(home.headers[.location] == "/auth/login")
    let form = try await app.get("/auth/register")
    #expect(form.status == .ok)
    #expect(form.text.contains("Create your account"))
    #expect(form.text.contains("_csrf_token"))
    #expect(form.text.contains("<title>Register · Roost</title>"))
    #expect(form.text.contains("site-footer"))
    let login = try await app.get("/auth/login")
    #expect(login.status == .ok)
    #expect(login.text.contains("Welcome back"))
    #expect(login.text.contains("_csrf_token"))
}

@Test("Typed auth views preserve form inputs, escaping, and optional errors")
func authTemplateViews() async throws {
    let email = "reader\"<example>@test"
    let token = "csrf\"<token>"
    let error = "<Invalid input>"
    let request = HTTPRequest(method: .get, scheme: "https", authority: "example.test", path: "/")
    let conn = try await roost_csrfProtection()(Connection(request: request)
        .assign(key: Connection.sessionKey, value: ["_csrf_token": token]))
    func rendered<V: ESWView>(_ view: V) throws -> String where V.Output == String {
        let response = try conn.render(view)
        if case .buffered(let data) = response.responseBody { return String(decoding: data, as: UTF8.self) }
        return ""
    }
    for html in [
        try rendered(RegisterView(email: email, error: error)),
        try rendered(LoginView(email: email, error: error)),
    ] {
        #expect(html.contains("value=\"reader&quot;&lt;example&gt;@test\""))
        #expect(html.contains("value=\"csrf&quot;&lt;token&gt;\""))
        #expect(html.contains("role=\"alert\">&lt;Invalid input&gt;</p>"))
        #expect(!html.contains("<%!"))
    }
    #expect(try !rendered(RegisterView()).contains("role=\"alert\""))
    #expect(try !rendered(LoginView()).contains("role=\"alert\""))
}

@Test("Bookmark views share form protection and prepare editable values")
func bookmarkTemplateViews() async throws {
    var bookmark = Bookmark()
    bookmark.title = "A <good> read"
    bookmark.url = "https://example.test/read"
    bookmark.note = "Save this"
    bookmark.read = false
    let request = HTTPRequest(method: .get, scheme: "https", authority: "example.test", path: "/")
    let conn = try await roost_csrfProtection()(Connection(request: request))
    func rendered<V: ESWView>(_ view: V) throws -> String where V.Output == String {
        if case .buffered(let data) = try conn.render(view).responseBody { return String(decoding: data, as: UTF8.self) }
        return ""
    }
    let edit = BookmarkEditView(bookmark: bookmark)
    #expect(edit.values["title"] == bookmark.title)
    #expect(edit.values["read"] == "false")
    let editHTML = try rendered(edit)
    #expect(editHTML.contains("<label for=\"title\">Title</label>"))
    #expect(editHTML.contains("name=\"_method\" value=\"PUT\""))
    #expect(editHTML.contains("A &lt;good&gt; read"))
    #expect(try rendered(BookmarkNewView()).contains(conn.csrfToken))
    #expect(try rendered(BookmarkShowView(bookmark: bookmark)).contains("name=\"_method\" value=\"DELETE\""))
    #expect(try rendered(BookmarksIndexView(bookmarks: [bookmark])).contains(conn.csrfToken))
    #expect(BookmarksIndexView(bookmarks: [bookmark], filter: .finished).visible.isEmpty)
    #expect(BookmarkShowView(bookmark: bookmark).status == "Saved for later")
    var finished = bookmark
    finished.read = true
    #expect(BookmarkShowView(bookmark: finished).status == "Finished reading")
    finished.readAt = Date(timeIntervalSince1970: 1_791_704_720)
    #expect(BookmarkShowView(bookmark: finished).status.hasPrefix("Finished "))
    #expect(BookmarkShowView(bookmark: finished).status != "Finished reading")
    let retry = BookmarkEditView(bookmark: bookmark, values: ["title": "Unsubmitted value"])
    #expect(retry.values["title"] == "Unsubmitted value")
}

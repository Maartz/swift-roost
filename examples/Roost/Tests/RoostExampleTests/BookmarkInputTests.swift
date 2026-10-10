import Roost
import Testing
@testable import RoostExample

private func link(title: String = "Example", url: String = "https://swift.org") -> Changes<Bookmark> {
    Changes().setting(\.title, to: title).setting(\.url, to: url).setting(\.note, to: "").setting(\.read, to: false)
}

@Test("Form input is trimmed, notes are optional, and an unchecked box becomes false")
func bookmarkValidForm() async throws {
    let changes = try await Bookmark.validate(FormValues([
        "title": "  Swift guide  ", "url": " https://swift.org/documentation/ ", "note": "",
    ]).decode(Bookmark.editable))
    #expect(changes[\.title] == "Swift guide")
    #expect(changes[\.url] == "https://swift.org/documentation/")
    #expect(changes[\.note] == "")
    #expect(changes[\.read] == false)
}

@Test("A form can't choose the bookmark's owner")
func ownerIsNotPermitted() throws {
    let changes = try FormValues([
        "title": "Mine", "url": "https://swift.org", "note": "", "userId": UUID().uuidString,
    ]).decode(Bookmark.editable)
    #expect(!changes.contains(\.userId))
}

@Test("A saved link must be a complete web URL", arguments: [
    "javascript:alert(1)", "file:///tmp/notes", "https://", "not-a-link",
    "https://user:password@example.com/", "https://exa mple.com/",
])
func rejectsInvalidURLs(url: String) async throws {
    do {
        _ = try await Bookmark.validate(link(url: url))
        Issue.record("Accepted an invalid URL")
    } catch let errors as ValidationErrors {
        #expect(!errors["url"].isEmpty)
    }
}

@Test("Whitespace-only titles cannot be saved")
func rejectsEmptyTitle() async throws {
    do {
        _ = try await Bookmark.validate(link(title: "  "))
        Issue.record("Accepted an empty title")
    } catch let errors as ValidationErrors {
        #expect(!errors["title"].isEmpty)
    }
}

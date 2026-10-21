import Foundation
import Nexus
import NexusRouter
import Testing

@testable import Roost
@testable import RoostTest

// MARK: - Fixture: RoomChannel

private struct RoomChannel: Channel {
    func join(topic: String, payload: ChannelPayload, socket: ChannelSocket) async throws -> ChannelPayload {
        guard let userID = socket.assigns["userID"] as? UUID else {
            throw ChannelError.unauthorized("Must be authenticated")
        }
        let userName = socket.assigns["userName"] as? String ?? "Anonymous"
        try await Presence.track(socket, topic: topic, key: userID.uuidString, meta: [
            "name": userName,
            "online_at": Date().timeIntervalSince1970,
        ])
        return [:]
    }

    func handle(event: String, payload: ChannelPayload, socket: ChannelSocket) async throws {
        guard event == "away", let userID = socket.assigns["userID"] as? UUID else { return }
        await Presence.untrack(socket, topic: socket.topic, key: userID.uuidString)
    }

    // Leaving untracks the socket's presence without help.
    func leave(topic: String, payload: ChannelPayload, socket: ChannelSocket) async {}
}

/// The metas of `key` in a `presence_state` payload, or in the `joins` or
/// `leaves` of a `presence_diff`, as phoenix.js's `Presence` reads them.
private func metas(_ key: String, in entries: Any?) -> [ChannelPayload] {
    ((entries as? ChannelPayload)?[key] as? ChannelPayload)?["metas"] as? [ChannelPayload] ?? []
}

// MARK: - Fixture: ChatApp

private struct ChatApp: RoostApp {
    var channels: ChannelRouter {
        ChannelRouter { on("room:*", RoomChannel.self) }
    }

    @RouteBuilder var routes: [Route] {
        // TestApp.connectSocket(_:) connects in process, without an HTTP route.
        GET("/") { conn in conn.text("ok") }
    }
}

// MARK: - Tests

@Suite("Presence Integration", .serialized, .timeLimit(.minutes(1)))
struct PresenceTests {

    // MARK: Track and List

    @Suite("Track and List")
    struct TrackAndList {

        @Test("Tracked socket appears in Presence.list")
        func trackedSocketAppears() async throws {
            let userID = UUID()
            let app    = try await TestApp(ChatApp.self, assigns: ["userID": userID, "userName": "Alice"])
            let socket = try await app.connectSocket("/socket")
            _ = try await socket.join("room:lobby", payload: [:])

            let entries = await app.presence.list("room:lobby")

            #expect(entries.count == 1)
            #expect(entries[0].key == userID.uuidString)
            #expect(entries[0].metas[0]["name"] as? String == "Alice")
        }

        @Test("Multiple users appear as separate entries")
        func multipleUsersTracked() async throws {
            let aliceID = UUID()
            let bobID   = UUID()

            let appA = try await TestApp(ChatApp.self, assigns: ["userID": aliceID, "userName": "Alice"])
            let appB = try await TestApp(ChatApp.self, assigns: ["userID": bobID,   "userName": "Bob"])

            let alice = try await appA.connectSocket("/socket")
            let bob   = try await appB.connectSocket("/socket")

            _ = try await alice.join("room:lobby", payload: [:])
            _ = try await bob.join("room:lobby", payload: [:])

            let entries = await appA.presence.list("room:lobby")
            #expect(entries.count == 2)

            let keys = entries.map(\.key)
            #expect(keys.contains(aliceID.uuidString))
            #expect(keys.contains(bobID.uuidString))
        }

        @Test("A tracked socket receives presence_state with everyone present")
        func trackedSocketReceivesState() async throws {
            let aliceID = UUID()
            let bobID   = UUID()
            let appA  = try await TestApp(ChatApp.self, assigns: ["userID": aliceID, "userName": "Alice"])
            let alice = try await appA.connectSocket("/socket")
            _ = try await alice.join("room:lobby", payload: [:])

            let appB  = try await TestApp(ChatApp.self, assigns: ["userID": bobID, "userName": "Bob"])
            let bob   = try await appB.connectSocket("/socket")
            _ = try await bob.join("room:lobby", payload: [:])

            let state = try await bob.receive(event: "presence_state")
            #expect(metas(aliceID.uuidString, in: state).first?["name"] as? String == "Alice")
            #expect(metas(bobID.uuidString, in: state).first?["name"] as? String == "Bob")
            #expect(metas(bobID.uuidString, in: state).first?["phx_ref"] is String)
        }
    }

    // MARK: Presence Diffs

    @Suite("Presence Diffs")
    struct PresenceDiffs {

        @Test("Existing subscribers receive presence_diff when a new user joins")
        func joinDiffBroadcast() async throws {
            let bobID = UUID()
            let appA  = try await TestApp(ChatApp.self, assigns: ["userID": UUID(), "userName": "Alice"])
            let alice = try await appA.connectSocket("/socket")
            _ = try await alice.join("room:lobby", payload: [:])

            let appB = try await TestApp(ChatApp.self, assigns: ["userID": bobID, "userName": "Bob"])
            let bob  = try await appB.connectSocket("/socket")
            _ = try await bob.join("room:lobby", payload: [:])

            // Alice should receive a diff telling her Bob joined
            let diff  = try await alice.receive(event: "presence_diff")
            let joins = metas(bobID.uuidString, in: diff["joins"])
            #expect(joins.first?["name"] as? String == "Bob", "Alice should receive a joins diff for Bob")
            #expect(joins.first?["phx_ref"] is String)
            #expect((diff["leaves"] as? ChannelPayload)?.isEmpty == true)
        }

        @Test("Existing subscribers receive presence_diff when a user leaves")
        func leaveDiffBroadcast() async throws {
            let bobID = UUID()
            let appA  = try await TestApp(ChatApp.self, assigns: ["userID": UUID(), "userName": "Alice"])
            let appB  = try await TestApp(ChatApp.self, assigns: ["userID": bobID,  "userName": "Bob"])

            let alice = try await appA.connectSocket("/socket")
            let bob   = try await appB.connectSocket("/socket")

            _ = try await alice.join("room:lobby", payload: [:])
            _ = try await bob.join("room:lobby", payload: [:])

            let joined = try await alice.receive(event: "presence_diff")
            let ref = metas(bobID.uuidString, in: joined["joins"]).first?["phx_ref"] as? String

            _ = try await bob.leave("room:lobby")

            let diff   = try await alice.receive(event: "presence_diff")
            let leaves = metas(bobID.uuidString, in: diff["leaves"])
            #expect(ref != nil && leaves.first?["phx_ref"] as? String == ref, "Alice should receive a leaves diff for Bob")
        }

        @Test("Untracked user disappears from Presence.list")
        func untrackedUserDisappears() async throws {
            let bobID = UUID()
            let appA  = try await TestApp(ChatApp.self, assigns: ["userID": UUID(),  "userName": "Alice"])
            let appB  = try await TestApp(ChatApp.self, assigns: ["userID": bobID,   "userName": "Bob"])

            let alice = try await appA.connectSocket("/socket")
            let bob   = try await appB.connectSocket("/socket")

            _ = try await alice.join("room:lobby", payload: [:])
            _ = try await bob.join("room:lobby", payload: [:])

            _ = try await bob.leave("room:lobby")

            let entries = await appA.presence.list("room:lobby")
            #expect(entries.count == 1)
            #expect(entries[0].key != bobID.uuidString)
        }

        @Test("Presence.untrack removes a key while the socket stays")
        func untrackWhileJoined() async throws {
            let bobID = UUID()
            let appA  = try await TestApp(ChatApp.self, assigns: ["userID": UUID(), "userName": "Alice"])
            let appB  = try await TestApp(ChatApp.self, assigns: ["userID": bobID,  "userName": "Bob"])

            let alice = try await appA.connectSocket("/socket")
            let bob   = try await appB.connectSocket("/socket")

            _ = try await alice.join("room:lobby", payload: [:])
            _ = try await bob.join("room:lobby", payload: [:])
            _ = try await alice.receive(event: "presence_diff")

            try await bob.push(event: "away")

            let diff = try await alice.receive(event: "presence_diff")
            #expect(metas(bobID.uuidString, in: diff["leaves"]).count == 1)
            #expect(!(await appA.presence.list("room:lobby")).contains { $0.key == bobID.uuidString })
            _ = try await bob.leave("room:lobby")
            #expect(alice.receivedEvents(named: "presence_diff").isEmpty, "Bob left nothing to untrack")
        }
    }

    // MARK: Multi-tab

    @Suite("Multi-tab")
    struct MultiTab {

        @Test("Same user joining twice stores two metas under the same key")
        func twoTabsSameUser() async throws {
            let userID  = UUID()
            let appTab1 = try await TestApp(ChatApp.self, assigns: ["userID": userID, "userName": "Alice"])
            let appTab2 = try await TestApp(ChatApp.self, assigns: ["userID": userID, "userName": "Alice"])

            let tab1 = try await appTab1.connectSocket("/socket")
            let tab2 = try await appTab2.connectSocket("/socket")

            _ = try await tab1.join("room:lobby", payload: [:])
            _ = try await tab2.join("room:lobby", payload: [:])

            let entries    = await appTab1.presence.list("room:lobby")
            let aliceEntry = entries.first { $0.key == userID.uuidString }

            #expect(entries.count == 1, "Still one key for Alice")
            #expect(aliceEntry?.metas.count == 2, "Two metas for two tabs")
        }

        @Test("User disappears from list only when all tabs have left")
        func disappearsWhenAllTabsLeave() async throws {
            let userID  = UUID()
            let appTab1 = try await TestApp(ChatApp.self, assigns: ["userID": userID, "userName": "Alice"])
            let appTab2 = try await TestApp(ChatApp.self, assigns: ["userID": userID, "userName": "Alice"])

            let tab1 = try await appTab1.connectSocket("/socket")
            let tab2 = try await appTab2.connectSocket("/socket")

            _ = try await tab1.join("room:lobby", payload: [:])
            _ = try await tab2.join("room:lobby", payload: [:])

            _ = try await tab1.leave("room:lobby")

            var entries = await appTab1.presence.list("room:lobby")
            #expect(entries.count == 1, "Alice is still present via tab2")

            _ = try await tab2.leave("room:lobby")

            entries = await appTab1.presence.list("room:lobby")
            #expect(entries.isEmpty, "Alice fully gone after both tabs left")
        }
    }
}

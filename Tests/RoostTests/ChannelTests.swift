import Foundation
import Nexus
import NexusRouter
import Testing

@testable import Roost
@testable import RoostTest

// MARK: - Fixture: RoomChannel

private struct RoomChannel: Channel {
    static var intercepts: [String] { ["new_message"] }

    func join(topic: String, payload: ChannelPayload, socket: ChannelSocket) async throws -> ChannelPayload {
        guard let userID = socket.assigns["userID"] as? UUID else {
            throw ChannelError.unauthorized("Must be authenticated")
        }
        try await Presence.track(socket, topic: topic, key: userID.uuidString, meta: [
            "name": socket.assigns["userName"] as? String ?? "Anonymous",
            "online_at": Date().timeIntervalSince1970,
        ])
        return ["room": topic]
    }

    func handle(event: String, payload: ChannelPayload, socket: ChannelSocket) async throws {
        switch event {
        case "new_msg":
            let body = payload["body"] as? String ?? ""
            try await socket.broadcast(event: "new_message", payload: [
                "body": body,
                "from": socket.assigns["userName"] as? String ?? "Unknown",
            ])
        case "typing":
            try await socket.broadcastFrom(event: "user_typing", payload: [
                "user": socket.assigns["userName"] as? String ?? "?",
            ])
        default:
            break
        }
    }

    func leave(topic: String, payload: ChannelPayload, socket: ChannelSocket) async {
        if let userID = socket.assigns["userID"] as? UUID {
            await Presence.untrack(socket, topic: topic, key: userID.uuidString)
        }
    }

    func intercept(event: String, payload: ChannelPayload, socket: ChannelSocket) async throws -> ChannelPayload {
        var enriched = payload
        enriched["server_time"] = Date().timeIntervalSince1970
        return enriched
    }
}

// MARK: - Fixture: SystemChannel

private struct SystemChannel: Channel {
    func join(topic: String, payload: ChannelPayload, socket: ChannelSocket) async throws -> ChannelPayload {
        return ["topic": topic]
    }

    func handle(event: String, payload: ChannelPayload, socket: ChannelSocket) async throws {}

    func leave(topic: String, payload: ChannelPayload, socket: ChannelSocket) async {}
}

// MARK: - Fixture: ChatApp

private struct ChatApp: RoostApp {
    var pubSub: (any RoostPubSub)? { PubSub.inMemory() }

    var channels: ChannelRouter {
        ChannelRouter {
            on("room:*", RoomChannel.self)
            on("system:*", SystemChannel.self)
        }
    }

    @RouteBuilder var routes: [Route] {
        // TestApp.connectSocket(_:) connects in process, without an HTTP route.
        GET("/") { conn in conn.text("ok") }
    }
}

// MARK: - Tests

@Suite("Channel Integration", .serialized, .timeLimit(.minutes(1)))
struct ChannelTests {

    // MARK: Join

    @Suite("Join")
    struct Join {

        @Test("Client can join a topic and receives ok reply")
        func joinSucceeds() async throws {
            let app = try await TestApp(ChatApp.self, assigns: ["userID": UUID(), "userName": "Guest"])
            let socket = try await app.connectSocket("/socket")

            let reply = try await socket.join("room:lobby", payload: [:])

            #expect(reply.status == "ok")
            #expect(reply.payload["room"] as? String == "room:lobby")
        }

        @Test("Unauthenticated client is rejected with error reply")
        func unauthenticatedJoinFails() async throws {
            let app = try await TestApp(ChatApp.self)
            let socket = try await app.connectSocket("/socket")

            do {
                _ = try await socket.join("room:lobby", payload: [:])
                Issue.record("Expected join to throw ChannelError.unauthorized")
            } catch let error as ChannelError {
                #expect(error == .unauthorized("Must be authenticated"))
            }
        }

        @Test("Client receives existing presence list on join")
        func receivesPresenceOnJoin() async throws {
            let app1 = try await TestApp(ChatApp.self, assigns: ["userID": UUID(), "userName": "Alice"])
            let alice = try await app1.connectSocket("/socket")
            _ = try await alice.join("room:lobby", payload: [:])

            let app2 = try await TestApp(ChatApp.self, assigns: ["userID": UUID(), "userName": "Bob"])
            let bob = try await app2.connectSocket("/socket")
            let reply = try await bob.join("room:lobby", payload: [:])

            #expect(reply.status == "ok")
        }
    }

    // MARK: Messaging

    @Suite("Messaging")
    struct Messaging {

        @Test("Client push broadcasts to all subscribers on the topic")
        func pushBroadcastsToAll() async throws {
            let userID = UUID()
            let app1 = try await TestApp(ChatApp.self, assigns: ["userID": userID, "userName": "Alice"])
            let app2 = try await TestApp(ChatApp.self, assigns: ["userID": UUID(), "userName": "Bob"])

            let alice = try await app1.connectSocket("/socket")
            let bob   = try await app2.connectSocket("/socket")

            _ = try await alice.join("room:lobby", payload: [:])
            _ = try await bob.join("room:lobby", payload: [:])

            try await alice.push(event: "new_msg", payload: ["body": "Hello!"])

            let bobReceived = try await bob.receive(event: "new_message")
            #expect(bobReceived["body"] as? String == "Hello!")
            #expect(bobReceived["from"] as? String == "Alice")
        }

        @Test("Server enriches broadcast payload with timestamp")
        func serverEnrichesPayload() async throws {
            let app    = try await TestApp(ChatApp.self, assigns: ["userID": UUID(), "userName": "Alice"])
            let socket = try await app.connectSocket("/socket")
            _ = try await socket.join("room:lobby", payload: [:])

            try await socket.push(event: "new_msg", payload: ["body": "Test"])

            let msg = try await socket.receive(event: "new_message")
            #expect(msg["server_time"] != nil)
        }

        @Test("broadcastFrom does not send to original sender")
        func broadcastFromExcludesSender() async throws {
            let app    = try await TestApp(ChatApp.self, assigns: ["userID": UUID(), "userName": "Alice"])
            let socket = try await app.connectSocket("/socket")
            _ = try await socket.join("room:lobby", payload: [:])

            try await socket.push(event: "typing", payload: [:])

            let messages = socket.receivedEvents(named: "user_typing")
            #expect(messages.isEmpty)
        }
    }

    // MARK: Leave

    @Suite("Leave")
    struct Leave {

        @Test("Client can leave a topic gracefully")
        func leaveGracefully() async throws {
            let app    = try await TestApp(ChatApp.self, assigns: ["userID": UUID(), "userName": "Alice"])
            let socket = try await app.connectSocket("/socket")
            _ = try await socket.join("room:lobby", payload: [:])

            let reply = try await socket.leave("room:lobby")
            #expect(reply.status == "ok")
        }

        @Test("Messages are not received after leaving")
        func noMessagesAfterLeave() async throws {
            let app1 = try await TestApp(ChatApp.self, assigns: ["userID": UUID(), "userName": "Alice"])
            let app2 = try await TestApp(ChatApp.self, assigns: ["userID": UUID(), "userName": "Bob"])

            let alice = try await app1.connectSocket("/socket")
            let bob   = try await app2.connectSocket("/socket")

            _ = try await alice.join("room:lobby", payload: [:])
            _ = try await bob.join("room:lobby", payload: [:])
            _ = try await alice.leave("room:lobby")

            try await bob.push(event: "new_msg", payload: ["body": "Still there?"])

            let aliceMessages = alice.receivedEvents(named: "new_message")
            #expect(aliceMessages.isEmpty)
        }
    }

    // MARK: Payloads

    @Suite("Payloads")
    struct Payloads {

        @Test("A payload that JSON can't hold throws, as it couldn't reach a client")
        func nonJSONPayloadThrows() async throws {
            let app    = try await TestApp(ChatApp.self, assigns: ["userID": UUID(), "userName": "Alice"])
            let socket = try await app.connectSocket("/socket")
            _ = try await socket.join("system:alerts", payload: [:])

            await #expect(throws: EncodingError.self) {
                try await app.channels.broadcast(topic: "system:alerts", event: "new_alert", payload: ["at": Date()])
            }
            await #expect(throws: EncodingError.self) {
                try await socket.socket.push(event: "new_alert", payload: ["id": UUID()])
            }
            let nickname: String? = nil
            try await socket.socket.push(event: "new_alert", payload: ["nickname": nickname as any Sendable])
        }
    }

    // MARK: Server Push

    @Suite("Server Push")
    struct ServerPush {

        @Test("Server can push to a topic without a client event")
        func serverPushReachesTopic() async throws {
            let app    = try await TestApp(ChatApp.self, assigns: ["userID": UUID(), "userName": "Alice"])
            let socket = try await app.connectSocket("/socket")
            _ = try await socket.join("system:alerts", payload: [:])

            try await app.channels.broadcast(
                topic: "system:alerts",
                event: "new_alert",
                payload: ["level": "critical", "msg": "DB unreachable"]
            )

            let alert = try await socket.receive(event: "new_alert")
            #expect(alert["level"] as? String == "critical")
        }
    }
}

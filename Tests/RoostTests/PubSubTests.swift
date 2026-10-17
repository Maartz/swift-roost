import Foundation
import Nexus
import NexusRouter
import Testing

@testable import Roost
@testable import RoostTest

// MARK: - Fixture App

private struct ChatApp: RoostApp {
    var pubSub: (any RoostPubSub)? { PubSub.inMemory() }

    @RouteBuilder var routes: [Route] {
        POST("/rooms/:id/messages") { conn in
            let id = conn.params["id"] ?? "lobby"
            let topic = "room:\(id)"
            let input = try conn.decode(as: [String: String].self)
            let body = input["body"] ?? ""
            try await conn.pubSub.broadcast(
                topic,
                event: "new_message",
                payload: [
                    "body": body,
                    "at": ISO8601DateFormatter().string(from: Date()),
                ]
            )
            return try conn.json(status: .created, value: ["ok": true])
        }
    }
}

// MARK: - Test Helper

/// Thread-safe message accumulator for use inside @Sendable closures.
private actor Collector {
    private(set) var items: [PubSubMessage] = []
    func append(_ item: PubSubMessage) { items.append(item) }
}

// MARK: - Tests

@Suite("PubSub Integration")
struct PubSubTests {

    // MARK: Subscribe and Receive

    @Suite("Subscribe and Receive")
    struct SubscribeAndReceive {

        @Test("Subscriber receives broadcast on matching topic")
        func receivesMatchingBroadcast() async throws {
            let app = try await TestApp(ChatApp.self)
            guard let ps = app.pubSub else { Issue.record("pubSub not configured"); return }
            let collector = Collector()

            ps.subscribe("room:lobby") { await collector.append($0) }
            try await ps.broadcast("room:lobby", event: "new_message", payload: ["body": "Hello"])

            let items = await collector.items
            #expect(items.count == 1)
            #expect(items[0].event == "new_message")
            #expect(items[0].payload["body"] as? String == "Hello")
        }

        @Test("Subscriber does not receive broadcast on different topic")
        func ignoresDifferentTopic() async throws {
            let app = try await TestApp(ChatApp.self)
            guard let ps = app.pubSub else { Issue.record("pubSub not configured"); return }
            let collector = Collector()

            ps.subscribe("room:lobby") { await collector.append($0) }
            try await ps.broadcast("room:other", event: "new_message", payload: ["body": "Nope"])

            let items = await collector.items
            #expect(items.isEmpty)
        }

        @Test("Multiple subscribers all receive the same broadcast")
        func multipleSubscribersReceive() async throws {
            let app = try await TestApp(ChatApp.self)
            guard let ps = app.pubSub else { Issue.record("pubSub not configured"); return }
            let collectorA = Collector()
            let collectorB = Collector()

            ps.subscribe("room:lobby") { await collectorA.append($0) }
            ps.subscribe("room:lobby") { await collectorB.append($0) }
            try await ps.broadcast("room:lobby", event: "ping", payload: [:])

            #expect(await collectorA.items.count == 1)
            #expect(await collectorB.items.count == 1)
        }
    }

    // MARK: Unsubscribe

    @Suite("Unsubscribe")
    struct Unsubscribe {

        @Test("Unsubscribed handler does not receive further messages")
        func unsubscribeStopsMessages() async throws {
            let app = try await TestApp(ChatApp.self)
            guard let ps = app.pubSub else { Issue.record("pubSub not configured"); return }
            let collector = Collector()

            let token = ps.subscribe("room:lobby") { await collector.append($0) }
            try await ps.broadcast("room:lobby", event: "first", payload: [:])
            #expect(await collector.items.count == 1)

            ps.unsubscribe(token)
            try await ps.broadcast("room:lobby", event: "second", payload: [:])
            #expect(await collector.items.count == 1, "Should not receive after unsubscribe")
        }
    }

    // MARK: HTTP → PubSub

    @Suite("HTTP Broadcast")
    struct HTTPBroadcast {

        @Test("POST /rooms/:id/messages broadcasts to topic")
        func postMessageBroadcasts() async throws {
            let app = try await TestApp(ChatApp.self)
            guard let ps = app.pubSub else { Issue.record("pubSub not configured"); return }
            let collector = Collector()

            ps.subscribe("room:lobby") { await collector.append($0) }

            let response = try await app.post("/rooms/lobby/messages", json: ["body": "Hello from HTTP"])

            let items = await collector.items
            #expect(response.status == .created)
            #expect(items.count == 1)
            #expect(items[0].payload["body"] as? String == "Hello from HTTP")
        }

        @Test("Broadcast payload includes sender metadata")
        func broadcastIncludesMetadata() async throws {
            let app = try await TestApp(ChatApp.self)
            guard let ps = app.pubSub else { Issue.record("pubSub not configured"); return }
            let collector = Collector()

            ps.subscribe("room:lobby") { await collector.append($0) }
            _ = try await app.post("/rooms/lobby/messages", json: ["body": "Test"])

            let first = await collector.items.first
            #expect(first?.payload["at"] != nil, "Broadcast should include a timestamp")
        }
    }

    // MARK: Adapter selection

    @Suite("Adapter")
    struct AdapterTests {

        @Test("Test environment uses in-memory adapter")
        func usesInMemoryInTests() async throws {
            let app = try await TestApp(ChatApp.self)
            #expect(app.pubSub is InMemoryPubSub)
        }
    }
}

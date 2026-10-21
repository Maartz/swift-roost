import Foundation
import Testing

@testable import Roost

@Suite("Valkey PubSub")
struct ValkeyPubSubTests {
    #if Valkey
    @Test(.timeLimit(.minutes(1)), .enabled(if: StoreBackend.valkeyURL != nil))
    func messagesReachTheSubscribersOfEveryServer() async throws {
        guard let url = StoreBackend.valkeyURL else { return }
        let channel = "roost-test:\(UUID().uuidString)"
        let first = PubSub.valkey(url: url, channel: channel)
        let second = PubSub.valkey(url: url, channel: channel)
        let (received, delivered) = AsyncStream<PubSubMessage>.makeStream()
        second.subscribe("room:1") { delivered.yield($0) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await first.run() }
            group.addTask { try await second.run() }
            defer { group.cancelAll() }
            // Publishes until the second server has subscribed.
            let publishing = Task {
                while !Task.isCancelled {
                    try? await first.broadcast("room:1", event: "said", payload: ["body": "hi", "count": 2])
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            defer { publishing.cancel() }
            var messages = received.makeAsyncIterator()
            let message = try #require(await messages.next())
            #expect(message.event == "said")
            #expect(message.payload["body"] as? String == "hi")
            #expect(message.payload["count"] as? Int == 2)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func broadcastingBeforeTheAppRunsItFails() async throws {
        let pubSub = PubSub.valkey(url: "valkey://127.0.0.1:1")
        let error = await #expect(throws: (any Error).self) {
            try await pubSub.broadcast("room:1", event: "said", payload: [:])
        }
        #expect(String(describing: error).contains("RoostApp.pubSub"))
    }
    #else
    @Test func withoutTheValkeyTraitTheAppStopsAtStartup() async throws {
        let error = await #expect(throws: KeyValueStoreError.self) {
            try await PubSub.valkey(url: "valkey://127.0.0.1:1").run()
        }
        #expect(error?.kind == .misconfigured)
        #expect(error?.description.contains("Valkey trait") == true)
    }
    #endif
}

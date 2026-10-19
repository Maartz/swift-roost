import ESWLive
import Foundation
import Nexus

struct LivePackets: Sendable {
    let stream: AsyncStream<String>
    let cancel: @Sendable () -> Void
}

/// Bounded forwarding plus heartbeats. The response producer awaits each
/// socket write; queue overflow terminates the stream and forces a snapshot.
func livePackets(_ updates: AsyncStream<LiveUpdate>) -> LivePackets {
    let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(16))
    let forward = Task {
        defer { continuation.finish() }
        for await update in updates {
            guard !Task.isCancelled else { break }
            guard let bytes = try? JSONEncoder().encode(update), let json = String(data: bytes, encoding: .utf8) else { break }
            let packet = SSEEvent(data: json, event: "update", id: String(update.revision), retry: 1000).formatted()
            guard case .enqueued = continuation.yield(packet) else { break }
        }
    }
    let heartbeat = Task {
        do {
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(15))
                guard case .enqueued = continuation.yield(": heartbeat\n\n") else { continuation.finish(); return }
            }
        } catch {}
    }
    let cancel: @Sendable () -> Void = { forward.cancel(); heartbeat.cancel(); continuation.finish() }
    continuation.onTermination = { _ in forward.cancel(); heartbeat.cancel() }
    return LivePackets(stream: stream, cancel: cancel)
}

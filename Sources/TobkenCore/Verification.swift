import AgentSpeedCore
import Foundation

public enum Verification {
    public enum Failure: Error { case assertion(String) }

    /// Exercises the same background monitor and mapping used by the app, with isolated transcripts.
    @MainActor public static func run() async throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tobken-verify-\(UUID().uuidString)")
        let sessions = folder.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = sessions.appendingPathComponent("rollout-test.jsonl")
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func line(_ seconds: Double, _ type: String, _ payload: [String: Any]) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: ["timestamp": formatter.string(from: now.addingTimeInterval(seconds)),
                                                                  "type": type, "payload": payload], options: [.sortedKeys])
            data.append(10)
            return data
        }
        func turn(_ id: String, input: Int, output: Int, at seconds: Double) throws -> Data {
            var data = try line(seconds - 2, "event_msg", ["type": "user_message", "message": "fixture"])
            data.append(try line(seconds, "token_usage_record", ["response_id": id, "usage": ["input_tokens": input, "output_tokens": output]]))
            return data
        }
        var seed = try line(-6, "session_meta", ["id": "tobken-fixture", "cwd": "/fixture"])
        seed.append(try line(-5, "turn_context", ["model": "fixture-model"]))
        seed.append(try turn("one", input: 1_000, output: 200, at: -1))
        try seed.write(to: file)
        let store = SpeedStore()
        let monitor = LiveMonitor(store: store, configuration: MonitorConfiguration(enabledSources: [.codex], codexRoot: sessions))
        monitor.start()
        defer { monitor.stop() }
        @MainActor func wait(_ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(15)
            while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            guard predicate() else { throw Failure.assertion("Timed out waiting for transcript updates") }
        }
        try await wait { store.snapshot.state == .running && store.snapshot.today.output == 200 }
        guard store.snapshot.today.total == 1_200 else { throw Failure.assertion("Expected 1200 tokens after seed") }
        guard store.snapshot.live.output == 0 else { throw Failure.assertion("Startup history became current TPS") }
        guard store.snapshot.activities.reduce(0, { $0 + $1.totals.total }) == 1_200 else {
            throw Failure.assertion("Model breakdown does not match seed total")
        }
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        try writer.seekToEnd()
        try writer.write(contentsOf: turn("two", input: 3_000, output: 400, at: Date().timeIntervalSince(now)))
        try await wait { store.snapshot.today.output == 600 }
        let snapshot = store.snapshot
        let dashboard = Dashboard(snapshot: snapshot)
        guard snapshot.live.output == 80 else { throw Failure.assertion("Expected 400 new output tokens / 5 seconds = 80 TPS") }
        let filtered = Dashboard(snapshot: snapshot, selectedSource: .claudeCode)
        guard dashboard.totals.total == 4_600, dashboard.models.reduce(0, { $0 + $1.metrics.totals.total }) == 4_600,
              filtered.totals.total == 0, filtered.statusTitle == dashboard.statusTitle else {
            throw Failure.assertion("Totals or global status title changed with a filter")
        }
        guard snapshot.activities.allSatisfy({ $0.ttftP50 == nil }) else {
            throw Failure.assertion("Missing TTFT was fabricated")
        }
        try await wait { store.snapshot.live.output == 0 }
        monitor.stop()
        let restartedStore = SpeedStore()
        let restarted = LiveMonitor(store: restartedStore, configuration: monitor.configuration)
        restarted.start()
        defer { restarted.stop() }
        try await wait { restartedStore.snapshot.state == .running && restartedStore.snapshot.today.total == 4_600 }
        guard restartedStore.snapshot.live.output == 0 else { throw Failure.assertion("Restart invented live TPS") }
        return "PASS: seed 1,200 → append 4,600 → restart 4,600; model totals match; filters preserve status total; unknown TTFT preserved; observed TPS 0 → 80 → 0."
    }
}

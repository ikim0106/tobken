import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Monitor efficiency")
struct MonitorEfficiencyTests {
    @Test func unchangedOpenCodeStillReconcilesADeletionAfterLiveRefresh() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tobken-db-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try SQLiteConnection(path: directory.appendingPathComponent("opencode.db").path, mode: .readWriteCreate)
        try writer.execute("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE session_v2 (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT,
                time_created INTEGER, time_updated INTEGER);
            CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT,
                seq INTEGER, time_created INTEGER, time_updated INTEGER, data TEXT);
            INSERT INTO session_v2 VALUES ('one', NULL, '/fixture', 1000, 2000);
            """)
        let source = OpencodeSource(root: directory.path, fileID: -1)
        #expect(source.refreshAvailability())
        var deduper = Deduper()
        _ = source.seed(todayStartMs: 0, deduper: &deduper)
        _ = source.rediscover(nowMs: 3000, deduper: &deduper)
        #expect(source.rediscover(nowMs: 4000, deduper: &deduper).isEmpty)
        try writer.execute("DELETE FROM session_v2 WHERE id = 'one'")
        // Live refresh advances its file signature. That must not skip the later deletion check.
        _ = source.refresh(deduper: &deduper)
        let removed = source.rediscover(nowMs: 5000, deduper: &deduper)
        #expect(removed.removedAgents == ["opencode:one"])
        #expect(source.agentStates.isEmpty)
        #expect(source.rediscover(nowMs: 6000, deduper: &deduper).isEmpty)
    }

    @Test @MainActor func idleMonitorSleepsButNoticesOpenWriterAndReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tobken-idle-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rollout-test.jsonl")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func line(at date: Date, type: String, payload: [String: Any]) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: [
                "timestamp": formatter.string(from: date), "type": type, "payload": payload
            ])
            data.append(10)
            return data
        }
        func turn(_ id: String, output: Int, at date: Date) throws -> Data {
            var data = try line(at: date.addingTimeInterval(-2), type: "event_msg", payload: ["type": "user_message"])
            data.append(try line(at: date, type: "token_usage_record", payload: [
                "response_id": id, "usage": ["input_tokens": 100, "output_tokens": output]
            ]))
            data.append(try line(at: date, type: "event_msg", payload: ["type": "task_complete"]))
            return data
        }
        var seed = try line(at: Date().addingTimeInterval(-20), type: "session_meta", payload: ["id": "idle-test"])
        seed.append(try turn("one", output: 200, at: Date().addingTimeInterval(-15)))
        try seed.write(to: file)
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        try writer.seekToEnd()

        let store = SpeedStore()
        var published: [SpeedSnapshot] = []
        let listener = store.addLiveListener { published.append($0) }
        defer { store.removeLiveListener(listener) }
        let monitor = LiveMonitor(store: store, configuration: MonitorConfiguration(enabledSources: [.codex], codexRoot: directory))
        monitor.start()
        defer { monitor.stop() }
        @MainActor func waitForOutput(_ output: Int) async throws {
            let deadline = Date().addingTimeInterval(2)
            while store.snapshot.state != .running || store.snapshot.today.output != output {
                guard Date() < deadline else {
                    throw Timeout(description: "expected output \(output), got \(store.snapshot.today.output), state \(store.snapshot.state)")
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await waitForOutput(200)
        let count = published.count
        try await Task.sleep(for: .milliseconds(1_400))
        #expect(published.count == count, "idle snapshots must stop")
        #expect(store.snapshot.history.isEmpty, "the app records its own graph; the collector must skip its unused history")

        // Keep the writer open: waiting for a file-close notification would miss these appends.
        try writer.write(contentsOf: turn("two", output: 300, at: Date()))
        try await waitForOutput(500)
        try writer.write(contentsOf: turn("three", output: 400, at: Date()))
        try writer.write(contentsOf: turn("four", output: 500, at: Date()))
        try await waitForOutput(1_400)
        let running = published.filter { $0.state == .running }
        for (previous, next) in zip(running, running.dropFirst()) {
            #expect(next.timestamp.timeIntervalSince(previous.timestamp) >= 0.95, "bursts must not publish faster than once a second")
        }

        // Atomic replacement needs a watcher for the new inode, even with the old writer open.
        try turn("replacement", output: 600, at: Date()).write(to: file, options: .atomic)
        try await waitForOutput(2_000)
        let replacementWriter = try FileHandle(forWritingTo: file)
        defer { try? replacementWriter.close() }
        try replacementWriter.seekToEnd()
        try replacementWriter.write(contentsOf: turn("after-replacement", output: 700, at: Date()))
        try await waitForOutput(2_700)
        monitor.stop()
        try await Task.sleep(for: .milliseconds(150))
        let stoppedCount = published.count
        try replacementWriter.write(contentsOf: turn("after-stop", output: 800, at: Date()))
        try await Task.sleep(for: .milliseconds(1_200))
        #expect(published.count == stoppedCount, "stop must cancel notifications and timers")
    }

    private struct Timeout: Error, CustomStringConvertible { let description: String }
}

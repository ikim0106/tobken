import AgentSpeedCore
import Foundation

public enum Demo {
    public static func snapshot() -> SpeedSnapshot {
        let now = Date()
        func activity(_ source: SourceKind, _ model: String, input: Int, output: Int,
                      requests: Int, live: Double, average: Double, latency: Int64?) -> ActivityMetrics {
            var metrics = ActivityMetrics(key: ActivityKey(source: source, model: model))
            metrics.totals = TokenTotals(requests: requests, input: input, cachedInput: input * 3 / 4,
                                        output: output, reasoning: output / 4)
            metrics.timedOutput = Int64(output)
            metrics.durationMs = Int64(Double(output) * 1000 / average)
            metrics.timedRequests = requests
            metrics.liveTPS = live
            metrics.estimatedTPS = live
            if let latency { metrics.latencyBins[PerfLatency.bucket(latency)] = requests }
            metrics.durationBins[PerfLatency.bucket(12_000)] = requests
            return metrics
        }
        let activities = [
            activity(.codex, "gpt-5.3-codex", input: 9_800_000, output: 420_000, requests: 184, live: 92, average: 88.4, latency: nil),
            activity(.claudeCode, "claude-opus-4-6", input: 5_200_000, output: 186_000, requests: 93, live: 54, average: 63.2, latency: 1_450),
            activity(.opencode, "gemini-3.1-pro", input: 1_400_000, output: 75_000, requests: 42, live: 0, average: 109.6, latency: 620),
            activity(.claudeCode, "gpt-5.3-codex", input: 650_000, output: 32_000, requests: 18, live: 0, average: 81.2, latency: 820),
        ]
        var all = ActivityMetrics(key: ActivityKey(source: .codex, model: nil))
        activities.forEach { all.merge($0) }
        var snapshot = SpeedSnapshot.empty
        snapshot.timestamp = now
        snapshot.dayStart = Calendar.current.startOfDay(for: now)
        snapshot.state = .running
        snapshot.activities = activities
        snapshot.today = all.totals
        snapshot.live = Rate(output: all.liveTPS)
        snapshot.averageToday = all.averageTPS
        snapshot.liveEstimatedShare = 1
        snapshot.generatingCount = 2
        snapshot.peakToday = Rate(output: 312)
        snapshot.sources = [SourceKind.codex, .claudeCode, .opencode].map { source in
            var metrics = ActivityMetrics(key: ActivityKey(source: source, model: nil))
            activities.filter { $0.key.source == source }.forEach { metrics.merge($0) }
            return SourceStatus(kind: source, enabled: true, rootPath: "", available: true,
                                sessionCount: 12, live: Rate(output: metrics.liveTPS), today: metrics.totals,
                                activeAgents: metrics.liveTPS > 0 ? 1 : 0)
        }
        // A minute of readings that ends at the current value, as the live graph would.
        let current = all.liveTPS
        snapshot.history = (0..<60).map { index in
            let wave = 0.78 + 0.16 * cos(Double(index - 59) * 0.21) + 0.06 * cos(Double(index - 59) * 0.57)
            return HistoryPoint(time: now.addingTimeInterval(Double(index - 59)),
                                measured: Rate(output: current * wave), estimated: .zero)
        }
        return snapshot
    }
}

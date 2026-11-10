import Foundation

/// Tobken: output actually reported since monitoring began, never a prediction from older requests.
///
/// Output counts only once its usage is logged, but it is placed across the time it was generated: a usage update
/// spreads its new output from the previous update of that response (or, for the first, from its first output or
/// request start) to the time the update was logged. Most harnesses log usage once, at completion, so this turns a
/// 2,000-token response that took 40 s into 50 TPS over those 40 s rather than a burst when the line appears.
///
/// The current rate is the output placed in the trailing `durationMs`, divided by its length, including quiet time.
struct ObservedOutputWindow: Sendable {
    /// Long enough to span the gaps between completion-logged responses of one running task (tool calls,
    /// thinking), so current TPS does not flicker between 0 and a burst while work continues.
    static let durationMs: Int64 = 30_000
    /// The graph: one reading per second over the last minute.
    static let seriesSamples = 60
    static let seriesStepMs: Int64 = 1_000
    /// Longer intervals are not credible generation times (METRICS valid interval); output beyond is not placed.
    static let maxIntervalMs: Int64 = 15 * 60_000

    private struct Contribution: Sendable {
        var startMs: Int64
        var endMs: Int64
        var response: String
        var activity: ActivityKey
        var agent: String
        var tokens: Int

        /// The tokens generated inside `(from, to]`, assuming an even rate across the interval. An instant
        /// (no usable interval) counts entirely at its end.
        func tokens(from: Int64, to: Int64) -> Double {
            guard endMs > startMs else { return endMs > from && endMs <= to ? Double(tokens) : 0 }
            let overlap = min(to, endMs) - max(from, startMs)
            return overlap > 0 ? Double(tokens) * Double(overlap) / Double(endMs - startMs) : 0
        }
    }

    private var contributions: [Contribution] = []
    /// When readings became known: the first `advance`, which is the startup seed.
    private var startedMs: Int64?

    mutating func replace(_ old: ResponseRecord?, with record: ResponseRecord, at nowMs: Int64) {
        expire(at: nowMs)
        // Late model identification moves the existing contribution without counting it again.
        for index in contributions.indices where contributions[index].response == record.key {
            contributions[index].activity = record.activityKey
        }
        let previousOutput = old?.usage.output ?? 0
        let delta = record.usage.output - previousOutput
        if delta > 0 {
            // A log timestamp in the future (clock skew) cannot place output there.
            let endMs = min(record.endMs, nowMs)
            let begin: Int64? = if let old, previousOutput > 0 { old.endMs } else { record.firstMs ?? record.startMs }
            let startMs = min(max(begin ?? endMs, endMs - Self.maxIntervalMs), endMs)
            contributions.append(Contribution(startMs: startMs, endMs: endMs, response: record.key,
                                              activity: record.activityKey, agent: record.agentId, tokens: delta))
        } else if delta < 0 {
            // A usage correction retracts recent output; it must never create negative TPS.
            var remaining = -delta
            for index in contributions.indices.reversed() where contributions[index].response == record.key {
                let removed = min(remaining, contributions[index].tokens)
                contributions[index].tokens -= removed
                remaining -= removed
                if remaining == 0 { break }
            }
            contributions.removeAll { $0.tokens == 0 }
        }
    }

    mutating func advance(nowMs: Int64) -> LiveWindow {
        if startedMs == nil { startedMs = nowMs }
        expire(at: nowMs)
        let seconds = Double(Self.durationMs) / 1_000
        var activities: [ActivityKey: Double] = [:]
        var sources: [SourceKind: Rate] = [:]
        var agents: [String: Rate] = [:]
        var total = Rate.zero
        for contribution in contributions {
            let tokens = contribution.tokens(from: nowMs - Self.durationMs, to: nowMs)
            guard tokens > 0 else { continue }
            let rate = Rate(output: tokens / seconds, total: tokens / seconds)
            total.add(rate)
            activities[contribution.activity, default: 0] += rate.output
            sources[contribution.activity.source, default: .zero].add(rate)
            agents[contribution.agent, default: .zero].add(rate)
        }
        var window = LiveWindow(total: total, activities: activities, sources: sources, agents: agents)
        window.observedSeries = series(nowMs: nowMs)
        return window
    }

    /// The current-rate reading at each second of the last minute; the last equals `advance`'s total.
    private func series(nowMs: Int64) -> ObservedSeries {
        let count = Self.seriesSamples
        let times = (0..<count).map { nowMs - Int64(count - 1 - $0) * Self.seriesStepMs }
        let known = times.map { $0 >= (startedMs ?? nowMs) }
        let empty = known.map { $0 ? 0.0 : nil } as [Double?]
        var total = empty
        var bySource: [SourceKind: [Double?]] = [:]
        let seconds = Double(Self.durationMs) / 1_000
        for contribution in contributions {
            for index in times.indices where known[index] {
                let tokens = contribution.tokens(from: times[index] - Self.durationMs, to: times[index])
                guard tokens > 0 else { continue }
                total[index]! += tokens / seconds
                let source = contribution.activity.source
                if bySource[source] == nil { bySource[source] = empty }
                bySource[source]![index]! += tokens / seconds
            }
        }
        return ObservedSeries(endMs: nowMs, stepMs: Self.seriesStepMs, total: total, bySource: bySource)
    }

    private mutating func expire(at nowMs: Int64) {
        // Keep what the oldest graph reading still needs.
        let horizon = nowMs - Int64(Self.seriesSamples - 1) * Self.seriesStepMs - Self.durationMs
        contributions.removeAll { $0.endMs <= horizon }
    }
}

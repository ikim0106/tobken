import Foundation

/// Output actually reported since monitoring began, never a prediction from older requests.
struct ObservedOutputWindow: Sendable {
    static let durationMs: Int64 = 5_000

    private struct Contribution: Sendable {
        var timeMs: Int64
        var response: String
        var activity: ActivityKey
        var agent: String
        var tokens: Int
    }

    private var contributions: [Contribution] = []

    mutating func replace(_ old: ResponseRecord?, with record: ResponseRecord, at nowMs: Int64) {
        expire(at: nowMs)
        // Late model identification moves the existing contribution without counting it again.
        for index in contributions.indices where contributions[index].response == record.key {
            contributions[index].activity = record.activityKey
        }
        let delta = record.usage.output - (old?.usage.output ?? 0)
        if delta > 0 {
            contributions.append(Contribution(timeMs: nowMs, response: record.key, activity: record.activityKey,
                                              agent: record.agentId, tokens: delta))
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
        expire(at: nowMs)
        let seconds = Double(Self.durationMs) / 1_000
        var activities: [ActivityKey: Double] = [:]
        var sources: [SourceKind: Rate] = [:]
        var agents: [String: Rate] = [:]
        var total = Rate.zero
        for contribution in contributions {
            let rate = Rate(output: Double(contribution.tokens) / seconds,
                            total: Double(contribution.tokens) / seconds)
            total.add(rate)
            activities[contribution.activity, default: 0] += rate.output
            sources[contribution.activity.source, default: .zero].add(rate)
            agents[contribution.agent, default: .zero].add(rate)
        }
        return LiveWindow(total: total, activities: activities, sources: sources, agents: agents)
    }

    private mutating func expire(at nowMs: Int64) {
        contributions.removeAll { $0.timeMs <= nowMs - Self.durationMs }
    }
}

import AgentSpeedCore
import Foundation

public enum MetricFormat {
    /// Compact token count. Decimals are chosen after rounding, so values never read "1000K" or "100.0K".
    public static func tokens(_ value: Int) -> String {
        let magnitude = abs(Double(value))
        guard magnitude >= 1_000 else { return String(value) }
        let units: [(scale: Double, suffix: String)] = [(1_000, "K"), (1_000_000, "M"), (1_000_000_000, "B")]
        var index = units.lastIndex { magnitude >= $0.scale } ?? 0
        let sign = value < 0 ? "-" : ""
        while true {
            let scaled = magnitude / units[index].scale
            let tenths = (scaled * 10).rounded() / 10
            guard tenths >= 100 else { return sign + String(format: "%.1f", tenths) + units[index].suffix }
            let whole = scaled.rounded()
            if whole >= 1_000, index + 1 < units.count { index += 1; continue }
            return sign + String(format: "%.0f", whole) + units[index].suffix
        }
    }

    /// One decimal below 100, none from 100 (decided after rounding, so 99.96 reads "100").
    public static func rate(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        let tenths = (value * 10).rounded() / 10
        return tenths >= 100 || value == 0 ? String(format: "%.0f", value) : String(format: "%.1f", tenths)
    }

    /// Whole-number rate for compact places such as the menu bar, where changing decimals cause jitter.
    public static func wholeRate(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.0f", value.rounded())
    }

    public static func latency(_ milliseconds: Double?) -> String {
        guard let milliseconds else { return "—" }
        return milliseconds < 1_000
            ? String(format: "%.0f ms", milliseconds)
            : String(format: "%.1f s", milliseconds / 1_000)
    }

    /// Spend at API list prices, or nil when nothing could be priced (unknown is not $0). "≥" marks a lower bound
    /// when some requests have no known price.
    public static func cost(_ tally: CostTally, requests: Int) -> String? {
        guard requests > 0, !tally.isUnknown(requests: requests) else { return nil }
        let prefix = tally.unpricedRequests > 0 ? "≥ " : ""
        return prefix + usd(micro: tally.costMicroUsd)
    }

    public static func usd(micro: Int64) -> String {
        let dollars = Double(max(micro, 0)) / 1_000_000
        if micro == 0 { return "$0.00" }
        if dollars < 0.01 { return "<$0.01" }
        if (dollars * 100).rounded() / 100 < 1_000 { return String(format: "$%.2f", dollars) }
        return "$" + tokens(Int(dollars.rounded()))
    }

    /// Tooltip for a cost: what it means and what it leaves out.
    public static func costHelp(_ tally: CostTally, requests: Int) -> String {
        var text = "Estimated at API list prices from token usage. Subscription plans are billed differently."
        if tally.unpricedRequests > 0 {
            text += " \(exact(tally.unpricedRequests)) of \(exact(requests)) requests have no known price and are not included."
        }
        return text
    }

    public static func exact(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }
}

public struct ModelRow: Identifiable {
    public struct ID: Hashable {
        var model: String?
        var provider: String?
    }
    public var id: ID
    public var name: String
    public var provider: String?
    public var sources: [SourceKind]
    public var metrics: ActivityMetrics
}

public struct Dashboard {
    public let snapshot: SpeedSnapshot
    public var selectedSource: SourceKind?
    /// Harnesses the user hid from the menu. They still count toward every total; the status item stays global.
    public var hiddenSources: Set<SourceKind>

    public init(snapshot: SpeedSnapshot, selectedSource: SourceKind? = nil, hiddenSources: Set<SourceKind> = []) {
        self.snapshot = snapshot
        self.selectedSource = selectedSource
        self.hiddenSources = hiddenSources
    }

    public var statusTitle: String {
        if case .starting = snapshot.state { return "Tobken · …" }
        let rate = Dashboard(snapshot: snapshot).currentTPS
        return "\(MetricFormat.tokens(snapshot.today.total)) today · \(MetricFormat.wholeRate(rate)) TPS"
    }

    public var selectedActivities: [ActivityMetrics] {
        snapshot.activities.filter { selectedSource == nil || $0.key.source == selectedSource }
    }

    /// Aggregate of the selected activities. Its `key` is a placeholder; read only the metrics.
    var summary: ActivityMetrics {
        selectedActivities.reduce(into: ActivityMetrics(key: ActivityKey(source: selectedSource ?? .codex, model: nil))) {
            $0.merge($1)
        }
    }

    /// Today's spend for the selection at list prices.
    public var cost: CostTally {
        selectedSource == nil ? snapshot.todayCost : summary.cost
    }

    /// Today's output divided by summed timed request durations for the selection.
    public var averageTPS: Double? { summary.averageTPS }

    /// Returns `source` if it is still listed and shown, otherwise nil ("All"), so a vanished or hidden harness cannot
    /// strand the menu.
    public func validSelection(_ source: SourceKind?) -> SourceKind? {
        guard let source else { return nil }
        return visibleSources.contains { $0.kind == source } ? source : nil
    }

    public var totals: TokenTotals {
        selectedSource == nil ? snapshot.today : summary.totals
    }

    public var liveTPS: Double {
        selectedSource == nil ? snapshot.live.output : summary.liveTPS
    }

    public var currentTPS: Double? {
        snapshot.state == .running ? liveTPS : nil
    }

    /// Requests in flight for the selection. Most harnesses log usage only when a response completes, so their
    /// output reaches current TPS (placed back across its generation time) only then.
    public var generatingCount: Int {
        snapshot.agents.filter { $0.phase == .generating && (selectedSource == nil || $0.source == selectedSource) }.count
    }

    /// Harnesses that are detected or active today.
    public var sources: [SourceStatus] {
        snapshot.sources.filter { $0.available || $0.today.total > 0 || $0.live.output > 0 }
    }

    /// `sources` without the ones hidden from the menu: the filter row and the Harnesses list.
    public var visibleSources: [SourceStatus] {
        sources.filter { !hiddenSources.contains($0.kind) }
    }

    public var models: [ModelRow] {
        let grouped = Dictionary(grouping: selectedActivities) {
            ModelRow.ID(model: $0.key.model, provider: $0.key.provider)
        }
        return grouped.map { id, activities in
            var metrics = ActivityMetrics(key: activities[0].key)
            activities.forEach { metrics.merge($0) }
            return ModelRow(id: id, name: id.model ?? "Unknown model", provider: id.provider,
                            sources: Array(Set(activities.map(\.key.source))).sorted { $0.rawValue < $1.rawValue },
                            metrics: metrics)
        }.sorted {
            if $0.metrics.totals.total != $1.metrics.totals.total { return $0.metrics.totals.total > $1.metrics.totals.total }
            if $0.name != $1.name { return $0.name < $1.name }
            return ($0.provider ?? "") < ($1.provider ?? "")
        }
    }
}

extension SourceKind {
    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude Desktop"
        case .deepseek: "DeepSeek"
        case .opencode: "OpenCode"
        case .gemini: "Gemini CLI"
        case .omp: "oh-my-pi"
        case .antigravity: "Antigravity"
        case .workbuddy: "WorkBuddy"
        case .workbuddyAi: "WorkBuddy AI"
        case .zcode: "ZCode"
        case .kimi: "Kimi"
        case .grokBuild: "Grok Build"
        case .pi: "Pi"
        case .openclaw: "OpenClaw"
        case .hermes: "Hermes"
        case .droid: "Factory Droid"
        case .devin: "Devin CLI"
        }
    }

    public var symbol: String {
        switch self {
        case .codex: "terminal"
        case .claudeCode, .claudeDesktop: "asterisk"
        case .gemini: "sparkles"
        case .opencode: "chevron.left.forwardslash.chevron.right"
        default: "cpu"
        }
    }
}

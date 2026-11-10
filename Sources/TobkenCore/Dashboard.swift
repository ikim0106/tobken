import AgentSpeedCore
import Foundation

public enum MetricFormat {
    public static func tokens(_ value: Int) -> String {
        let magnitude = abs(Double(value))
        let units: [(Double, String)] = [(1_000_000_000, "B"), (1_000_000, "M"), (1_000, "K")]
        for (scale, suffix) in units where magnitude >= scale {
            return String(format: magnitude / scale >= 100 ? "%.0f%@" : "%.1f%@", Double(value) / scale, suffix)
        }
        return String(value)
    }

    public static func rate(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: value >= 100 || value == 0 ? "%.0f" : "%.1f", value)
    }

    public static func latency(_ milliseconds: Double?) -> String {
        guard let milliseconds else { return "—" }
        return milliseconds < 1_000
            ? String(format: "%.0f ms", milliseconds)
            : String(format: "%.1f s", milliseconds / 1_000)
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

    public init(snapshot: SpeedSnapshot, selectedSource: SourceKind? = nil) {
        self.snapshot = snapshot
        self.selectedSource = selectedSource
    }

    public var statusTitle: String {
        if case .starting = snapshot.state { return "Tobken · …" }
        let rate = Dashboard(snapshot: snapshot).currentTPS
        return "\(MetricFormat.tokens(snapshot.today.total)) today · \(MetricFormat.rate(rate)) TPS"
    }

    public var selectedActivities: [ActivityMetrics] {
        snapshot.activities.filter { selectedSource == nil || $0.key.source == selectedSource }
    }

    public var summary: ActivityMetrics {
        selectedActivities.reduce(into: ActivityMetrics(key: ActivityKey(source: selectedSource ?? .codex, model: nil))) {
            $0.merge($1)
        }
    }

    public var totals: TokenTotals {
        selectedSource == nil ? snapshot.today : summary.totals
    }

    public var liveTPS: Double {
        selectedSource == nil ? snapshot.live.output : summary.liveTPS
    }

    public var currentTPS: Double? {
        let generating = selectedSource == nil ? snapshot.generatingCount > 0 : snapshot.agents.contains {
            $0.source == selectedSource && $0.phase == .generating
        }
        return generating && liveTPS == 0 ? nil : liveTPS
    }

    public var sources: [SourceStatus] {
        snapshot.sources.filter { $0.available || $0.today.total > 0 || $0.live.output > 0 }
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

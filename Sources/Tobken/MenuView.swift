import AgentSpeedCore
import SwiftUI
import TobkenCore

struct MenuView: View {
    @ObservedObject var model: AppModel
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}
    @State var expanded: Set<ModelRow.ID> = []
    @State private var contentHeight: CGFloat = 530
    private var dashboard: Dashboard { model.dashboard }
    private let green = Color(red: 0.22, green: 0.65, blue: 0.40)

    var body: some View {
        VStack(spacing: 0) {
            sourcePicker
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    title
                    if case .starting(let progress) = model.snapshot.state {
                        VStack(alignment: .leading, spacing: 10) {
                            ProgressView(value: progress)
                            Text("Reading today's activity…").foregroundStyle(.secondary)
                        }.padding(.vertical, 28)
                    } else {
                        totals
                        live
                        Divider()
                        breakdown
                        if model.selectedSource == nil { harnesses }
                        warning
                    }
                }
                .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
                .padding(.vertical, 14)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: MenuContentHeight.self, value: geometry.size.height)
                })
            }
            .frame(height: min(contentHeight, maxBodyHeight))
            .onPreferenceChange(MenuContentHeight.self) {
                contentHeight = $0
                model.menuSizeChanged?(min($0, maxBodyHeight) + 90)
            }
            Divider()
            footer
        }
        .font(.system(size: 12))
        .frame(width: 408)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var maxBodyHeight: CGFloat { max(300, (NSScreen.main?.visibleFrame.height ?? 900) - 150) }

    private var sourcePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                sourceButton(nil, title: "All", symbol: "square.grid.2x2")
                ForEach(dashboard.sources) { source in
                    sourceButton(source.kind, title: source.kind.displayName, symbol: source.kind.symbol)
                }
            }.padding(.horizontal, 12).padding(.vertical, 10)
        }.frame(height: 48)
    }

    private func sourceButton(_ source: SourceKind?, title: String, symbol: String) -> some View {
        Button { model.selectedSource = source } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(model.selectedSource == source ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).help(source == nil ? "All harnesses and models" : "Show \(title)")
    }

    private var title: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.selectedSource?.displayName ?? "Tobken").font(.system(size: 15, weight: .semibold))
            Spacer()
            Text("Today").foregroundStyle(.secondary)
            Text(Date(), format: .dateTime.month(.abbreviated).day()).foregroundStyle(.tertiary)
        }
    }

    private var totals: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(MetricFormat.tokens(dashboard.totals.total)).font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit().help("\(MetricFormat.exact(dashboard.totals.total)) tokens")
                Text("tokens today").foregroundStyle(.secondary)
                Spacer()
            }
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    Capsule().fill(green).frame(width: max(0, geometry.size.width * inputFraction - 1))
                    Capsule().fill(green.opacity(0.35))
                }
            }.frame(height: 5).accessibilityLabel("Input and output token proportions")
            HStack {
                dot(green)
                Text("\(MetricFormat.tokens(dashboard.totals.input)) input")
                Spacer()
                dot(green.opacity(0.35))
                Text("\(MetricFormat.tokens(dashboard.totals.output)) output")
            }.foregroundStyle(.secondary)
            HStack {
                Text("\(MetricFormat.tokens(dashboard.totals.cachedInput)) cached")
                    .help("Cache reads are included in input. Cache writes and reasoning are included in their respective input/output totals.")
                Spacer()
                Text("\(MetricFormat.exact(dashboard.totals.requests)) requests")
            }.font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    private var inputFraction: Double {
        dashboard.totals.total > 0 ? Double(dashboard.totals.input) / Double(dashboard.totals.total) : 0
    }

    private var live: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Circle().fill(dashboard.liveTPS > 0 ? green : Color.secondary.opacity(0.35)).frame(width: 5, height: 5)
                    Text("Current TPS").foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(MetricFormat.rate(dashboard.currentTPS))
                        .font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("TPS").foregroundStyle(.secondary)
                }
            }.help("Output tokens per second across concurrent requests, over a trailing 3-second window. Rates are reconstructed from transcript timing; in-flight requests use recent response rates.")
            Spacer(minLength: 0)
            if model.selectedSource == nil {
                TPSChart(history: model.tpsHistory, color: green)
            }
            VStack(alignment: .trailing, spacing: 4) {
                Text("Avg TPS").foregroundStyle(.secondary)
                Text(MetricFormat.rate(dashboard.summary.averageTPS)).monospacedDigit().fontWeight(.medium)
            }.help("Today's output tokens divided by summed request durations. Includes waiting for the first token; concurrent requests are averaged by duration.")
        }
        .padding(.top, 1)
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Models").fontWeight(.semibold)
                Spacer()
                Text("\(dashboard.models.count)").foregroundStyle(.tertiary)
            }
            if dashboard.models.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No tokens recorded today").foregroundStyle(.secondary)
                    Text("Activity appears here as your tools write their logs.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }.padding(.vertical, 10)
            } else {
                HStack(spacing: 0) {
                    Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Tokens").frame(width: 57, alignment: .trailing)
                    Text("TPS").frame(width: 54, alignment: .trailing)
                    Text("TTFT").frame(width: 67, alignment: .trailing)
                }.font(.system(size: 10)).foregroundStyle(.tertiary)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(dashboard.models) { row in modelRow(row) }
                    }
                }.frame(height: modelListHeight)
            }
        }
    }

    private var modelListHeight: CGFloat {
        min(260, CGFloat(dashboard.models.count) * 52 + CGFloat(dashboard.models.filter { expanded.contains($0.id) }.count) * 116)
    }

    private func modelRow(_ row: ModelRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
            } label: {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: expanded.contains(row.id) ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                            Text(row.name).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        }
                        Text(([row.sources.map(\.displayName).joined(separator: ", ")] + [row.provider].compactMap { $0 }).joined(separator: " · "))
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(MetricFormat.tokens(row.metrics.totals.total)).frame(width: 57, alignment: .trailing)
                    Text(MetricFormat.rate(row.metrics.averageTPS)).frame(width: 54, alignment: .trailing)
                        .help("Average TPS today, including TTFT. Expand for current TPS and sample counts.")
                    Text(MetricFormat.latency(row.metrics.ttftP50)).frame(width: 67, alignment: .trailing)
                        .help("Approximate median TTFT from first logged content. A dash means the harness did not provide timing.")
                }.monospacedDigit().frame(height: 51).contentShape(Rectangle())
            }.buttonStyle(.plain).help(row.name + (row.provider.map { " · \($0)" } ?? ""))
            if expanded.contains(row.id) {
                VStack(spacing: 7) {
                    detail("Current TPS", MetricFormat.rate(row.metrics.liveTPS))
                    detail("Input / output", "\(MetricFormat.tokens(row.metrics.totals.input)) / \(MetricFormat.tokens(row.metrics.totals.output))")
                    detail("TTFT p95", MetricFormat.latency(row.metrics.ttftP95))
                        .help("Shown with at least 20 timed samples.")
                    detail("Requests · TPS / TTFT samples", "\(row.metrics.totals.requests) · \(row.metrics.timedRequests) / \(row.metrics.latencySamples)")
                    detail("Response p50", MetricFormat.latency(row.metrics.durationP50))
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 5))
                    .padding(.bottom, 8)
            }
            Divider().opacity(0.5)
        }
    }

    private var harnesses: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Harnesses").fontWeight(.semibold)
            ForEach(dashboard.sources.filter { $0.today.total > 0 || $0.live.output > 0 }) { source in
                Button { model.selectedSource = source.kind } label: {
                    HStack(spacing: 7) {
                        Image(systemName: source.kind.symbol).frame(width: 14)
                        Text(source.kind.displayName)
                        Spacer()
                        if source.live.output > 0 {
                            Text("\(MetricFormat.rate(source.live.output)) TPS").foregroundStyle(.secondary)
                        }
                        Text(MetricFormat.tokens(source.today.total)).monospacedDigit()
                        Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.font(.system(size: 11))
    }

    @ViewBuilder private var warning: some View {
        if !model.snapshot.warnings.isEmpty {
            Label("Some activity could not be read", systemImage: "exclamationmark.triangle")
                .font(.system(size: 10)).foregroundStyle(.orange)
                .help(model.snapshot.warnings.map(\.descriptionForUser).joined(separator: "\n"))
        } else if case .noSources = model.snapshot.state {
            Text("No supported logs found. Add a location in Settings.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Settings…", action: openSettings)
            Spacer()
            if model.isDemo { Text("Demo").foregroundStyle(.tertiary) }
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Rescan logs")
            Button("Quit", action: quit).keyboardShortcut("q")
        }.buttonStyle(.plain).foregroundStyle(.secondary)
            .padding(.horizontal, UsageMenuCardLayout.horizontalPadding).padding(.vertical, 12)
    }

    private func dot(_ color: Color) -> some View { Circle().fill(color).frame(width: 5, height: 5) }
    private func detail(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).monospacedDigit() }
    }
}

private struct MenuContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension MonitorWarning {
    var descriptionForUser: String {
        switch self {
        case .partialHistory: "Some history was unavailable; totals may be incomplete."
        case .unreadableFiles(let count): "\(count) log files could not be opened."
        case .malformedLines(let count): "\(count) log lines could not be read."
        case .unfinalizedUsage(let count): "\(count) requests did not write final usage; totals may be incomplete."
        case .unsupportedFormat(let source): "\(source.displayName) uses an unsupported log format."
        }
    }
}

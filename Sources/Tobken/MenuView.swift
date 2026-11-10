import AgentSpeedCore
import SwiftUI
import TobkenCore

/// Shared sizes for the menu. `UsageMenuCardLayout` (from CodexBar) keeps its own spacing values.
enum MenuMetrics {
    static let width: CGFloat = 408
    static let bodyFont: CGFloat = 12
    static let smallFont: CGFloat = 11
    static let captionFont: CGFloat = 10
    static let visibleModels = 6
    static let tokensColumn: CGFloat = 56
    static let averageColumn: CGFloat = 60
    static let ttftColumn: CGFloat = 60
    /// Room left for the menu bar and the popover's own chrome when capping the scrolling body.
    static let screenMargin: CGFloat = 160
}

enum MenuColors {
    static let input = Color(red: 0.22, green: 0.65, blue: 0.40)
    static let output = Color(red: 0.20, green: 0.56, blue: 0.80)
    static let live = input
}

struct MenuView: View {
    @ObservedObject var model: AppModel
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}
    @State var expanded: Set<ModelRow.ID> = []
    @State private var showAllModels = false
    /// The scrolling body's applied height. It changes only when the menu opens, startup finishes, or the user
    /// changes the layout (filter, expanding a row, "Show more"); live data never resizes the open popover.
    @State private var bodyHeight: CGFloat = 0
    @State private var resizeAllowedUntil = Date.distantFuture
    @State private var picker = PickerScroll()
    private var dashboard: Dashboard { model.dashboard }

    var body: some View {
        VStack(spacing: 0) {
            sourcePicker
            Divider()
            ScrollView {
                content
                    .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
                    .padding(.vertical, 14)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: MenuContentHeight.self, value: geometry.size.height)
                    })
            }
            // A ScrollView has no intrinsic height: size it to its content, capped to the screen.
            .frame(height: min(bodyHeight, maxBodyHeight))
            .onPreferenceChange(MenuContentHeight.self) { height in
                guard height > 0, bodyHeight == 0 || Date() < resizeAllowedUntil else { return }
                bodyHeight = height
            }
            .onAppear { allowResize() }
            .onChange(of: model.selectedSource) { allowResize() }
            .onChange(of: expanded) { allowResize() }
            .onChange(of: showAllModels) { allowResize() }
            .onChange(of: isStarting) { allowResize() }
            Divider()
            footer
        }
        .font(.system(size: MenuMetrics.bodyFont))
        .frame(width: MenuMetrics.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: MenuTotalHeight.self, value: geometry.size.height)
        })
        .onPreferenceChange(MenuTotalHeight.self) { model.menuSizeChanged?($0) }
    }

    private var isStarting: Bool {
        if case .starting = model.snapshot.state { true } else { false }
    }

    /// Lets the body settle to its new height for a moment after a layout change the user expects.
    private func allowResize() { resizeAllowedUntil = Date().addingTimeInterval(0.5) }

    @ViewBuilder private var content: some View {
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
    }

    private var maxBodyHeight: CGFloat {
        max(300, (NSScreen.main?.visibleFrame.height ?? 900) - MenuMetrics.screenMargin - 100)
    }

    // MARK: Header

    /// Scrolls sideways inside the card's padding, so chips never reach the popover's rounded corners. An edge fades
    /// while more chips lie beyond it.
    private var sourcePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                sourceButton(nil, title: "All", symbol: "square.grid.2x2")
                ForEach(dashboard.visibleSources) { source in
                    sourceButton(source.kind, title: source.kind.displayName, symbol: source.kind.symbol)
                }
            }
            // Preferences do not cross a macOS scroll view; geometry callbacks do.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { picker.content = $0 }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { picker.viewport = $0 }
        .mask(edgeFade)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var edgeFade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: picker.hasMoreBefore ? 20 : 0)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: picker.hasMoreAfter ? 20 : 0)
        }
    }

    private func sourceButton(_ source: SourceKind?, title: String, symbol: String) -> some View {
        let selected = model.selectedSource == source
        return Button { model.selectedSource = source } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                Text(title).font(.system(size: MenuMetrics.smallFont, weight: .medium))
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(selected ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(source == nil ? "All harnesses and models" : "Show only \(title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var title: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.selectedSource?.displayName ?? "Tobken").font(.system(size: 15, weight: .semibold))
            Spacer()
            Text("Today").foregroundStyle(.secondary)
            Text(Date(), format: .dateTime.month(.abbreviated).day()).foregroundStyle(.secondary)
        }
    }

    // MARK: Totals

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
                    Capsule().fill(MenuColors.input).frame(width: max(0, geometry.size.width * inputFraction - 1))
                    Capsule().fill(MenuColors.output)
                }
            }
            .frame(height: 5)
            .accessibilityElement()
            .accessibilityLabel("Input and output share")
            .accessibilityValue("\(Int((inputFraction * 100).rounded())) percent input")
            HStack {
                legend(MenuColors.input, "\(MetricFormat.tokens(dashboard.totals.input)) input")
                Spacer()
                legend(MenuColors.output, "\(MetricFormat.tokens(dashboard.totals.output)) output")
            }.foregroundStyle(.secondary)
            HStack {
                Text("\(MetricFormat.tokens(dashboard.totals.cachedInput)) cached")
                    .help("Cache reads are included in input. Cache writes and reasoning are included in their respective input/output totals.")
                Spacer()
                Text("\(MetricFormat.exact(dashboard.totals.requests)) requests")
            }.font(.system(size: MenuMetrics.smallFont)).foregroundStyle(.secondary)
        }
    }

    private var inputFraction: Double {
        dashboard.totals.total > 0 ? Double(dashboard.totals.input) / Double(dashboard.totals.total) : 0
    }

    // MARK: Live

    private var live: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Circle().fill(dashboard.liveTPS > 0 ? MenuColors.live : Color.secondary.opacity(0.35)).frame(width: 5, height: 5)
                        Text("Current TPS").foregroundStyle(.secondary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(MetricFormat.rate(dashboard.currentTPS))
                            .font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit()
                        Text("TPS").foregroundStyle(.secondary)
                    }
                    Text(liveCaption).font(.system(size: MenuMetrics.captionFont)).foregroundStyle(.secondary)
                }.help("Output generated in the last 10 seconds, divided by 10. Output counts once its usage is logged and is placed across the time it was generated. Most tools log usage when a response finishes, so a running response shows up then; nothing is predicted from earlier speeds.")
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Avg TPS").foregroundStyle(.secondary)
                    Text(MetricFormat.rate(dashboard.averageTPS))
                        .font(.system(size: 17, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("today, per request").font(.system(size: MenuMetrics.captionFont)).foregroundStyle(.secondary)
                }.help("Today's output tokens divided by summed request durations. Includes TTFT and pauses within a request. Excludes idle time between requests; concurrent requests are averaged by duration.")
            }
            TPSChart(history: model.selectedHistory, color: MenuColors.live)
        }
        .padding(.top, 1)
    }

    private var liveCaption: String {
        let generating = dashboard.generatingCount
        guard generating > 0 else { return "output, last 10 s" }
        return "\(generating) generating · counted when logged"
    }

    // MARK: Models

    private var breakdown: some View {
        let models = dashboard.models
        let visible = showAllModels ? models : Array(models.prefix(MenuMetrics.visibleModels))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Models").fontWeight(.semibold)
                Spacer()
                Text("\(models.count)").foregroundStyle(.secondary)
            }
            if models.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No tokens recorded today").foregroundStyle(.secondary)
                    Text("Activity appears here as your tools write their logs.")
                        .font(.system(size: MenuMetrics.smallFont)).foregroundStyle(.secondary)
                }.padding(.vertical, 10)
            } else {
                HStack(spacing: 0) {
                    Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Tokens").frame(width: MenuMetrics.tokensColumn, alignment: .trailing)
                    Text("Avg TPS").frame(width: MenuMetrics.averageColumn, alignment: .trailing)
                        .help("Today's output divided by summed request durations, including TTFT.")
                    Text("TTFT").frame(width: MenuMetrics.ttftColumn, alignment: .trailing)
                        .help("Approximate median time to first logged content.")
                }.font(.system(size: MenuMetrics.captionFont)).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(visible) { row in modelRow(row) }
                }
                if models.count > MenuMetrics.visibleModels {
                    Button(showAllModels ? "Show fewer" : "Show \(models.count - MenuMetrics.visibleModels) more") {
                        showAllModels.toggle()
                    }
                    .buttonStyle(.plain).font(.system(size: MenuMetrics.smallFont)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func modelRow(_ row: ModelRow) -> some View {
        let isExpanded = expanded.contains(row.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if isExpanded { expanded.remove(row.id) } else { expanded.insert(row.id) }
            } label: {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                            Text(row.name).font(.system(size: MenuMetrics.smallFont, weight: .medium))
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Text(([row.sources.map(\.displayName).joined(separator: ", ")] + [row.provider].compactMap { $0 }).joined(separator: " · "))
                            .font(.system(size: MenuMetrics.captionFont)).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(MetricFormat.tokens(row.metrics.totals.total)).frame(width: MenuMetrics.tokensColumn, alignment: .trailing)
                    Text(MetricFormat.rate(row.metrics.averageTPS)).frame(width: MenuMetrics.averageColumn, alignment: .trailing)
                        .help("Average TPS today, including TTFT. Expand for current TPS and sample counts.")
                    Text(MetricFormat.latency(row.metrics.ttftP50)).frame(width: MenuMetrics.ttftColumn, alignment: .trailing)
                        .help("Approximate median TTFT from first logged content. A dash means the harness did not provide timing.")
                }.monospacedDigit().frame(height: 46).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(row.name + (row.provider.map { " · \($0)" } ?? ""))
            .accessibilityHint(isExpanded ? "Hide details" : "Show details")
            if isExpanded {
                VStack(spacing: 7) {
                    detail("Current TPS", MetricFormat.rate(row.metrics.liveTPS))
                    detail("Input / output", "\(MetricFormat.tokens(row.metrics.totals.input)) / \(MetricFormat.tokens(row.metrics.totals.output))")
                    detail("TTFT p95", MetricFormat.latency(row.metrics.ttftP95))
                        .help("Shown with at least 20 timed samples.")
                    detail("Requests · TPS / TTFT samples", "\(row.metrics.totals.requests) · \(row.metrics.timedRequests) / \(row.metrics.latencySamples)")
                    detail("Response p50", MetricFormat.latency(row.metrics.durationP50))
                }.font(.system(size: MenuMetrics.captionFont)).foregroundStyle(.secondary)
                    .padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                    .padding(.bottom, 8)
            }
            Divider().opacity(0.5)
        }
    }

    // MARK: Harnesses

    private var harnesses: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Harnesses").font(.system(size: MenuMetrics.bodyFont, weight: .semibold))
            ForEach(dashboard.visibleSources.filter { $0.today.total > 0 || $0.live.output > 0 }) { source in
                Button { model.selectedSource = source.kind } label: {
                    HStack(spacing: 7) {
                        Image(systemName: source.kind.symbol).frame(width: 14)
                        Text(source.kind.displayName)
                        Spacer()
                        if source.live.output > 0 {
                            Text("\(MetricFormat.wholeRate(source.live.output)) TPS now").foregroundStyle(.secondary)
                        }
                        Text(MetricFormat.tokens(source.today.total)).monospacedDigit()
                        Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show only \(source.kind.displayName)")
            }
        }.font(.system(size: MenuMetrics.smallFont))
    }

    @ViewBuilder private var warning: some View {
        if !model.snapshot.warnings.isEmpty {
            Label("Some activity could not be read", systemImage: "exclamationmark.triangle")
                .font(.system(size: MenuMetrics.captionFont)).foregroundStyle(.orange)
                .help(model.snapshot.warnings.map(\.descriptionForUser).joined(separator: "\n"))
        } else if case .noSources = model.snapshot.state {
            Text("No supported logs found. Add a location in Settings.")
                .font(.system(size: MenuMetrics.smallFont)).foregroundStyle(.secondary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Settings…", action: openSettings).keyboardShortcut(",")
            Spacer()
            if model.isDemo { Text("Demo").foregroundStyle(.secondary) }
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("Rescan logs").accessibilityLabel("Rescan logs")
            Button("Quit", action: quit).keyboardShortcut("q")
        }.buttonStyle(.plain).foregroundStyle(.secondary)
            .padding(.horizontal, UsageMenuCardLayout.horizontalPadding).padding(.vertical, 12)
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).monospacedDigit() }
    }
}

/// Where the filter row's content sits relative to its viewport, to fade only the edges with chips beyond them.
private struct PickerScroll: Equatable {
    var content: CGRect = .zero
    var viewport: CGRect = .zero
    var hasMoreBefore: Bool { content.width > 0 && content.minX < viewport.minX - 1 }
    var hasMoreAfter: Bool { content.width > 0 && content.maxX > viewport.maxX + 1 }
}

private struct MenuContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct MenuTotalHeight: PreferenceKey {
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

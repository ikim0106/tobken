import AgentSpeedCore
import AppKit
import SwiftUI
import TobkenCore

@MainActor
final class AppModel: ObservableObject {
    /// Extra locations per harness folder, after the automatic entry that `SourceLocations` always keeps first.
    static let maxExtraLocations = SourceLocations.maxEntries - 1

    @Published var snapshot: SpeedSnapshot = .empty
    @Published var selectedSource: SourceKind?
    @Published var extraPaths: [String: [String]]
    @Published var locationMessage: String?
    /// Harnesses hidden from the menu's filter row and Harnesses list; persisted, and still counted in totals.
    @Published var hiddenSources: Set<SourceKind>
    /// Global current-TPS readings; the menu filter never changes these.
    @Published var tpsHistory = TPSHistory()
    /// The same readings per harness, kept only for harnesses with activity today.
    @Published var sourceHistories: [SourceKind: TPSHistory] = [:]
    let store = SpeedStore()
    private var monitor: LiveMonitor?
    private var listener: UUID?
    let isDemo: Bool
    var statusChanged: ((String) -> Void)?
    var menuSizeChanged: ((CGFloat) -> Void)?

    var dashboard: Dashboard { Dashboard(snapshot: snapshot, selectedSource: selectedSource, hiddenSources: hiddenSources) }

    /// The graph for the open menu: global, or the selected harness's.
    var selectedHistory: TPSHistory {
        guard let selectedSource else { return tpsHistory }
        return sourceHistories[selectedSource] ?? TPSHistory()
    }

    init(demo: Bool = false) {
        isDemo = demo
        extraPaths = demo ? [:] : (UserDefaults.standard.dictionary(forKey: "extraPaths") as? [String: [String]] ?? [:])
        let hidden = demo ? [] : (UserDefaults.standard.stringArray(forKey: "hiddenSources") ?? [])
        hiddenSources = Set(hidden.compactMap(SourceKind.init(rawValue:)))
        if demo {
            snapshot = Demo.snapshot()
            for point in snapshot.history {
                tpsHistory.record(at: point.time, value: point.measured.output + point.estimated.output)
            }
            tpsHistory.record(at: snapshot.timestamp, value: Dashboard(snapshot: snapshot).currentTPS)
            // Scale the demo curve by each harness's share of current output.
            let total = snapshot.live.output
            for source in snapshot.sources where total > 0 {
                var history = TPSHistory()
                for sample in tpsHistory.samples {
                    history.record(at: sample.time, value: sample.value.map { $0 * source.live.output / total })
                }
                sourceHistories[source.kind] = history
            }
        }
    }

    func start() {
        guard !isDemo else { statusChanged?(dashboard.statusTitle); return }
        listener = store.addLiveListener { [weak self] snapshot in
            self?.receive(snapshot)
        }
        let monitor = LiveMonitor(store: store, configuration: configuration)
        self.monitor = monitor
        monitor.start()
    }

    func receive(_ snapshot: SpeedSnapshot) {
        self.snapshot = snapshot
        if snapshot.state == .running {
            if let series = snapshot.observedSeries {
                applySeries(series)
            } else {
                tpsHistory.record(at: snapshot.timestamp, value: Dashboard(snapshot: snapshot).currentTPS)
                recordSources(at: snapshot.timestamp)
            }
        }
        let valid = dashboard.validSelection(selectedSource)
        if valid != selectedSource { selectedSource = valid }
        statusChanged?(dashboard.statusTitle)
    }

    /// Called before the menu opens: every open starts on "All" with an up-to-date graph.
    func prepareMenu() {
        selectedSource = nil
        recordCurrentReading()
    }

    /// Records the current reading at the wall clock. The monitor stops publishing once output is quiet, so the
    /// open menu calls this to keep the graph moving; `TPSHistory` fills the quiet seconds with zeros.
    func recordCurrentReading() {
        guard !isDemo, snapshot.state == .running else { return }
        let now = Date()
        tpsHistory.record(at: now, value: Dashboard(snapshot: snapshot).currentTPS)
        recordSources(at: now)
    }

    /// The collector's last minute replaces the graphs: a completed response fills in the seconds it took.
    private func applySeries(_ series: ObservedSeries) {
        let end = Date(timeIntervalSince1970: Double(series.endMs) / 1_000)
        let step = Double(series.stepMs) / 1_000
        tpsHistory.replace(values: series.total, endingAt: end, step: step)
        let quiet = series.total.map { $0.map { _ in 0.0 } }
        for source in snapshot.sources
        where source.today.total > 0 || series.bySource[source.kind] != nil || sourceHistories[source.kind] != nil {
            sourceHistories[source.kind, default: TPSHistory()]
                .replace(values: series.bySource[source.kind] ?? quiet, endingAt: end, step: step)
        }
    }

    private func recordSources(at time: Date) {
        for source in snapshot.sources
        where source.today.total > 0 || source.live.output > 0 || sourceHistories[source.kind] != nil {
            sourceHistories[source.kind, default: TPSHistory()].record(at: time, value: source.live.output)
        }
    }

    func stop() { monitor?.stop() }

    func refresh() {
        guard !isDemo else { return }
        resetReadings()
        monitor?.stop()
        monitor?.start()
    }

    private func resetReadings() {
        snapshot = .empty
        tpsHistory = TPSHistory()
        sourceHistories = [:]
        statusChanged?(dashboard.statusTitle)
    }

    private var configuration: MonitorConfiguration {
        var locations = SourceLocations()
        for folder in TranscriptFolder.allCases {
            locations[folder] = [.automatic] + (extraPaths[folder.rawValue] ?? []).map(DataLocation.path)
        }
        return MonitorConfiguration(locations: locations)
    }

    func setShown(_ shown: Bool, for source: SourceKind) {
        if shown { hiddenSources.remove(source) } else { hiddenSources.insert(source) }
        if !isDemo { UserDefaults.standard.set(hiddenSources.map(\.rawValue).sorted(), forKey: "hiddenSources") }
        let valid = dashboard.validSelection(selectedSource)
        if valid != selectedSource { selectedSource = valid }
    }

    func canAddLocation(for folder: TranscriptFolder) -> Bool {
        (extraPaths[folder.rawValue]?.count ?? 0) < Self.maxExtraLocations
    }

    func chooseFolder(for folder: TranscriptFolder) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = folder == .opencode || folder == .zcode || folder == .openclaw
        panel.allowsMultipleSelection = false
        panel.message = "Add a transcript location for \(folder.displayName)."
        guard panel.runModal() == .OK, let path = panel.url?.standardized.path else { return }
        var paths = extraPaths[folder.rawValue] ?? []
        if paths.contains(path) { locationMessage = "\(path) is already added for \(folder.displayName)."; return }
        guard paths.count < Self.maxExtraLocations else {
            locationMessage = "Up to \(Self.maxExtraLocations) extra locations per harness."
            return
        }
        locationMessage = nil
        paths.append(path)
        extraPaths[folder.rawValue] = paths
        saveLocations()
    }

    func removeFolder(_ path: String, for folder: TranscriptFolder) {
        extraPaths[folder.rawValue]?.removeAll { $0 == path }
        if extraPaths[folder.rawValue]?.isEmpty == true { extraPaths[folder.rawValue] = nil }
        locationMessage = nil
        saveLocations()
    }

    private func saveLocations() {
        guard !isDemo else { return }
        UserDefaults.standard.set(extraPaths, forKey: "extraPaths")
        resetReadings()
        monitor?.update(configuration: configuration)
    }
}

extension TranscriptFolder {
    var displayName: String { sources.map(\.displayName).joined(separator: " / ") }
}

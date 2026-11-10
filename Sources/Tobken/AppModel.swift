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
    /// List prices: the bundled table, then any newer table downloaded by `checkPrices`.
    let priceBook = PriceBook()
    @Published var showCosts: Bool { didSet { UserDefaults.standard.set(showCosts, forKey: "showCosts") } }
    @Published var updatesPrices: Bool { didSet { UserDefaults.standard.set(updatesPrices, forKey: "updatesPrices") } }
    @Published private(set) var priceStatus = ""
    private var checkingPrices = false
    private let launchedAt = Date()
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
        UserDefaults.standard.register(defaults: ["showCosts": true, "updatesPrices": true])
        showCosts = demo || UserDefaults.standard.bool(forKey: "showCosts")
        updatesPrices = !demo && UserDefaults.standard.bool(forKey: "updatesPrices")
        if !demo, let table = Self.priceStore.loadTable() { _ = priceBook.add(table) }
        priceStatus = describePrices(checked: demo ? nil : Self.priceStore.loadState())
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
        let monitor = LiveMonitor(store: store, configuration: configuration, pricing: priceBook)
        self.monitor = monitor
        monitor.start()
        // The upstream schedule waits a minute after launch; check once then, and again whenever the menu opens.
        DispatchQueue.main.asyncAfter(deadline: .now() + PriceTableSync.launchDelay + 1) { [weak self] in
            self?.checkPrices()
        }
    }

    // MARK: Prices

    static var appDataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tobken", isDirectory: true)
    }

    static var priceStore: PriceTableStore { PriceTableStore(appDataDirectory: appDataDirectory) }

    /// Downloads a newer public price table when one is due (daily), or now when `force` is set. Sends a plain GET
    /// with a generic user agent; nothing about the user or their usage leaves the machine.
    func checkPrices(force: Bool = false) {
        guard !isDemo, updatesPrices || force, !checkingPrices else { return }
        let store = Self.priceStore
        let due = PriceTableSync.nextAttempt(launchedAt: launchedAt, state: store.loadState(), now: Date())
        guard force || Date() >= due else { return }
        checkingPrices = true
        priceStatus = "Checking for price updates…"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let sync = PriceTableSync(store: store, transport: URLSessionTransport(), userAgent: "Tobken/\(version)")
        let current = priceBook.currentVersion
        Task { [weak self] in
            let result = await sync.run(currentVersion: current)
            guard let self else { return }
            if let table = result.table { _ = self.priceBook.add(table) }
            self.checkingPrices = false
            self.priceStatus = self.describePrices(checked: result.state, outcome: result.outcome)
        }
    }

    private func describePrices(checked state: PriceSyncState?, outcome: PriceSyncOutcome? = nil) -> String {
        let table = priceBook.current
        var text = "Price table \(table.version), updated \(table.updated)"
        if case .failed(let reason) = outcome { return text + " · last check failed (\(reason))" }
        if case .newerSchema = outcome { return text + " · a newer table needs a Tobken update" }
        if let success = state?.lastSuccessMs {
            let date = Date(timeIntervalSince1970: Double(success) / 1_000)
            text += " · checked " + date.formatted(.relative(presentation: .named))
        } else if !updatesPrices {
            text += " · bundled with the app"
        }
        return text
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
        checkPrices()
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

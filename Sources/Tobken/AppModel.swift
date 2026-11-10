import AgentSpeedCore
import AppKit
import SwiftUI
import TobkenCore

@MainActor
final class AppModel: ObservableObject {
    @Published var snapshot: SpeedSnapshot = .empty
    @Published var selectedSource: SourceKind?
    @Published var extraPaths: [String: [String]]
    @Published var tpsHistory = TPSHistory()
    let store = SpeedStore()
    private var monitor: LiveMonitor?
    private var listener: UUID?
    let isDemo: Bool
    var statusChanged: ((String) -> Void)?
    var menuSizeChanged: ((CGFloat) -> Void)?

    var dashboard: Dashboard { Dashboard(snapshot: snapshot, selectedSource: selectedSource) }

    init(demo: Bool = false) {
        isDemo = demo
        extraPaths = demo ? [:] : (UserDefaults.standard.dictionary(forKey: "extraPaths") as? [String: [String]] ?? [:])
        if demo {
            snapshot = Demo.snapshot()
            for point in snapshot.history {
                tpsHistory.record(at: point.time, value: point.measured.output + point.estimated.output)
            }
            tpsHistory.record(at: snapshot.timestamp, value: Dashboard(snapshot: snapshot).currentTPS)
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
            tpsHistory.record(at: snapshot.timestamp, value: Dashboard(snapshot: snapshot).currentTPS)
        }
        statusChanged?(dashboard.statusTitle)
    }

    func prepareMenu() {
        guard !isDemo, snapshot.state == .running else { return }
        tpsHistory.record(at: Date(), value: Dashboard(snapshot: snapshot).currentTPS)
    }

    func stop() { monitor?.stop() }

    func refresh() {
        guard !isDemo else { return }
        snapshot = .empty
        tpsHistory = TPSHistory()
        statusChanged?(dashboard.statusTitle)
        monitor?.stop()
        monitor?.start()
    }

    private var configuration: MonitorConfiguration {
        var locations = SourceLocations()
        for folder in TranscriptFolder.allCases {
            locations[folder] = [.automatic] + (extraPaths[folder.rawValue] ?? []).map(DataLocation.path)
        }
        return MonitorConfiguration(locations: locations)
    }

    func chooseFolder(for folder: TranscriptFolder) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = folder == .opencode || folder == .zcode || folder == .openclaw
        panel.allowsMultipleSelection = false
        panel.message = "Add a transcript location for \(folder.sources.map(\.displayName).joined(separator: " / "))."
        guard panel.runModal() == .OK, let path = panel.url?.standardized.path else { return }
        var paths = extraPaths[folder.rawValue] ?? []
        guard !paths.contains(path), paths.count < SourceLocations.maxEntries - 1 else { return }
        paths.append(path)
        extraPaths[folder.rawValue] = paths
        saveLocations()
    }

    func removeFolder(_ path: String, for folder: TranscriptFolder) {
        extraPaths[folder.rawValue]?.removeAll { $0 == path }
        saveLocations()
    }

    private func saveLocations() {
        guard !isDemo else { return }
        UserDefaults.standard.set(extraPaths, forKey: "extraPaths")
        snapshot = .empty
        tpsHistory = TPSHistory()
        monitor?.update(configuration: configuration)
    }
}

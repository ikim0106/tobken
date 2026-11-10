import AgentSpeedCore
import AppKit
import TobkenCore

/// `--ui-smoke-test <directory>`: drives the real status item, popover and Settings window with demo data.
/// Needs a logged-in macOS desktop session (WindowServer); expectations are derived from `Demo.snapshot()`.
extension AppController {
    func smokeTest(directory: URL) async throws {
        func fail(_ message: String) -> Error { Verification.Failure.assertion(message) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(500))
        let expectedTitle = " " + Dashboard(snapshot: model.snapshot).statusTitle
        let title = statusItem?.button?.title
        guard popover.contentViewController == nil else { throw fail("Closed menu retained its SwiftUI view") }
        guard title == expectedTitle else { throw fail("Status title \(title ?? "nil") ≠ \(expectedTitle)") }
        guard model.tpsHistory.samples.last?.value == model.dashboard.currentTPS else {
            throw fail("Chart endpoint differs from displayed TPS")
        }
        guard let button = statusItem?.button, let action = button.action else {
            throw fail("Status item has no button/action")
        }

        let sent = NSApp.sendAction(action, to: button.target, from: button)
        try await Task.sleep(for: .milliseconds(350))
        guard popover.isShown, let view = popover.contentViewController?.view, view.bounds.height > 300 else {
            throw fail("Action sent=\(sent), dropdown shown=\(popover.isShown), bounds=\(String(describing: popover.contentViewController?.view.bounds))")
        }
        try PreviewRenderer.capture(view, to: directory.appendingPathComponent("native-menu.png"))
        let allHeight = view.bounds.height

        let filter = SourceKind.claudeCode
        let filteredModels = Set(model.snapshot.activities.filter { $0.key.source == filter }
            .map { "\($0.key.model ?? "")|\($0.key.provider ?? "")" }).count
        model.selectedSource = filter
        try await Task.sleep(for: .milliseconds(200))
        guard statusItem?.button?.title == title, model.dashboard.models.count == filteredModels else {
            throw fail("Filter affected global status or showed \(model.dashboard.models.count) of \(filteredModels) models")
        }
        guard view.bounds.height < allHeight else {
            throw fail("Filtered menu did not shrink: all=\(allHeight), filtered=\(view.bounds.height)")
        }
        guard model.selectedHistory == model.sourceHistories[filter] else {
            throw fail("Filtered menu does not graph the selected harness")
        }

        // A new global reading while filtered: the global graph and status follow it; the menu shows the filter.
        var next = model.snapshot
        next.timestamp = next.timestamp.addingTimeInterval(1)
        next.live.output += 20
        next.activities[0].liveTPS += 20
        let expectedFiltered = next.activities.filter { $0.key.source == filter }.reduce(0) { $0 + $1.liveTPS }
        model.receive(next)
        guard model.tpsHistory.samples.last?.value == next.live.output,
              model.dashboard.currentTPS == expectedFiltered,
              statusItem?.button?.title.contains("\(MetricFormat.wholeRate(next.live.output)) TPS") == true else {
            throw fail("Menu filter changed the global TPS history or status")
        }
        try PreviewRenderer.capture(view, to: directory.appendingPathComponent("native-filtered.png"))

        showSettings()
        try await Task.sleep(for: .milliseconds(200))
        guard popover.contentViewController == nil else { throw fail("Closing the menu did not release its view") }
        guard settingsWindow?.isVisible == true, let settingsView = settingsWindow?.contentView else {
            throw fail("Settings did not open")
        }
        try PreviewRenderer.capture(settingsView, to: directory.appendingPathComponent("native-settings.png"))
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }
        let scrollers = scrollViews(in: settingsView) + scrollViews(in: view)
        guard !scrollers.isEmpty, scrollers.allSatisfy({ $0.scrollerStyle == .overlay }) else {
            throw fail("Scrollbars did not use the auto-fading overlay style")
        }
        settingsWindow?.close()
        guard settingsWindow == nil else { throw fail("Closing Settings did not release its window") }

        toggleMenu()
        guard popover.isShown, popover.contentViewController != nil else { throw fail("Menu did not reopen") }
        guard model.selectedSource == nil else { throw fail("Reopened menu kept the previous filter") }
        popover.performClose(nil)
        guard popover.contentViewController == nil else { throw fail("Reopened menu did not release its view") }

        let report: [String: Any] = ["statusTitle": title ?? "", "popoverOpened": true,
                                     "filterPreservedStatus": true, "settingsOpened": true,
                                     "chartEndpointMatchesTPS": true,
                                     "filterPreservedGlobalChart": true,
                                     "filterGraphsSelectedHarness": true,
                                     "reopenResetsFilter": true,
                                     "scrollbarsUseOverlayStyle": true,
                                     "closedViewsReleased": true, "menuReopened": true,
                                     "allHeight": allHeight, "filteredHeight": view.bounds.height]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("ui-smoke.json"))
    }
}

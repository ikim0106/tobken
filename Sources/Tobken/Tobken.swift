import AgentSpeedCore
import AppKit
import SwiftUI
import TobkenCore

@main
enum Tobken {
    @MainActor static func main() {
        let commandLine = CommandLine.arguments
        if commandLine.contains("--verify") {
            Task { @MainActor in
                do { print(try await Verification.run()); exit(0) }
                catch { FileHandle.standardError.write(Data("Verification failed: \(error)\n".utf8)); exit(1) }
            }
            dispatchMain()
        }
        // Keep native scrollbars transient within Tobken, including when using a mouse. The argument domain is
        // volatile and outranks the global preference, so nothing is written to disk; drop the old persisted value.
        UserDefaults.standard.removeObject(forKey: "AppleShowScrollBars")
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleShowScrollBars"] = "WhenScrolling"
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if let index = commandLine.firstIndex(of: "--render-preview"), commandLine.indices.contains(index + 1) {
            do { try PreviewRenderer.render(to: URL(fileURLWithPath: commandLine[index + 1])); exit(0) }
            catch { FileHandle.standardError.write(Data("Preview failed: \(error)\n".utf8)); exit(1) }
        }
        let smokeIndex = commandLine.firstIndex(of: "--ui-smoke-test")
        let smokeDirectory = smokeIndex.flatMap { commandLine.indices.contains($0 + 1) ? commandLine[$0 + 1] : nil }
        let controller = AppController(demo: commandLine.contains("--demo") || smokeIndex != nil, smokeDirectory: smokeDirectory)
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    let model: AppModel
    private(set) var statusItem: NSStatusItem?
    let popover = NSPopover()
    private(set) var settingsWindow: NSWindow?
    private var smokeDirectory: String?
    /// Moves the graph while the menu is open after output goes quiet; never runs with the menu closed.
    private var chartTimer: Timer?

    init(demo: Bool, smokeDirectory: String? = nil) {
        model = AppModel(demo: demo)
        self.smokeDirectory = smokeDirectory
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "Tobken")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            button.title = " " + model.dashboard.statusTitle
            button.target = self
            button.action = #selector(toggleMenu)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Today's tokens across all harnesses · current TPS"
        }
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        model.menuSizeChanged = { [weak self] height in
            guard let self, height > 0, abs(popover.contentSize.height - height) >= 0.5 else { return }
            popover.contentSize = NSSize(width: MenuMetrics.width, height: height)
        }
        model.statusChanged = { [weak self] title in
            self?.updateStatusTitle(title)
            self?.updateChartTimer()
        }
        model.start()
        if let smokeDirectory {
            Task { @MainActor in
                do {
                    try await smokeTest(directory: URL(fileURLWithPath: smokeDirectory))
                    print("PASS: native status item opens dropdown; filter preserves global total; Settings opens.")
                    NSApp.terminate(nil)
                } catch {
                    FileHandle.standardError.write(Data("UI smoke test failed: \(error)\n".utf8))
                    exit(1)
                }
            }
        }
    }

    private func prepareMenu() {
        model.prepareMenu()
        let hostingController = NSHostingController(rootView: MenuView(
            model: model,
            openSettings: { [weak self] in self?.showSettings() },
            quit: { NSApp.terminate(nil) }
        ))
        hostingController.sizingOptions = [.preferredContentSize, .intrinsicContentSize]
        popover.contentViewController = hostingController
        popover.contentSize = hostingController.view.fittingSize
    }

    func applicationWillTerminate(_ notification: Notification) { model.stop() }

    /// Redraws only changed text. While output is active the item only grows (in 8 pt steps), so a reading
    /// moving between "9" and "146 TPS" does not shift neighbouring menu bar items every second.
    private func updateStatusTitle(_ title: String) {
        guard let item = statusItem, let button = item.button else { return }
        let text = " " + title
        if button.title != text { button.title = text }
        // The popover is anchored to this item: while it is open, keep the width (grow only if text would clip).
        if popover.isShown {
            let current = item.length == NSStatusItem.variableLength ? button.intrinsicContentSize.width : item.length
            item.length = max(current, button.intrinsicContentSize.width.rounded(.up))
            return
        }
        guard (Dashboard(snapshot: model.snapshot).currentTPS ?? 0) > 0 else {
            if item.length != NSStatusItem.variableLength { item.length = NSStatusItem.variableLength }
            return
        }
        let needed = (button.intrinsicContentSize.width / 8).rounded(.up) * 8
        if item.length == NSStatusItem.variableLength || needed > item.length { item.length = needed }
    }

    @objc func toggleMenu() {
        guard let button = statusItem?.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            showContextMenu(from: button)
            return
        }
        if popover.isShown { popover.performClose(nil) }
        else {
            prepareMenu()
            // Freeze the anchor's width at what is on screen, so the open popover never slides sideways. A fixed
            // `length` excludes the item's padding (a variable item's button frame includes it), so freeze at the
            // intrinsic width; `button.frame.width` would widen the item by the padding and the popover would
            // jump left on its next resize.
            if let item = statusItem, item.length == NSStatusItem.variableLength {
                item.length = button.intrinsicContentSize.width
            }
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            updateChartTimer()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        updateStatusTitle(model.dashboard.statusTitle)
        updateChartTimer()
    }

    /// The monitor stops publishing once output is quiet, so the open menu records the quiet seconds itself until
    /// the graph is flat. With the menu closed, nothing ticks.
    private func updateChartTimer() {
        let needed = popover.isShown && !model.isDemo && model.tpsHistory.samples.contains { ($0.value ?? 0) > 0 }
        if needed, chartTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.chartTick() }
            }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            chartTimer = timer
        } else if !needed, let timer = chartTimer {
            timer.invalidate()
            chartTimer = nil
        }
    }

    private func chartTick() {
        // While output is active the monitor publishes each second; only fill in once its snapshot goes stale.
        if Date().timeIntervalSince(model.snapshot.timestamp) > 1.5 { model.recordCurrentReading() }
        updateChartTimer()
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Rescan Logs", action: #selector(rescanFromMenu), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Tobken", action: #selector(quitFromMenu), keyEquivalent: "q").target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
    }

    @objc private func openSettingsFromMenu() { showSettings() }
    @objc private func rescanFromMenu() { model.refresh() }
    @objc private func quitFromMenu() { NSApp.terminate(nil) }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow { settingsWindow = nil }
    }

    func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            window.title = "Tobken Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.contentMinSize = NSSize(width: 520, height: 420)
            window.setContentSize(NSSize(width: 580, height: 600))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

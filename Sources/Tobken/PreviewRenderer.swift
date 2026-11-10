import AgentSpeedCore
import AppKit
import SwiftUI
import TobkenCore

/// `--render-preview <directory>`: renders the production SwiftUI views with demo data, in light and dark,
/// without reading user histories or needing a status item.
@MainActor
enum PreviewRenderer {
    static func capture(_ view: NSView, to file: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Verification.Failure.assertion("No bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Verification.Failure.assertion("No PNG") }
        try png.write(to: file)
    }

    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let background = name == "dark" ? Color(red: 0.16, green: 0.16, blue: 0.17) : Color(red: 0.96, green: 0.96, blue: 0.96)
            let all = AppModel(demo: true)
            try render(MenuView(model: all).padding(1).background(background), appearance: appearance,
                       to: directory.appendingPathComponent("tobken-\(name).png"))
            let filtered = AppModel(demo: true)
            filtered.selectedSource = .claudeCode
            try render(MenuView(model: filtered).padding(1).background(background), appearance: appearance,
                       to: directory.appendingPathComponent("tobken-filtered-\(name).png"))
            try render(SettingsView(model: AppModel(demo: true)).frame(width: 580, height: 600), appearance: appearance,
                       to: directory.appendingPathComponent("tobken-settings-\(name).png"))
        }
    }

    private static func render(_ root: some View, appearance: NSAppearance.Name, to file: URL) throws {
        let view = NSHostingView(rootView: root)
        view.appearance = NSAppearance(named: appearance)
        let size = view.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = view.appearance
        window.backgroundColor = NSColor.windowBackgroundColor
        window.contentView = view
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        window.display()
        try capture(view, to: file)
        print(file.path)
        window.close()
    }
}

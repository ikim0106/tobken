import AgentSpeedCore
import ServiceManagement
import SwiftUI
import TobkenCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?
    @State private var showUndetected = false

    private var detected: [TranscriptFolder] { TranscriptFolder.allCases.filter(isDetected) }
    private var undetected: [TranscriptFolder] { TranscriptFolder.allCases.filter { !isDetected($0) } }

    var body: some View {
        Form {
            Section("General") {
                if !model.isDemo {
                    Toggle("Open Tobken at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                    if let launchError {
                        Text(launchError).font(.caption).foregroundStyle(.red)
                    }
                }
                Text("Current TPS is output generated in the last 30 seconds ÷ 30, counted once its usage is logged. Avg TPS includes TTFT. Today resets at local midnight.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show estimated costs", isOn: $model.showCosts)
                if !model.isDemo {
                    Toggle("Update prices daily", isOn: $model.updatesPrices)
                        .onChange(of: model.updatesPrices) { _, enabled in if enabled { model.checkPrices() } }
                    HStack {
                        Text(model.priceStatus).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Check Now") { model.checkPrices(force: true) }
                    }
                }
            } header: {
                Text("Costs")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Costs are estimates at API list prices from token usage; subscription plans are billed differently. Requests without a known price are left out and marked with ≥. Price updates download the public table below once a day; nothing about your usage is sent.")
                    Link("Price table source", destination: PriceTableSync.sourcePage)
                }.font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if menuSources.isEmpty {
                    Text("Harnesses appear here once their logs are found.").foregroundStyle(.secondary)
                }
                ForEach(menuSources, id: \.self) { source in
                    Toggle(isOn: Binding(get: { !model.hiddenSources.contains(source) },
                                         set: { model.setShown($0, for: source) })) {
                        Label(source.displayName, systemImage: source.symbol)
                    }
                }
            } header: {
                Text("Show in menu")
            } footer: {
                Text("Hidden harnesses are left out of the menu's filter row and Harnesses list. Their tokens still count in every total, including the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if detected.isEmpty {
                    Text("No supported logs found yet. Add a location for a harness below.")
                        .foregroundStyle(.secondary)
                }
                ForEach(detected, id: \.rawValue) { folder in folderRow(folder) }
                DisclosureGroup("Not detected (\(undetected.count))", isExpanded: $showUndetected) {
                    ForEach(undetected, id: \.rawValue) { folder in folderRow(folder) }
                }
            } header: {
                Text("Log locations")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Supported harnesses are read automatically. Add locations for logs stored elsewhere.")
                    if let message = model.locationMessage {
                        Text(message).foregroundStyle(.orange)
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Version", value: version)
                LabeledContent("Data") {
                    Text("Local logs · no account or proxy required").foregroundStyle(.secondary)
                }
                Link("Source on GitHub", destination: URL(string: "https://github.com/ikim0106/tobken")!)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, idealWidth: 580, minHeight: 420, idealHeight: 600)
    }

    private func folderRow(_ folder: TranscriptFolder) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(folder.displayName).fontWeight(.medium)
                Spacer()
                Button("Add…") { model.chooseFolder(for: folder) }
                    .disabled(!model.canAddLocation(for: folder))
                    .help(model.canAddLocation(for: folder)
                          ? "Add a log location for \(folder.displayName)"
                          : "Up to \(AppModel.maxExtraLocations) extra locations per harness")
            }
            ForEach(folder.sources) { source in
                if let status = status(for: source), status.available, !status.rootPath.isEmpty {
                    Text(status.rootPath).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(status.rootPath).textSelection(.enabled)
                }
            }
            ForEach(model.extraPaths[folder.rawValue] ?? [], id: \.self) { path in
                HStack {
                    Text(path).font(.caption).lineLimit(1).truncationMode(.middle).help(path)
                    Spacer()
                    Button { model.removeFolder(path, for: folder) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).help("Remove this location").accessibilityLabel("Remove \(path)")
                }.foregroundStyle(.secondary)
            }
        }.padding(.vertical, 2)
    }

    /// Detected or active harnesses, plus any hidden one so it can be shown again.
    private var menuSources: [SourceKind] {
        let listed = Set(model.dashboard.sources.map(\.kind)).union(model.hiddenSources)
        return SourceKind.allCases.filter(listed.contains)
    }

    private func status(for source: SourceKind) -> SourceStatus? {
        model.snapshot.sources.first { $0.kind == source }
    }

    private func isDetected(_ folder: TranscriptFolder) -> Bool {
        folder.sources.contains { status(for: $0)?.available == true } || model.extraPaths[folder.rawValue]?.isEmpty == false
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            launchError = "Could not change login item: \(error.localizedDescription)"
        }
        let actual = SMAppService.mainApp.status
        if actual == .requiresApproval {
            launchError = "Approve Tobken in System Settings → General → Login Items."
        }
        let isEnabled = actual == .enabled || actual == .requiresApproval
        if launchAtLogin != isEnabled { launchAtLogin = isEnabled }
    }
}

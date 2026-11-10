import AgentSpeedCore
import SwiftUI
import TobkenCore

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tobken").font(.title2.bold())
            Text("All supported harnesses are read automatically. Add locations for logs stored elsewhere.")
                .foregroundStyle(.secondary)
            List(TranscriptFolder.allCases, id: \.rawValue) { folder in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(folder.sources.map(\.displayName).joined(separator: " / ")).fontWeight(.medium)
                        Spacer()
                        Button("Add…") { model.chooseFolder(for: folder) }
                    }
                    ForEach(folder.sources) { source in
                        if let status = model.snapshot.sources.first(where: { $0.kind == source }), status.available {
                            Text(status.rootPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    ForEach(model.extraPaths[folder.rawValue] ?? [], id: \.self) { path in
                        HStack {
                            Text(path).font(.caption).lineLimit(1).truncationMode(.middle).help(path)
                            Spacer()
                            Button { model.removeFolder(path, for: folder) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).help("Remove additional location")
                        }.foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 5)
            }.listStyle(.inset)
            Text("TPS counts output. Live rates are approximate; Avg TPS includes TTFT. TTFT uses first logged content when available. Today resets at local midnight.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Local logs · no account or proxy required").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Link("GitHub", destination: URL(string: "https://github.com/ikim0106/tobken")!)
            }
        }.padding(24).frame(width: 590, height: 620)
    }
}

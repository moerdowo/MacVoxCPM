import SwiftUI
import AppKit

struct AppSettingsView: View {
    @Environment(SidecarManager.self) private var sidecar
    @Environment(AudioStore.self) private var store

    @State private var runtimeBytes: Int64 = 0
    @State private var modelsBytes: Int64 = 0
    @State private var outputsBytes: Int64 = 0
    @State private var voicesBytes: Int64 = 0

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gear") }
            storageTab.tabItem { Label("Storage", systemImage: "internaldrive") }
            diagnosticsTab.tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 560, height: 420)
        .task { await refreshSizes() }
    }

    private var generalTab: some View {
        Form {
            Section("Model") {
                LabeledContent("Active model", value: sidecar.status.modelId)
                LabeledContent("Sample rate", value: "\(sidecar.status.sampleRate) Hz")
                LabeledContent("Device", value: sidecar.status.device)
                LabeledContent("Sidecar port",
                               value: sidecar.port.map(String.init) ?? "—")
            }
            Section("Folders") {
                folderRow("Application Support", AppPaths.applicationSupport)
                folderRow("Models cache", AppPaths.modelsDir)
                folderRow("Outputs", AppPaths.outputsDir)
                folderRow("Voices", AppPaths.voicesDir)
            }
        }
        .formStyle(.grouped)
    }

    private var storageTab: some View {
        Form {
            Section("Disk usage") {
                LabeledContent("Python runtime", value: Format.bytes(runtimeBytes))
                LabeledContent("Model weights", value: Format.bytes(modelsBytes))
                LabeledContent("Generated outputs", value: Format.bytes(outputsBytes))
                LabeledContent("Saved voices", value: Format.bytes(voicesBytes))
                LabeledContent("Total",
                    value: Format.bytes(runtimeBytes + modelsBytes + outputsBytes + voicesBytes))
                Button("Refresh") { Task { await refreshSizes() } }
            }
            Section("Cleanup") {
                Button("Re-download model from Hugging Face") {
                    try? FileManager.default.removeItem(at: AppPaths.modelsDir)
                    _ = AppPaths.modelsDir
                    NSApp.terminate(nil)
                }
                .help("Wipes the local model cache and quits — relaunch to re-download.")
                Button(role: .destructive) {
                    try? FileManager.default.removeItem(at: AppPaths.runtimeDir)
                    NSApp.terminate(nil)
                } label: { Text("Uninstall Python runtime and quit") }
                    .help("Removes the Python venv + uv. The model cache is kept.")
            }
        }
        .formStyle(.grouped)
    }

    private var diagnosticsTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sidecar log").font(.headline)
                Spacer()
                Button("Open log file") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.logFile])
                }
            }
            SidecarLogView()
                .frame(maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(12)
    }

    private func folderRow(_ title: String, _ url: URL) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button("Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .buttonStyle(.borderless)
        }
    }

    private func refreshSizes() async {
        let runtime = AppPaths.runtimeDir.path
        let models = AppPaths.modelsDir.path
        let outputs = AppPaths.outputsDir.path
        let voices = AppPaths.voicesDir.path
        let (a, b, c, d) = await Task.detached(priority: .utility) {
            (
                Self.dirBytes(runtime),
                Self.dirBytes(models),
                Self.dirBytes(outputs),
                Self.dirBytes(voices)
            )
        }.value
        await MainActor.run {
            self.runtimeBytes = a
            self.modelsBytes = b
            self.outputsBytes = c
            self.voicesBytes = d
        }
    }

    nonisolated private static func dirBytes(_ path: String) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }
        for case let sub as String in enumerator {
            let full = (path as NSString).appendingPathComponent(sub)
            if let attrs = try? fm.attributesOfItem(atPath: full),
               let size = attrs[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }
}

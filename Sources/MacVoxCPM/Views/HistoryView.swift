import SwiftUI
import AppKit

struct HistoryView: View {
    @Environment(AudioStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let onReplay: (HistoryItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History").font(.title3).bold()
                Spacer()
                Button(role: .destructive) {
                    store.clearHistory()
                } label: { Label("Clear All", systemImage: "trash") }
                    .disabled(store.history.isEmpty)
            }
            .padding(.horizontal, 20).padding(.top, 18)

            if store.history.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .resizable().scaledToFit().frame(width: 56, height: 56)
                        .foregroundStyle(.tertiary)
                    Text("Nothing here yet").font(.headline)
                    Text("Your generated audio shows up here once you press Generate.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.history) { item in
                    row(item)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { onReplay(item) }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 620, minHeight: 460)
    }

    private func row(_ item: HistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.text).lineLimit(2).truncationMode(.tail)
                Spacer()
                Text(Format.duration(item.durationSeconds))
                    .monospacedDigit().font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                badge(item.mode.label)
                if let v = item.voiceName { badge(v) }
                badge("CFG \(String(format: "%.1f", item.settings.cfgValue))")
                badge("ts \(item.settings.inferenceTimesteps)")
                Spacer()
                Text(Format.relativeDate(item.createdAt))
                    .font(.caption).foregroundStyle(.secondary)

                Button {
                    onReplay(item)
                } label: { Image(systemName: "arrow.uturn.left.circle") }
                    .buttonStyle(.borderless)
                    .help("Reload these settings into the generator")

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([item.outputURL])
                } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless)

                Button(role: .destructive) {
                    store.deleteHistory(item)
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private func badge(_ s: String) -> some View {
        Text(s)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.tint.opacity(0.15), in: Capsule())
    }
}

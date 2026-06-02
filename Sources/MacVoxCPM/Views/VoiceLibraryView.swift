import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct VoiceLibraryView: View {
    @Environment(AudioStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var importingURL: URL?
    @State private var importingName: String = ""
    @State private var importingTranscript: String = ""
    @State private var renaming: SavedVoice?
    @State private var renameText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Voice Library").font(.title3).bold()
                Spacer()
                Button {
                    pickFile()
                } label: { Label("Add Voice…", systemImage: "plus") }
            }
            .padding(.horizontal, 20).padding(.top, 18)

            if store.voices.isEmpty {
                emptyState
            } else {
                List(store.voices) { voice in
                    voiceRow(voice)
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("\(store.voices.count) voice\(store.voices.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 540, minHeight: 460)
        .sheet(item: $importingURL) { url in
            importSheet(url: url)
        }
        .sheet(item: $renaming) { v in
            renameSheet(voice: v)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.wave.2")
                .resizable().scaledToFit().frame(width: 60, height: 60)
                .foregroundStyle(.tertiary)
            Text("No saved voices yet").font(.headline)
            Text("Add a short reference clip — 5–15 seconds of clean speech is plenty.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func voiceRow(_ voice: SavedVoice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(voice.name).font(.body)
                HStack(spacing: 8) {
                    Text(Format.relativeDate(voice.createdAt))
                    if voice.transcript != nil { Text("• transcript") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                renameText = voice.name
                renaming = voice
            } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([voice.audioURL])
            } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless)
            Button {
                store.deleteVoice(voice)
            } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
        }
        .padding(.vertical, 4)
    }

    private func importSheet(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save voice").font(.title3).bold()
            Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)

            TextField("Name", text: $importingName)
                .textFieldStyle(.roundedBorder)

            Text("Transcript (optional) — required only for Ultimate Cloning")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $importingTranscript)
                .frame(minHeight: 100)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.4),
                            in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                Button("Cancel") { importingURL = nil }
                Button("Save") {
                    let name = importingName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    let tr = importingTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                    _ = try? store.importVoice(from: url, name: name,
                                               transcript: tr.isEmpty ? nil : tr)
                    importingURL = nil
                    importingName = ""
                    importingTranscript = ""
                }
                .keyboardShortcut(.defaultAction)
                .disabled(importingName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 460)
    }

    private func renameSheet(voice: SavedVoice) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename voice").font(.title3).bold()
            TextField("Name", text: $renameText).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { renaming = nil }
                Button("Rename") {
                    store.renameVoice(voice, to: renameText)
                    renaming = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .wav, .mp3, .mpeg4Audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            importingName = url.deletingPathExtension().lastPathComponent
            importingURL = url
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

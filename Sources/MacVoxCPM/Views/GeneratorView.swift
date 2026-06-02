import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct GeneratorView: View {
    @Environment(SidecarManager.self) private var sidecar
    @Environment(AudioStore.self) private var store

    // Form state
    @State private var text: String = ""
    @State private var mode: VoiceMode = .default
    @State private var voiceDescription: String = ""    // for design mode
    @State private var selectedVoice: SavedVoice?
    @State private var importedVoiceURL: URL?           // ad-hoc, not saved
    @State private var promptTranscript: String = ""

    // Generation state
    @State private var isGenerating: Bool = false
    @State private var generationError: String?
    @State private var lastResult: HistoryItem?

    // Sheets
    @State private var showAdvanced: Bool = false
    @State private var showLibrary: Bool = false
    @State private var showHistory: Bool = false
    @State private var showImportSheet: Bool = false

    @State private var player = AudioPlayer()

    var body: some View {
        HSplitView {
            mainColumn
                .frame(minWidth: 560)
            sidebar
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showHistory = true
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                Button {
                    showLibrary = true
                } label: {
                    Label("Voices", systemImage: "person.wave.2")
                }
                Button {
                    showAdvanced = true
                } label: {
                    Label("Advanced Settings", systemImage: "slider.horizontal.3")
                }
            }
        }
        .sheet(isPresented: $showAdvanced) { AdvancedSettingsView() }
        .sheet(isPresented: $showLibrary) {
            // In a cloning mode, let the user pick a voice straight from the
            // library sheet; otherwise it's just management.
            VoiceLibraryView(onSelect: (mode == .clone || mode == .ultimate)
                ? { voice in
                    selectLibraryVoice(voice)
                    showLibrary = false
                  }
                : nil)
        }
        .sheet(isPresented: $showHistory) {
            HistoryView(onReplay: { item in replayHistory(item) })
        }
    }

    // MARK: - Main column

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            modePicker
            textEditor
            referenceSection
            generateRow

            if let err = generationError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .padding(8)
                    .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            resultPanel
                .frame(maxHeight: .infinity)
        }
        .padding(18)
    }

    private var modePicker: some View {
        Picker("", selection: $mode) {
            ForEach(VoiceMode.allCases) { m in
                Text(m.label).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(mode.blurb).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text("\(text.count) chars")
                    .font(.caption).foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.quaternary.opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 10))
                    .frame(minHeight: 140)
                if text.isEmpty {
                    Text("Type the text you want spoken…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: - Reference / description block

    @ViewBuilder
    private var referenceSection: some View {
        switch mode {
        case .default:
            EmptyView()

        case .design:
            VStack(alignment: .leading, spacing: 6) {
                Text("Voice description")
                    .font(.subheadline).foregroundStyle(.secondary)
                TextField("e.g. A young woman, gentle and sweet voice",
                          text: $voiceDescription)
                    .textFieldStyle(.roundedBorder)
                Text("Will be prepended to your text as “(\(voiceDescription))…”")
                    .font(.caption).foregroundStyle(.tertiary)
            }

        case .clone, .ultimate:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Reference audio").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("Import file…") { importAdHocVoice() }
                        .buttonStyle(.borderless)
                    if store.voices.isEmpty {
                        Button("Add to Library…") { showLibrary = true }
                            .buttonStyle(.borderless)
                    } else {
                        Menu("From Library…") {
                            ForEach(store.voices) { v in
                                Button {
                                    selectLibraryVoice(v)
                                } label: {
                                    if v.transcript != nil {
                                        Label(v.name, systemImage: "text.bubble")
                                    } else {
                                        Text(v.name)
                                    }
                                }
                            }
                            Divider()
                            Button("Manage Library…") { showLibrary = true }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }

                if let voice = selectedVoice {
                    voiceChip(name: voice.name, source: "Library", clear: {
                        selectedVoice = nil
                    })
                } else if let url = importedVoiceURL {
                    voiceChip(name: url.lastPathComponent, source: "File", clear: {
                        importedVoiceURL = nil
                    })
                } else {
                    Text("Drop a wav/mp3/m4a/flac here, or pick from the library.")
                        .font(.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary.opacity(0.3),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .onDrop(of: [.audio, .fileURL], isTargeted: nil, perform: handleDrop)
                }

                if mode == .ultimate {
                    Text("Transcript of the reference audio")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(.top, 4)
                    TextEditor(text: $promptTranscript)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.quaternary.opacity(0.4),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .frame(minHeight: 70)
                }
            }
        }
    }

    /// Pick a saved voice for cloning. Clears any ad-hoc file selection and,
    /// for Ultimate Clone, pre-fills the transcript if the voice has one.
    private func selectLibraryVoice(_ v: SavedVoice) {
        selectedVoice = v
        importedVoiceURL = nil
        if mode == .ultimate, let t = v.transcript, !t.isEmpty,
           promptTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            promptTranscript = t
        }
    }

    private func voiceChip(name: String, source: String, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform").foregroundStyle(.tint)
            Text(name).lineLimit(1).truncationMode(.middle)
            Text("(\(source))").foregroundStyle(.secondary).font(.caption)
            Spacer()
            Button(action: clear) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Generate

    private var generateRow: some View {
        HStack(spacing: 12) {
            Button {
                Task { await generate() }
            } label: {
                if isGenerating {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Generating…")
                    }
                    .padding(.horizontal, 6)
                } else {
                    Label("Generate", systemImage: "waveform.path.ecg")
                        .padding(.horizontal, 6)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canGenerate || isGenerating)
            .keyboardShortcut(.return, modifiers: [.command])

            Spacer()

            Text("Model: \(sidecar.status.modelId) • SR \(sidecar.status.sampleRate) Hz")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var canGenerate: Bool {
        guard sidecar.phase == .ready else { return false }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch mode {
        case .default:    return true
        case .design:     return !voiceDescription.trimmingCharacters(in: .whitespaces).isEmpty
        case .clone:      return selectedVoice != nil || importedVoiceURL != nil
        case .ultimate:   return (selectedVoice != nil || importedVoiceURL != nil)
                              && !promptTranscript.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func generate() async {
        generationError = nil
        isGenerating = true
        defer { isGenerating = false }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let composedText: String = {
            if mode == .design {
                let desc = voiceDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                let body = trimmed.hasPrefix("(") ? trimmed : trimmed
                return "(\(desc))\(body)"
            }
            return trimmed
        }()

        let refURL: URL? = selectedVoice?.audioURL ?? importedVoiceURL

        let settings = store.settings
        let outFile = "\(timestampStem()).\(settings.outputFormat.ext)"
        let outURL = AppPaths.outputsDir.appendingPathComponent(outFile)

        let req = GenerateAPIRequest(
            text: composedText,
            mode: mode.rawValue,
            reference_audio: (mode == .clone || mode == .ultimate) ? refURL?.path : nil,
            prompt_audio: mode == .ultimate ? refURL?.path : nil,
            prompt_text: mode == .ultimate ? promptTranscript.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            cfg_value: settings.cfgValue,
            inference_timesteps: settings.inferenceTimesteps,
            seed: settings.seedLocked ? settings.seed : nil,
            output_path: outURL.path,
            output_format: settings.outputFormat.rawValue,
            normalize: settings.normalize
        )

        do {
            let resp = try await sidecar.generate(req)
            let item = HistoryItem(
                text: trimmed,
                mode: mode,
                voiceName: selectedVoice?.name ?? importedVoiceURL?.lastPathComponent,
                outputFilename: outFile,
                durationSeconds: resp.duration_seconds,
                elapsedSeconds: resp.elapsed_seconds,
                settings: settings
            )
            store.recordHistory(item)
            lastResult = item
            player.load(outURL)
            player.play()
        } catch {
            generationError = error.localizedDescription
        }
    }

    // MARK: - Result panel

    @ViewBuilder
    private var resultPanel: some View {
        if let result = lastResult {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Result").font(.headline)
                    Spacer()
                    Text(Format.duration(result.durationSeconds))
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    Text("• rendered in \(String(format: "%.1fs", result.elapsedSeconds))")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                WaveformView(
                    url: result.outputURL,
                    progress: player.duration > 0 ? player.currentTime / player.duration : 0,
                    onScrub: { f in player.seek(to: f * player.duration) }
                )
                HStack(spacing: 10) {
                    Button {
                        player.toggle()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .resizable().frame(width: 32, height: 32)
                    }
                    .buttonStyle(.borderless)

                    Text("\(Format.duration(player.currentTime)) / \(Format.duration(player.duration))")
                        .monospacedDigit().font(.caption).foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        revealInFinder(result.outputURL)
                    } label: { Label("Reveal", systemImage: "folder") }

                    Button {
                        saveAs(result.outputURL)
                    } label: { Label("Save As…", systemImage: "square.and.arrow.down") }

                    Button {
                        Task { await generate() }
                    } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
                        .disabled(!canGenerate || isGenerating)
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        } else {
            VStack(spacing: 8) {
                Image(systemName: "waveform").resizable().scaledToFit()
                    .frame(width: 48, height: 48)
                    .foregroundStyle(.tertiary)
                Text("Your generated audio will appear here.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tips").font(.headline)
            tipBlock(title: "Mix description + voice",
                     body: "In Voice Clone mode you can still steer style by prepending a control like (slightly faster, cheerful tone) to your text.")
            tipBlock(title: "Long text",
                     body: "VoxCPM2 handles paragraphs, but very long passages may benefit from being split into 1–2 sentence chunks.")
            tipBlock(title: "Reproducibility",
                     body: "Lock the seed in Advanced Settings to compare two prompts side-by-side with the same voice draw.")
            Spacer()

            Divider()
            Label("Storage", systemImage: "internaldrive")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Text("Outputs")
                Spacer()
                Button("Reveal") { revealInFinder(AppPaths.outputsDir) }
                    .buttonStyle(.borderless)
            }
            .font(.caption)
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func tipBlock(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).bold()
            Text(body).font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Helpers

    private func timestampStem() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "voxcpm-\(f.string(from: .now))"
    }

    private func importAdHocVoice() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .wav, .mp3, .mpeg4Audio]
        if panel.runModal() == .OK, let url = panel.url {
            importedVoiceURL = url
            selectedVoice = nil
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil)
            else { return }
            DispatchQueue.main.async {
                self.importedVoiceURL = url
                self.selectedVoice = nil
            }
        }
        return true
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func saveAs(_ src: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = src.lastPathComponent
        panel.allowedContentTypes = [.wav, .audio]
        if panel.runModal() == .OK, let dst = panel.url {
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: src, to: dst)
        }
    }

    private func replayHistory(_ item: HistoryItem) {
        text = item.text
        mode = item.mode
        store.settings = item.settings
        store.persistSettings()
        lastResult = item
        player.load(item.outputURL)
        showHistory = false
    }
}

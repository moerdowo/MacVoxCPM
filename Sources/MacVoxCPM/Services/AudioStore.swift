import Foundation
import Observation

/// Disk-backed store for saved reference voices, generation history, and the
/// user's persisted Advanced Settings.
@MainActor
@Observable
final class AudioStore {

    var voices: [SavedVoice] = []
    var history: [HistoryItem] = []
    var settings: AdvancedSettings = .defaults

    init() {
        load()
    }

    // MARK: - Load / save

    private func load() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: AppPaths.voicesIndexFile),
           let arr = try? dec.decode([SavedVoice].self, from: data) {
            voices = arr
        }
        if let data = try? Data(contentsOf: AppPaths.historyFile),
           let arr = try? dec.decode([HistoryItem].self, from: data) {
            history = arr
        }
        if let data = try? Data(contentsOf: AppPaths.settingsFile),
           let s = try? dec.decode(AdvancedSettings.self, from: data) {
            settings = s
        }
    }

    private func persistVoices() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(voices) {
            try? data.write(to: AppPaths.voicesIndexFile, options: .atomic)
        }
    }

    private func persistHistory() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(history) {
            try? data.write(to: AppPaths.historyFile, options: .atomic)
        }
    }

    func persistSettings() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(settings) {
            try? data.write(to: AppPaths.settingsFile, options: .atomic)
        }
    }

    // MARK: - Voices

    @discardableResult
    func importVoice(from src: URL, name: String, transcript: String? = nil) throws -> SavedVoice {
        let fm = FileManager.default
        let ext = src.pathExtension.isEmpty ? "wav" : src.pathExtension
        let filename = "\(UUID().uuidString).\(ext)"
        let dst = AppPaths.voicesDir.appendingPathComponent(filename)
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.copyItem(at: src, to: dst)
        let voice = SavedVoice(name: name, audioFilename: filename, transcript: transcript)
        voices.append(voice)
        persistVoices()
        return voice
    }

    func deleteVoice(_ voice: SavedVoice) {
        try? FileManager.default.removeItem(at: voice.audioURL)
        voices.removeAll { $0.id == voice.id }
        persistVoices()
    }

    func renameVoice(_ voice: SavedVoice, to name: String) {
        guard let idx = voices.firstIndex(where: { $0.id == voice.id }) else { return }
        voices[idx].name = name
        persistVoices()
    }

    func updateTranscript(_ voice: SavedVoice, transcript: String?) {
        guard let idx = voices.firstIndex(where: { $0.id == voice.id }) else { return }
        voices[idx].transcript = transcript?.isEmpty == true ? nil : transcript
        persistVoices()
    }

    // MARK: - History

    func recordHistory(_ item: HistoryItem) {
        history.insert(item, at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        persistHistory()
    }

    func deleteHistory(_ item: HistoryItem) {
        try? FileManager.default.removeItem(at: item.outputURL)
        history.removeAll { $0.id == item.id }
        persistHistory()
    }

    func clearHistory() {
        for item in history {
            try? FileManager.default.removeItem(at: item.outputURL)
        }
        history.removeAll()
        persistHistory()
    }
}

// MARK: - Format helpers

enum Format {
    static func bytes(_ count: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        return fmt.string(fromByteCount: count)
    }

    static func duration(_ seconds: Double) -> String {
        if !seconds.isFinite || seconds < 0 { return "—" }
        let total = Int(seconds.rounded())
        let m = total / 60, s = total % 60
        if m == 0 { return String(format: "%d.%01ds", Int(seconds), Int((seconds - floor(seconds)) * 10)) }
        return String(format: "%d:%02d", m, s)
    }

    static func relativeDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: .now)
    }
}

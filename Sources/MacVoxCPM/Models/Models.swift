import Foundation

// MARK: - Voice modes

enum VoiceMode: String, CaseIterable, Codable, Identifiable {
    case `default`      // model picks
    case design         // (description)Text...
    case clone          // reference audio only
    case ultimate       // reference + prompt audio + transcript

    var id: String { rawValue }

    var label: String {
        switch self {
        case .default:  return "Default"
        case .design:   return "Voice Design"
        case .clone:    return "Voice Clone"
        case .ultimate: return "Ultimate Clone"
        }
    }

    var blurb: String {
        switch self {
        case .default:  return "Let the model pick a voice."
        case .design:   return "Describe the voice in natural language."
        case .clone:    return "Clone the timbre of a short reference clip."
        case .ultimate: return "Reference clip + matching transcript for maximum fidelity."
        }
    }
}

// MARK: - Advanced generation settings

struct AdvancedSettings: Codable, Equatable, Hashable {
    var cfgValue: Double = 2.0
    var inferenceTimesteps: Int = 10
    var seed: Int = 0
    var seedLocked: Bool = false
    var device: Device = .auto
    var outputFormat: OutputFormat = .wav
    var normalize: Bool = false

    enum Device: String, Codable, CaseIterable, Identifiable {
        case auto, mps, cpu
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: return "Auto"
            case .mps:  return "Apple Silicon (MPS)"
            case .cpu:  return "CPU"
            }
        }
    }

    enum OutputFormat: String, Codable, CaseIterable, Identifiable {
        case wav, flac
        var id: String { rawValue }
        var label: String { rawValue.uppercased() }
        var ext: String { rawValue }
    }

    static let defaults = AdvancedSettings()
}

// MARK: - Voice library

struct SavedVoice: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var audioFilename: String          // relative to AppPaths.voicesDir
    var transcript: String?            // optional, enables ultimate-clone
    var createdAt: Date

    init(id: UUID = UUID(), name: String, audioFilename: String,
         transcript: String? = nil, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.audioFilename = audioFilename
        self.transcript = transcript
        self.createdAt = createdAt
    }

    var audioURL: URL { AppPaths.voicesDir.appendingPathComponent(audioFilename) }
}

// MARK: - History

struct HistoryItem: Codable, Identifiable, Hashable {
    var id: UUID
    var createdAt: Date
    var text: String
    var mode: VoiceMode
    var voiceName: String?
    var outputFilename: String         // relative to AppPaths.outputsDir
    var durationSeconds: Double
    var elapsedSeconds: Double
    var settings: AdvancedSettings

    init(id: UUID = UUID(), createdAt: Date = .now, text: String, mode: VoiceMode,
         voiceName: String?, outputFilename: String, durationSeconds: Double,
         elapsedSeconds: Double, settings: AdvancedSettings) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.mode = mode
        self.voiceName = voiceName
        self.outputFilename = outputFilename
        self.durationSeconds = durationSeconds
        self.elapsedSeconds = elapsedSeconds
        self.settings = settings
    }

    var outputURL: URL { AppPaths.outputsDir.appendingPathComponent(outputFilename) }
}

// MARK: - Sidecar status (mirrors GET /status)

struct SidecarStatus: Codable, Equatable {
    var stage: String
    var message: String
    var error: String?
    var progress: Double
    var bytesDownloaded: Int64
    var bytesTotal: Int64
    var modelId: String
    var device: String
    var sampleRate: Int
    var ready: Bool

    enum CodingKeys: String, CodingKey {
        case stage, message, error, progress
        case bytesDownloaded = "bytes_downloaded"
        case bytesTotal = "bytes_total"
        case modelId = "model_id"
        case device
        case sampleRate = "sample_rate"
        case ready
    }

    static let unknown = SidecarStatus(
        stage: "unknown", message: "Connecting to sidecar…", error: nil, progress: 0,
        bytesDownloaded: 0, bytesTotal: 0, modelId: "openbmb/VoxCPM2",
        device: "auto", sampleRate: 48_000, ready: false
    )
}

// MARK: - Generate request/response (mirrors /generate)

struct GenerateAPIRequest: Codable {
    var text: String
    var mode: String
    var reference_audio: String?
    var prompt_audio: String?
    var prompt_text: String?
    var cfg_value: Double
    var inference_timesteps: Int
    var seed: Int?
    var output_path: String
    var output_format: String
    var normalize: Bool
}

struct GenerateAPIResponse: Codable {
    var output_path: String
    var duration_seconds: Double
    var sample_rate: Int
    var elapsed_seconds: Double
}

// MARK: - Bootstrap phases (drives onboarding UI)

enum BootstrapPhase: Codable, Equatable {
    case notStarted
    case extractingUV
    case creatingVenv
    case installingPackages          // pip install voxcpm
    case startingSidecar
    case downloadingModel(progress: Double, bytes: Int64, total: Int64)
    case loadingModel
    case ready
    case failed(message: String)

    var humanLabel: String {
        switch self {
        case .notStarted:           return "Idle"
        case .extractingUV:         return "Setting up runtime (uv)…"
        case .creatingVenv:         return "Creating Python environment…"
        case .installingPackages:   return "Installing VoxCPM and PyTorch (this takes a few minutes)…"
        case .startingSidecar:      return "Starting the inference server…"
        case .downloadingModel:     return "Downloading VoxCPM2 model from Hugging Face…"
        case .loadingModel:         return "Loading model into memory…"
        case .ready:                return "Ready."
        case .failed(let m):        return "Failed: \(m)"
        }
    }
}

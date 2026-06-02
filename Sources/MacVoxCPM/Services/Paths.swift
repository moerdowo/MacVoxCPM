import Foundation

/// Centralised file-system layout for MacVoxCPM.
///
/// Everything heavy (the Python venv, model weights, generated audio) lives in
/// Application Support so the .app bundle stays tiny and self-contained.
enum AppPaths {
    static let bundleIdentifier = "id.macvoxcpm.app"

    static var applicationSupport: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("MacVoxCPM", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var runtimeDir: URL {
        let url = applicationSupport.appendingPathComponent("runtime", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var venvDir: URL { runtimeDir.appendingPathComponent(".venv", isDirectory: true) }
    static var venvPython: URL { venvDir.appendingPathComponent("bin/python", isDirectory: false) }
    static var uvBinary: URL { runtimeDir.appendingPathComponent("uv", isDirectory: false) }

    /// Where the sidecar Python source is laid out on disk so uv/python can
    /// import it (`server.py` is run directly).
    static var sidecarDir: URL {
        let url = runtimeDir.appendingPathComponent("sidecar", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var sidecarScript: URL { sidecarDir.appendingPathComponent("server.py") }

    static var modelsDir: URL {
        let url = applicationSupport.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var voicesDir: URL {
        let url = applicationSupport.appendingPathComponent("voices", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var outputsDir: URL {
        let url = applicationSupport.appendingPathComponent("outputs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var logFile: URL { runtimeDir.appendingPathComponent("sidecar.log") }
    /// Written only after `uv pip install` succeeds, so a partially-installed
    /// venv (e.g. killed mid-install) is correctly re-installed on next launch.
    static var installMarker: URL { runtimeDir.appendingPathComponent(".install-ok") }
    static var historyFile: URL { applicationSupport.appendingPathComponent("history.json") }
    static var voicesIndexFile: URL { applicationSupport.appendingPathComponent("voices.json") }
    static var settingsFile: URL { applicationSupport.appendingPathComponent("settings.json") }
}

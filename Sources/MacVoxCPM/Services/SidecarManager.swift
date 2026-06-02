import Foundation
import Observation
import OSLog

/// Owns the lifecycle of the Python sidecar process.
///
/// On first launch:
///   1. Extract the bundled `uv` binary into AppPaths.runtimeDir
///   2. Copy the sidecar Python source there too
///   3. `uv venv` to create a Python 3.11 env
///   4. `uv pip install -r requirements` (i.e. voxcpm + fastapi + uvicorn)
///   5. Launch `python server.py --port 0`
///   6. Scrape stdout for `MACVOXCPM_PORT=<n>` and start polling /status
///
/// On subsequent launches steps 1–4 are skipped if the marker file exists.
@MainActor
@Observable
final class SidecarManager {

    // MARK: - Public observable state

    var phase: BootstrapPhase = .notStarted
    var status: SidecarStatus = .unknown
    var port: Int? = nil
    var logTail: [String] = []   // last ~400 lines of sidecar stdout/stderr
    var isShuttingDown = false

    /// `true` once `uv pip install` finished cleanly on a previous run. Used
    /// to skip the (slow) install step on subsequent launches.
    var hasInstalledRuntime: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: AppPaths.venvPython.path)
            && fm.fileExists(atPath: AppPaths.installMarker.path)
    }

    // MARK: - Private

    private let log = Logger(subsystem: AppPaths.bundleIdentifier, category: "sidecar")
    private var process: Process?
    private var pollTask: Task<Void, Never>?
    private var stdoutBuffer = ""
    private var stderrBuffer = ""
    private let queue = DispatchQueue(label: "macvoxcpm.sidecar", qos: .userInitiated)

    // MARK: - Public API

    /// Run the full bootstrap and bring the sidecar up. Safe to call multiple
    /// times; if the sidecar is already healthy, this is essentially a no-op.
    func bootstrapIfNeeded() async {
        guard process == nil else {
            await pollStatusOnce()
            return
        }

        do {
            if !hasInstalledRuntime {
                try await extractUV()
                try await syncSidecarSources()
                // If venv exists but the marker doesn't, the previous install
                // was interrupted — start fresh.
                if FileManager.default.fileExists(atPath: AppPaths.venvDir.path)
                    && !FileManager.default.fileExists(atPath: AppPaths.installMarker.path) {
                    append("removing partial venv")
                    try? FileManager.default.removeItem(at: AppPaths.venvDir)
                }
                try await createVenv()
                try await installPackages()
            } else {
                // Keep sidecar source in sync with what's bundled in case the
                // app was updated.
                try await syncSidecarSources()
            }
            try await startSidecar()
            startPolling()
        } catch {
            log.error("Bootstrap failed: \(String(describing: error), privacy: .public)")
            phase = .failed(message: "\(error)")
        }
    }

    /// Tear the sidecar down. Called from App.willTerminate.
    func shutdown() {
        guard let p = process, p.isRunning else {
            process = nil
            pollTask?.cancel()
            return
        }
        isShuttingDown = true
        // Polite first: hit /shutdown so uvicorn flushes its workers.
        if let port {
            Task.detached { @Sendable in
                var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/shutdown")!)
                req.httpMethod = "POST"
                _ = try? await URLSession.shared.data(for: req)
            }
        }
        // Then a hard stop after a beat, in case the polite path is wedged.
        let proc = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            if let proc, proc.isRunning { proc.terminate() }
        }
        pollTask?.cancel()
    }

    // MARK: - Steps

    private func extractUV() async throws {
        phase = .extractingUV
        let fm = FileManager.default
        let dst = AppPaths.uvBinary
        if !fm.fileExists(atPath: dst.path) {
            guard let src = Bundle.module.url(forResource: "uv", withExtension: nil) else {
                throw SidecarError.missingResource("uv binary not bundled — run scripts/fetch-uv.sh")
            }
            try fm.copyItem(at: src, to: dst)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
        }
        append("uv ready at \(dst.path)")
    }

    private func syncSidecarSources() async throws {
        // SwiftPM `.process("Resources")` flattens our subdirectory, so look
        // each file up individually rather than walking a directory.
        let fm = FileManager.default
        let pieces: [(name: String, ext: String)] = [
            ("server", "py"),
            ("pyproject", "toml"),
        ]
        for (name, ext) in pieces {
            guard let src = Bundle.module.url(forResource: name, withExtension: ext) else {
                throw SidecarError.missingResource("\(name).\(ext) not bundled")
            }
            let dst = AppPaths.sidecarDir.appendingPathComponent("\(name).\(ext)")
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
        }
        append("sidecar source synced to \(AppPaths.sidecarDir.path)")
    }

    private func createVenv() async throws {
        phase = .creatingVenv
        let result = try await runOneShot(
            executable: AppPaths.uvBinary,
            arguments: ["venv", "--python", "3.11", AppPaths.venvDir.path],
            cwd: AppPaths.runtimeDir,
            env: nil
        )
        if result.code != 0 {
            throw SidecarError.command("uv venv failed (exit \(result.code))\n\(result.stderr)")
        }
        append("venv created at \(AppPaths.venvDir.path)")
    }

    private func installPackages() async throws {
        phase = .installingPackages
        let pyproject = AppPaths.sidecarDir.appendingPathComponent("pyproject.toml")
        // We don't use `uv pip install -e .` because the sidecar source isn't a
        // proper package; instead install the dependencies directly.
        let result = try await runOneShot(
            executable: AppPaths.uvBinary,
            arguments: [
                "pip", "install",
                "--python", AppPaths.venvPython.path,
                "voxcpm",
                "fastapi>=0.110",
                "uvicorn>=0.27",
                "soundfile>=0.12",
                "numpy>=1.26",
                "huggingface_hub>=0.24",
            ],
            cwd: AppPaths.runtimeDir,
            env: nil,
            tail: { [weak self] line in
                Task { @MainActor in self?.append(line) }
            }
        )
        _ = pyproject  // reserved for future `uv pip install -r pyproject` flow
        if result.code != 0 {
            throw SidecarError.command("uv pip install failed (exit \(result.code))\n\(result.stderr.suffix(2000))")
        }
        // Mark the install as complete only after `uv pip install` returns 0,
        // so an interrupted install is re-run on the next launch.
        try? Data().write(to: AppPaths.installMarker, options: .atomic)
        append("packages installed")
    }

    private func startSidecar() async throws {
        phase = .startingSidecar
        let p = Process()
        p.executableURL = AppPaths.venvPython
        p.arguments = [
            AppPaths.sidecarScript.path,
            "--host", "127.0.0.1",
            "--port", "0",
        ]
        p.currentDirectoryURL = AppPaths.sidecarDir

        var env = ProcessInfo.processInfo.environment
        env["MACVOXCPM_MODELS_DIR"] = AppPaths.modelsDir.path
        // huggingface_hub cache lives next to our model dir so the user can
        // wipe everything from Settings → Storage with one click.
        env["HF_HOME"] = AppPaths.modelsDir.appendingPathComponent("hf_home").path
        env["PYTHONUNBUFFERED"] = "1"
        // Use plain HTTP LFS downloads instead of the xet chunked protocol.
        // xet stages chunks in its own cache (so our directory-size progress
        // reads ~0% until each file finalizes) and was measurably slower and
        // flakier here. Direct LFS writes growing *.incomplete files into the
        // model dir, which makes our progress watcher accurate.
        env["HF_HUB_DISABLE_XET"] = "1"
        env["HF_XET_HIGH_PERFORMANCE"] = "0"

        // Reuse the user's existing HF token if they have one — anonymous
        // downloads via xet are heavily rate-limited and "connection
        // struggling" warnings dominate the log.
        if env["HF_TOKEN"] == nil,
           let token = try? String(contentsOf: URL(fileURLWithPath:
               NSString("~/.cache/huggingface/token").expandingTildeInPath),
               encoding: .utf8) {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { env["HF_TOKEN"] = trimmed }
        }

        p.environment = env

        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = String(data: handle.availableData, encoding: .utf8) ?? ""
            guard !chunk.isEmpty, let self else { return }
            Task { @MainActor in self.ingestStdout(chunk) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = String(data: handle.availableData, encoding: .utf8) ?? ""
            guard !chunk.isEmpty, let self else { return }
            Task { @MainActor in self.ingestStderr(chunk) }
        }

        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                self.append("sidecar exited with code \(proc.terminationStatus)")
                if !self.isShuttingDown {
                    self.phase = .failed(message: "sidecar exited unexpectedly")
                }
                self.process = nil
            }
        }

        try p.run()
        process = p
        append("sidecar pid=\(p.processIdentifier)")
    }

    // MARK: - Stream ingestion

    private func ingestStdout(_ chunk: String) {
        stdoutBuffer += chunk
        while let nl = stdoutBuffer.firstIndex(of: "\n") {
            let line = String(stdoutBuffer[..<nl])
            stdoutBuffer.removeSubrange(...nl)
            handleSidecarLine(line)
        }
    }

    private func ingestStderr(_ chunk: String) {
        stderrBuffer += chunk
        while let nl = stderrBuffer.firstIndex(of: "\n") {
            let line = String(stderrBuffer[..<nl])
            stderrBuffer.removeSubrange(...nl)
            handleSidecarLine(line)
        }
    }

    private func handleSidecarLine(_ line: String) {
        append(line)
        // The sidecar prints `MACVOXCPM_PORT=<n>` once uvicorn binds.
        if let range = line.range(of: "MACVOXCPM_PORT=") {
            let tail = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if let n = Int(tail) {
                self.port = n
                append("→ resolved sidecar port: \(n)")
            }
        }
    }

    private func append(_ s: String) {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logTail.append(trimmed)
        if logTail.count > 400 { logTail.removeFirst(logTail.count - 400) }
        log.debug("\(trimmed, privacy: .public)")
        // Also tail to a log file for post-mortem.
        if let data = (trimmed + "\n").data(using: .utf8) {
            try? data.appendToFile(at: AppPaths.logFile)
        }
    }

    // MARK: - Polling /status

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollStatusOnce()
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }
    }

    @discardableResult
    private func pollStatusOnce() async -> Bool {
        guard let port else { return false }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/status")!)
        req.timeoutInterval = 2.0
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let s = try JSONDecoder().decode(SidecarStatus.self, from: data)
            self.status = s
            switch s.stage {
            case "idle":         phase = .startingSidecar
            case "downloading":  phase = .downloadingModel(progress: s.progress,
                                                            bytes: s.bytesDownloaded,
                                                            total: s.bytesTotal)
            case "loading":      phase = .loadingModel
            case "ready":        phase = .ready
            case "error":        phase = .failed(message: s.error ?? "unknown error")
            default:             break
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Generate

    func generate(_ request: GenerateAPIRequest) async throws -> GenerateAPIResponse {
        guard let port else { throw SidecarError.notReady }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/generate")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw SidecarError.command("no HTTP response")
        }
        if http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SidecarError.command("HTTP \(http.statusCode): \(body)")
        }
        return try JSONDecoder().decode(GenerateAPIResponse.self, from: data)
    }
}

// MARK: - Errors

enum SidecarError: LocalizedError {
    case missingResource(String)
    case command(String)
    case notReady

    var errorDescription: String? {
        switch self {
        case .missingResource(let m): return m
        case .command(let m):         return m
        case .notReady:               return "Sidecar isn't ready yet."
        }
    }
}

// MARK: - Helpers

extension SidecarManager {
    /// Run a child process to completion, streaming its output line-by-line.
    fileprivate func runOneShot(executable: URL,
                                arguments: [String],
                                cwd: URL?,
                                env: [String: String]?,
                                tail: (@Sendable (String) -> Void)? = nil) async throws
        -> (code: Int32, stdout: String, stderr: String)
    {
        let q = self.queue
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Int32, String, String), Error>) in
            q.async {
                let p = Process()
                p.executableURL = executable
                p.arguments = arguments
                if let cwd { p.currentDirectoryURL = cwd }
                var merged = ProcessInfo.processInfo.environment
                if let env { for (k, v) in env { merged[k] = v } }
                p.environment = merged

                let outPipe = Pipe(), errPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = errPipe

                let bufs = LineBuffers()
                let outQ = DispatchQueue(label: "macvoxcpm.proc.out")
                let errQ = DispatchQueue(label: "macvoxcpm.proc.err")

                outPipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty { return }
                    let s = String(data: d, encoding: .utf8) ?? ""
                    outQ.async {
                        bufs.appendOut(s)
                        for line in s.split(separator: "\n", omittingEmptySubsequences: true) {
                            tail?(String(line))
                        }
                    }
                }
                errPipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty { return }
                    let s = String(data: d, encoding: .utf8) ?? ""
                    errQ.async {
                        bufs.appendErr(s)
                        for line in s.split(separator: "\n", omittingEmptySubsequences: true) {
                            tail?(String(line))
                        }
                    }
                }

                do {
                    try p.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }
                p.waitUntilExit()
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                outQ.sync {}
                errQ.sync {}
                cont.resume(returning: (p.terminationStatus, bufs.stdout, bufs.stderr))
            }
        }
    }
}

// MARK: - Tiny class so concurrent readability handlers can mutate shared buffers

final class LineBuffers: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var stdout = ""
    private(set) var stderr = ""
    func appendOut(_ s: String) { lock.lock(); stdout += s; lock.unlock() }
    func appendErr(_ s: String) { lock.lock(); stderr += s; lock.unlock() }
}

// MARK: - File append helper

private extension Data {
    func appendToFile(at url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try self.write(to: url)
            return
        }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: self)
    }
}

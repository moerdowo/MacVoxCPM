import SwiftUI

struct OnboardingView: View {
    @Environment(SidecarManager.self) private var sidecar
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                stepList

                progressBlock

                Spacer(minLength: 0)

                HStack {
                    Button {
                        showLog.toggle()
                    } label: {
                        Label(showLog ? "Hide Log" : "Show Log", systemImage: "terminal")
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    Text("Everything is downloaded into ~/Library/Application Support/MacVoxCPM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if showLog {
                SidecarLogView()
                    .frame(height: 220)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .resizable().frame(width: 56, height: 56)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Setting up MacVoxCPM")
                    .font(.title2).bold()
                Text("One-time install. Future launches start in a second or two.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepRow("Set up Python runtime",  reached: stepReached(.creatingVenv),
                    current: phase == .extractingUV || phase == .creatingVenv)
            stepRow("Install VoxCPM (~2 GB)", reached: stepReached(.installingPackages),
                    current: phase == .installingPackages)
            stepRow("Start inference server", reached: stepReached(.startingSidecar),
                    current: phase == .startingSidecar)
            stepRow("Download model from Hugging Face (~5 GB)",
                    reached: stepReached(.downloadingModel(progress: 0, bytes: 0, total: 0)),
                    current: phase.isDownloading)
            stepRow("Load model into memory", reached: stepReached(.loadingModel),
                    current: phase == .loadingModel)
        }
    }

    @ViewBuilder
    private func stepRow(_ title: String, reached: Bool, current: Bool) -> some View {
        HStack(spacing: 10) {
            if current {
                ProgressView().controlSize(.small)
                    .frame(width: 18, height: 18)
            } else if reached {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 18)
            }
            Text(title)
                .foregroundStyle(reached || current ? .primary : .secondary)
            Spacer()
        }
    }

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(phase.humanLabel)
                .font(.headline)

            if case let .downloadingModel(progress, bytes, total) = phase {
                ProgressView(value: progress) {
                    HStack {
                        Text("Downloading model…")
                        Spacer()
                        Text("\(Format.bytes(bytes)) / \(Format.bytes(total))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            } else if phase == .installingPackages {
                ProgressView()
                Text("Installing PyTorch + voxcpm. Grab a coffee — this is the slowest step on first run.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if phase != .ready {
                ProgressView().controlSize(.large)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private var phase: BootstrapPhase { sidecar.phase }

    private func stepReached(_ target: BootstrapPhase) -> Bool {
        phase.rank >= target.rank
    }
}

private extension BootstrapPhase {
    var isDownloading: Bool {
        if case .downloadingModel = self { return true }
        return false
    }

    /// Linear order so we can compare "have we reached this step?".
    var rank: Int {
        switch self {
        case .notStarted:         return 0
        case .extractingUV:       return 1
        case .creatingVenv:       return 2
        case .installingPackages: return 3
        case .startingSidecar:    return 4
        case .downloadingModel:   return 5
        case .loadingModel:       return 6
        case .ready:              return 7
        case .failed:             return 99
        }
    }
}

struct FailureView: View {
    @Environment(SidecarManager.self) private var sidecar

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .resizable().frame(width: 56, height: 56)
                .foregroundStyle(.orange)
            Text("Setup failed").font(.title2).bold()
            if case .failed(let message) = sidecar.phase {
                ScrollView {
                    Text(message)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .frame(maxHeight: 240)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                Button("Show Log") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.logFile])
                }
                Button("Retry") {
                    Task { await sidecar.bootstrapIfNeeded() }
                }
                .keyboardShortcut(.defaultAction)
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct SidecarLogView: View {
    @Environment(SidecarManager.self) private var sidecar

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(sidecar.logTail.enumerated()), id: \.offset) { idx, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(idx)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(Color.black.opacity(0.85))
            .onChange(of: sidecar.logTail.count) { _, new in
                proxy.scrollTo(new - 1, anchor: .bottom)
            }
        }
    }
}

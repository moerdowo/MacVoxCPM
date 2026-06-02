import SwiftUI
import AVFoundation

/// Static-peaks waveform with a movable play-head. Computes peaks once per
/// loaded URL on a background task and caches them.
struct WaveformView: View {
    let url: URL?
    let progress: Double           // 0.0 ... 1.0 playback position
    let onScrub: (Double) -> Void  // 0.0 ... 1.0

    @State private var peaks: [Float] = []
    @State private var loading: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.5))

                if loading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Rendering waveform…").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                } else if !peaks.isEmpty {
                    Canvas { ctx, size in
                        let mid = size.height / 2
                        let count = peaks.count
                        let stepX = size.width / CGFloat(max(count, 1))
                        let playedX = size.width * CGFloat(progress.clamped(0, 1))
                        for (i, peak) in peaks.enumerated() {
                            let x = CGFloat(i) * stepX
                            let h = CGFloat(peak) * (size.height * 0.9)
                            let rect = CGRect(x: x, y: mid - h / 2,
                                              width: max(stepX - 0.5, 0.5), height: h)
                            let played = x < playedX
                            ctx.fill(Path(roundedRect: rect, cornerRadius: 0.5),
                                     with: .color(played ? .accentColor : .gray.opacity(0.55)))
                        }
                        // play-head
                        var head = Path()
                        head.move(to: CGPoint(x: playedX, y: 0))
                        head.addLine(to: CGPoint(x: playedX, y: size.height))
                        ctx.stroke(head, with: .color(.accentColor), lineWidth: 1.2)
                    }
                    .padding(.horizontal, 6)
                } else {
                    Text("No audio").font(.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let frac = value.location.x / max(geo.size.width, 1)
                        onScrub(Double(max(0, min(1, frac))))
                    }
            )
        }
        .frame(height: 80)
        .onChange(of: url) { _, new in
            recompute(url: new)
        }
        .task { recompute(url: url) }
    }

    private func recompute(url: URL?) {
        guard let url else {
            peaks = []
            return
        }
        loading = true
        Task.detached(priority: .userInitiated) {
            let result = Self.computePeaks(for: url, buckets: 600)
            await MainActor.run {
                self.peaks = result
                self.loading = false
            }
        }
    }

    /// Downsample the file into `buckets` peaks (0..1).
    nonisolated private static func computePeaks(for url: URL, buckets: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let format = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0 else { return [] }

        let framesPerBucket = max(Int(totalFrames) / buckets, 1)
        var peaks = [Float](repeating: 0, count: buckets)

        let bufferCapacity = AVAudioFrameCount(min(framesPerBucket * 8, 1 << 16))
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferCapacity) else {
            return []
        }
        var bucketIdx = 0
        var framesSeenInBucket = 0
        var currentPeak: Float = 0

        while file.framePosition < file.length, bucketIdx < buckets {
            do {
                try file.read(into: buf)
            } catch { break }

            let frames = Int(buf.frameLength)
            guard let channelData = buf.floatChannelData else { break }
            let ch = channelData[0]

            var i = 0
            while i < frames {
                let v = abs(ch[i])
                if v > currentPeak { currentPeak = v }
                framesSeenInBucket += 1
                if framesSeenInBucket >= framesPerBucket {
                    peaks[bucketIdx] = currentPeak
                    bucketIdx += 1
                    framesSeenInBucket = 0
                    currentPeak = 0
                    if bucketIdx >= buckets { break }
                }
                i += 1
            }
        }

        // Normalise so the loudest peak is ~1.0.
        if let mx = peaks.max(), mx > 0 {
            peaks = peaks.map { $0 / mx }
        }
        return peaks
    }
}

private extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}

import Foundation
import Observation
import AVFoundation
import AppKit

/// Tiny @Observable wrapper around AVAudioPlayer with the bits SwiftUI cares
/// about (isPlaying, current time, duration). Single-track for v1.
@MainActor
@Observable
final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var url: URL?
    private(set) var duration: Double = 0
    var currentTime: Double = 0
    private(set) var isPlaying: Bool = false

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ url: URL) {
        stop()
        self.url = url
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            p.delegate = self
            self.player = p
            self.duration = p.duration
            self.currentTime = 0
        } catch {
            self.player = nil
            self.duration = 0
            self.currentTime = 0
        }
    }

    func play() {
        guard let p = player else { return }
        if currentTime >= duration { currentTime = 0; p.currentTime = 0 }
        p.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    func toggle() { isPlaying ? pause() : play() }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        currentTime = 0
        isPlaying = false
        stopTimer()
    }

    func seek(to seconds: Double) {
        guard let p = player else { return }
        let clamped = max(0, min(seconds, duration))
        p.currentTime = clamped
        currentTime = clamped
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player else { return }
                self.currentTime = p.currentTime
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = self.duration
            self.stopTimer()
        }
    }
}

import AVFoundation
import Foundation

@MainActor
final class AudioPlayerController: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published var currentTime: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var loadedURL: URL?

    func togglePlayback(for url: URL?) {
        guard let url else { return }

        if loadedURL != url {
            load(url: url)
        }

        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = time
        currentTime = time
    }

    func setPan(_ pan: Float) {
        player?.pan = max(-1, min(1, pan))
    }

    func stop() {
        player?.stop()
        player = nil
        loadedURL = nil
        timer?.invalidate()
        timer = nil
        isPlaying = false
        duration = 0
        currentTime = 0
    }

    func load(url: URL, autoPlay: Bool = false, loop: Bool = false, volume: Float = 1.0) {
        stop()

        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.numberOfLoops = loop ? -1 : 0
            player?.volume = volume
            player?.prepareToPlay()
            duration = player?.duration ?? 0
            loadedURL = url
            if autoPlay {
                play()
            }
        } catch {
            stop()
        }
    }

    private func play() {
        player?.play()
        isPlaying = true
        startTimer()
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = self.player?.currentTime ?? 0
            }
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        currentTime = duration
        timer?.invalidate()
        timer = nil
    }
}

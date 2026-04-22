import AVFoundation
import CoreGraphics
import Foundation

@MainActor
final class AudioPlayerController: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isSpatialPlaybackActive = false
    @Published var currentTime: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var loadedURL: URL?
    private var shouldLoop = false

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
        guard let player, duration > 0 else { return }

        let clampedTime = max(0, min(time, duration))
        player.currentTime = clampedTime
        currentTime = clampedTime
    }

    func setPan(_ pan: Float) {
        player?.pan = max(-1, min(1, pan))
    }

    func setSpatialOffset(_ offset: CGSize) {}

    func stop() {
        invalidateTimer()
        player?.stop()
        player = nil
        loadedURL = nil
        shouldLoop = false
        isPlaying = false
        isSpatialPlaybackActive = false
        duration = 0
        currentTime = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func load(url: URL, autoPlay: Bool = false, loop: Bool = false, volume: Float = 1.0) {
        stop()

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.numberOfLoops = loop ? -1 : 0
            player.volume = volume
            player.prepareToPlay()

            self.player = player
            loadedURL = url
            shouldLoop = loop
            duration = player.duration
            currentTime = 0
            isSpatialPlaybackActive = false

            if autoPlay {
                play()
            }
        } catch {
            stop()
        }
    }

    private func play() {
        guard let player else { return }

        do {
            try preparePlaybackSession()
            if !shouldLoop, duration > 0, player.currentTime >= duration - 0.01 {
                player.currentTime = 0
                currentTime = 0
            }
            guard player.play() else {
                stop()
                return
            }
            isPlaying = true
            startTimer()
        } catch {
            stop()
        }
    }

    private func pause() {
        player?.pause()
        currentTime = player?.currentTime ?? currentTime
        isPlaying = false
        invalidateTimer()
    }

    private func preparePlaybackSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetoothA2DP])
        try session.setActive(true)
    }

    private func startTimer() {
        invalidateTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = self.player?.currentTime ?? self.currentTime
            }
        }
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard !shouldLoop else { return }

        isPlaying = false
        currentTime = duration
        invalidateTimer()
    }
}

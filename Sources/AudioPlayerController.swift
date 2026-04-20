import AVFoundation
import Foundation

@MainActor
final class AudioPlayerController: NSObject, ObservableObject, AVAudioPlayerDelegate {
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

    func load(url: URL) {
        stop()

        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.prepareToPlay()
            duration = player?.duration ?? 0
            loadedURL = url
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
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            currentTime = player?.currentTime ?? 0
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        currentTime = duration
        timer?.invalidate()
        timer = nil
    }
}

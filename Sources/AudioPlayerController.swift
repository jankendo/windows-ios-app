import AVFoundation
import Foundation

@MainActor
final class AudioPlayerController: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published var currentTime: TimeInterval = 0

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    private var audioFile: AVAudioFile?
    private var loopBuffer: AVAudioPCMBuffer?
    private var timer: Timer?
    private var loadedURL: URL?
    private var shouldLoop = false
    private var volume: Float = 1
    private var scheduledStartTime: TimeInterval = 0
    private var pausedTime: TimeInterval = 0
    private var needsScheduling = true

    override init() {
        super.init()
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
        engine.prepare()
    }

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
        guard !shouldLoop, duration > 0 else { return }

        let clampedTime = max(0, min(time, duration))
        currentTime = clampedTime
        pausedTime = clampedTime
        scheduledStartTime = clampedTime
        needsScheduling = true

        if isPlaying {
            playerNode.stop()
            play()
        }
    }

    func setPan(_ pan: Float) {
        playerNode.pan = max(-1, min(1, pan))
    }

    func stop() {
        invalidateTimer()
        playerNode.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        audioFile = nil
        loopBuffer = nil
        loadedURL = nil
        shouldLoop = false
        needsScheduling = true
        scheduledStartTime = 0
        pausedTime = 0
        isPlaying = false
        duration = 0
        currentTime = 0
    }

    func load(url: URL, autoPlay: Bool = false, loop: Bool = false, volume: Float = 1.0) {
        invalidateTimer()
        playerNode.stop()
        engine.stop()

        do {
            let file = try AVAudioFile(forReading: url)
            audioFile = file
            loadedURL = url
            shouldLoop = loop
            self.volume = volume
            duration = Double(file.length) / file.processingFormat.sampleRate
            currentTime = 0
            pausedTime = 0
            scheduledStartTime = 0
            needsScheduling = true
            isPlaying = false
            playerNode.volume = volume

            if loop {
                loopBuffer = try Self.makeLoopBuffer(from: file)
            } else {
                loopBuffer = nil
            }

            if autoPlay {
                play()
            }
        } catch {
            stop()
        }
    }

    private func play() {
        guard loadedURL != nil else { return }

        if !shouldLoop, duration > 0, currentTime >= duration - 0.01 {
            currentTime = 0
            pausedTime = 0
            scheduledStartTime = 0
            needsScheduling = true
        }

        do {
            try preparePlaybackSession()
            try startEngineIfNeeded()

            if needsScheduling {
                try schedulePlayback()
            }

            playerNode.play()
            isPlaying = true
            startTimer()
        } catch {
            stop()
        }
    }

    private func pause() {
        currentTime = playbackPosition()
        pausedTime = currentTime
        playerNode.pause()
        isPlaying = false
        invalidateTimer()
    }

    private func schedulePlayback() throws {
        playerNode.stop()
        playerNode.volume = volume

        if shouldLoop {
            guard let loopBuffer else { throw AudioPlayerError.missingBuffer }
            scheduledStartTime = 0
            pausedTime = 0
            currentTime = 0
            playerNode.scheduleBuffer(loopBuffer, at: nil, options: [.loops], completionHandler: nil)
        } else {
            guard let audioFile else { throw AudioPlayerError.missingFile }

            let sampleRate = audioFile.processingFormat.sampleRate
            let startFrame = AVAudioFramePosition(max(0, min(scheduledStartTime, duration)) * sampleRate)
            let remainingFrames = AVAudioFrameCount(max(0, audioFile.length - startFrame))

            guard remainingFrames > 0 else {
                currentTime = duration
                pausedTime = duration
                isPlaying = false
                return
            }

            playerNode.scheduleSegment(audioFile, startingFrame: startFrame, frameCount: remainingFrames, at: nil) { [weak self] in
                Task { @MainActor in
                    self?.finishPlaybackNaturally()
                }
            }
        }

        needsScheduling = false
    }

    private func finishPlaybackNaturally() {
        guard !shouldLoop else { return }

        invalidateTimer()
        isPlaying = false
        currentTime = duration
        pausedTime = duration
        scheduledStartTime = duration
        needsScheduling = true
    }

    private func playbackPosition() -> TimeInterval {
        guard
            let nodeTime = playerNode.lastRenderTime,
            let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else {
            return pausedTime
        }

        let sampleRate = playerTime.sampleRate
        let elapsed = Double(playerTime.sampleTime) / sampleRate

        if shouldLoop, duration > 0 {
            let wrapped = elapsed.truncatingRemainder(dividingBy: duration)
            return wrapped >= 0 ? wrapped : wrapped + duration
        }

        return min(scheduledStartTime + elapsed, duration)
    }

    private func preparePlaybackSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetoothA2DP])
        try session.setActive(true)
    }

    private func startEngineIfNeeded() throws {
        guard !engine.isRunning else { return }
        try engine.start()
    }

    private func startTimer() {
        invalidateTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = self.playbackPosition()
            }
        }
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }

    private static func makeLoopBuffer(from file: AVAudioFile) throws -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw AudioPlayerError.missingBuffer
        }
        try file.read(into: buffer)
        return buffer
    }
}

private enum AudioPlayerError: Error {
    case missingFile
    case missingBuffer
}

import AVFoundation
import CoreGraphics
import Foundation

@MainActor
final class AudioPlayerController: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isSpatialPlaybackActive = false
    @Published var currentTime: TimeInterval = 0

    private enum PlaybackBackend {
        case none
        case simple
        case spatialLoop
    }

    private let engine = AVAudioEngine()
    private let environmentNode = AVAudioEnvironmentNode()
    private let spatialPlayerNode = AVAudioPlayerNode()

    private var simplePlayer: AVAudioPlayer?
    private var spatialLoopBuffer: AVAudioPCMBuffer?
    private var timer: Timer?
    private var loadedURL: URL?
    private var backend: PlaybackBackend = .none
    private var shouldLoop = false
    private var volume: Float = 1
    private var pausedTime: TimeInterval = 0
    private var spatialNeedsScheduling = true
    private var fallbackValidationTask: Task<Void, Never>?
    private var playbackGeneration = 0

    override init() {
        super.init()
        engine.attach(environmentNode)
        engine.attach(spatialPlayerNode)
        engine.connect(environmentNode, to: engine.mainMixerNode, format: nil)
        configureSpatialEnvironment()
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
        guard backend == .simple, let simplePlayer, duration > 0 else { return }

        let clampedTime = max(0, min(time, duration))
        simplePlayer.currentTime = clampedTime
        currentTime = clampedTime
        pausedTime = clampedTime
    }

    func setPan(_ pan: Float) {
        let clampedPan = max(-1, min(1, pan))
        simplePlayer?.pan = clampedPan

        guard backend == .spatialLoop else { return }
        spatialPlayerNode.position = AVAudio3DPoint(
            x: clampedPan * 2.4,
            y: 0,
            z: -1.35
        )
    }

    func setSpatialOffset(_ offset: CGSize) {
        guard backend == .spatialLoop else { return }

        let normalizedX = max(-1.0, min(1.0, Float(offset.width / 24)))
        let normalizedY = max(-1.0, min(1.0, Float(offset.height / 20)))
        spatialPlayerNode.position = AVAudio3DPoint(
            x: normalizedX * 2.6,
            y: normalizedY * -0.8,
            z: -1.35
        )
    }

    func stop() {
        playbackGeneration += 1
        fallbackValidationTask?.cancel()
        fallbackValidationTask = nil
        invalidateTimer()
        simplePlayer?.stop()
        simplePlayer = nil

        spatialPlayerNode.stop()
        engine.stop()

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        spatialLoopBuffer = nil
        loadedURL = nil
        backend = .none
        shouldLoop = false
        pausedTime = 0
        spatialNeedsScheduling = true
        isPlaying = false
        isSpatialPlaybackActive = false
        duration = 0
        currentTime = 0
    }

    func load(url: URL, autoPlay: Bool = false, loop: Bool = false, volume: Float = 1.0) {
        load(url: url, autoPlay: autoPlay, loop: loop, volume: volume, preferSpatial: true)
    }

    private func load(url: URL, autoPlay: Bool, loop: Bool, volume: Float, preferSpatial: Bool) {
        stop()
        playbackGeneration += 1

        loadedURL = url
        shouldLoop = loop
        self.volume = volume

        do {
            if loop && preferSpatial && supportsSpatialLoopPlaybackRoute() {
                try prepareSpatialLoopPlayback(url: url, volume: volume)
            } else {
                try prepareSimplePlayback(url: url, loop: loop, volume: volume)
            }

            if autoPlay {
                play()
            }
        } catch {
            do {
                try prepareSimplePlayback(url: url, loop: loop, volume: volume)
                if autoPlay {
                    play()
                }
            } catch {
                stop()
            }
        }
    }

    private func play() {
        guard loadedURL != nil else { return }

        do {
            try preparePlaybackSession()

            switch backend {
            case .simple:
                fallbackValidationTask?.cancel()
                fallbackValidationTask = nil
                guard let simplePlayer else { return }
                if !shouldLoop, duration > 0, simplePlayer.currentTime >= duration - 0.01 {
                    simplePlayer.currentTime = 0
                    currentTime = 0
                    pausedTime = 0
                }
                simplePlayer.play()

            case .spatialLoop:
                try startEngineIfNeeded()
                if spatialNeedsScheduling {
                    scheduleSpatialLoopIfNeeded()
                }
                spatialPlayerNode.play()
                scheduleSpatialFallbackValidation()

            case .none:
                return
            }

            isPlaying = true
            startTimer()
        } catch {
            stop()
        }
    }

    private func pause() {
        playbackGeneration += 1
        fallbackValidationTask?.cancel()
        fallbackValidationTask = nil
        currentTime = playbackPosition()
        pausedTime = currentTime

        switch backend {
        case .simple:
            simplePlayer?.pause()
        case .spatialLoop:
            spatialPlayerNode.pause()
        case .none:
            break
        }

        isPlaying = false
        invalidateTimer()
    }

    private func prepareSimplePlayback(url: URL, loop: Bool, volume: Float) throws {
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.numberOfLoops = loop ? -1 : 0
        player.volume = volume
        player.prepareToPlay()

        simplePlayer = player
        backend = .simple
        duration = player.duration
        pausedTime = 0
        currentTime = 0
        isSpatialPlaybackActive = false
    }

    private func prepareSpatialLoopPlayback(url: URL, volume: Float) throws {
        let (buffer, duration) = try Self.makeSpatialLoopBuffer(from: url)

        spatialLoopBuffer = buffer
        backend = .spatialLoop
        self.duration = duration
        pausedTime = 0
        currentTime = 0
        spatialNeedsScheduling = true
        isSpatialPlaybackActive = true

        spatialPlayerNode.stop()
        spatialPlayerNode.volume = volume
        spatialPlayerNode.position = AVAudio3DPoint(x: 0, y: 0, z: -1.35)
        environmentNode.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)

        engine.disconnectNodeOutput(spatialPlayerNode)
        engine.connect(spatialPlayerNode, to: environmentNode, format: buffer.format)
    }

    private func configureSpatialEnvironment() {
        environmentNode.distanceAttenuationParameters.referenceDistance = 0.7
        environmentNode.distanceAttenuationParameters.maximumDistance = 6
        environmentNode.reverbParameters.enable = true
        environmentNode.reverbParameters.level = -10
        environmentNode.outputVolume = 1
    }

    private func scheduleSpatialLoopIfNeeded() {
        guard let spatialLoopBuffer else { return }
        spatialPlayerNode.stop()
        spatialPlayerNode.scheduleBuffer(spatialLoopBuffer, at: nil, options: [.loops], completionHandler: nil)
        spatialNeedsScheduling = false
        pausedTime = 0
        currentTime = 0
    }

    private func playbackPosition() -> TimeInterval {
        switch backend {
        case .simple:
            return simplePlayer?.currentTime ?? pausedTime

        case .spatialLoop:
            guard
                let nodeTime = spatialPlayerNode.lastRenderTime,
                let playerTime = spatialPlayerNode.playerTime(forNodeTime: nodeTime),
                duration > 0
            else {
                return pausedTime
            }

            let elapsed = Double(playerTime.sampleTime) / playerTime.sampleRate
            let wrapped = elapsed.truncatingRemainder(dividingBy: duration)
            return wrapped >= 0 ? wrapped : wrapped + duration

        case .none:
            return pausedTime
        }
    }

    private func preparePlaybackSession() throws {
        let session = AVAudioSession.sharedInstance()
        let mode: AVAudioSession.Mode = backend == .spatialLoop ? .moviePlayback : .default
        try session.setCategory(.playback, mode: mode, options: [.allowAirPlay, .allowBluetoothA2DP])
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

    private func scheduleSpatialFallbackValidation() {
        fallbackValidationTask?.cancel()
        let expectedGeneration = playbackGeneration
        fallbackValidationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self else { return }
            guard self.playbackGeneration == expectedGeneration else { return }
            guard self.backend == .spatialLoop, self.isPlaying, let loadedURL = self.loadedURL else { return }

            let progressed = max(self.currentTime, self.playbackPosition())
            guard progressed < 0.05 else { return }

            self.load(
                url: loadedURL,
                autoPlay: true,
                loop: self.shouldLoop,
                volume: self.volume,
                preferSpatial: false
            )
        }
    }

    private func supportsSpatialLoopPlaybackRoute() -> Bool {
        let supportedOutputPorts: Set<AVAudioSession.Port> = [
            .headphones,
            .bluetoothA2DP,
            .bluetoothHFP,
            .airPlay,
            .carAudio,
            .usbAudio
        ]

        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.contains { supportedOutputPorts.contains($0.portType) }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard backend == .simple, !shouldLoop else { return }

        isPlaying = false
        currentTime = duration
        pausedTime = duration
        invalidateTimer()
    }
}

private extension AudioPlayerController {
    static func makeSpatialLoopBuffer(from url: URL) throws -> (buffer: AVAudioPCMBuffer, duration: TimeInterval) {
        let file = try AVAudioFile(forReading: url)
        let sourceFrameCount = AVAudioFrameCount(file.length)
        guard sourceFrameCount > 0 else {
            throw AudioPlayerError.missingBuffer
        }

        let sourceBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: sourceFrameCount)
        guard let sourceBuffer else {
            throw AudioPlayerError.missingBuffer
        }

        try file.read(into: sourceBuffer)

        let duration = Double(file.length) / file.processingFormat.sampleRate
        if sourceBuffer.format.channelCount == 1 {
            return (sourceBuffer, duration)
        }

        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: file.processingFormat.sampleRate,
            channels: 1,
            interleaved: false
        )
        guard let monoFormat else {
            throw AudioPlayerError.bufferConversionFailed
        }

        let estimatedFrameCapacity = AVAudioFrameCount(
            ceil(Double(sourceBuffer.frameLength) * monoFormat.sampleRate / sourceBuffer.format.sampleRate)
        ) + 1024
        guard let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: estimatedFrameCapacity) else {
            throw AudioPlayerError.missingBuffer
        }

        guard let converter = AVAudioConverter(from: sourceBuffer.format, to: monoFormat) else {
            throw AudioPlayerError.bufferConversionFailed
        }

        var hasProvidedSource = false
        var conversionError: NSError?
        let status = converter.convert(to: monoBuffer, error: &conversionError) { _, outStatus in
            if hasProvidedSource {
                outStatus.pointee = .endOfStream
                return nil
            }

            hasProvidedSource = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if status == .error || monoBuffer.frameLength == 0 {
            throw conversionError ?? AudioPlayerError.bufferConversionFailed
        }

        return (monoBuffer, duration)
    }
}

private enum AudioPlayerError: Error {
    case missingBuffer
    case bufferConversionFailed
}

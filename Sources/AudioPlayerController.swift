import AVFoundation
import CoreGraphics
import Foundation

@MainActor
final class AudioPlayerController: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isSpatialPlaybackActive = false
    @Published private(set) var reactiveLevel: Double = 0.18
    @Published var currentTime: TimeInterval = 0

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var looper: AVPlayerLooper?
    private var loadedURL: URL?
    private var shouldLoop = false
    private var volume: Float = 1
    private var playbackEnvelope: [CGFloat] = []
    private var engine: AVAudioEngine?
    private var enginePlayerNode: AVAudioPlayerNode?
    private var environmentNode: AVAudioEnvironmentNode?
    private var engineProgressTimer: Timer?
    private var engineDuration: TimeInterval = 0
    private var loopRange: ClosedRange<Double>?
    private var spatialPan: Float = 0
    private var spatialOffset: CGSize = .zero
    private var listenerYawDegrees: Double = 0
    private var usesEngineLoop = false
    private let diagnostics = AudioPlaybackDiagnostics.shared

    func togglePlayback(for url: URL?) {
        guard let url else {
            diagnostics.record("toggle ignored: no audio URL")
            return
        }

        diagnostics.record("toggle playback requested for \(url.lastPathComponent)")
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
        guard let player else {
            diagnostics.record("seek ignored: player missing")
            return
        }

        let clampedTime = max(0, min(time, duration))
        let target = CMTime(seconds: clampedTime, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clampedTime
        diagnostics.record("seek -> \(Self.timeString(clampedTime))")
    }

    func setPan(_ pan: Float) {
        spatialPan = max(-1, min(1, pan))
        refreshSpatialPlacement()
    }

    func setSpatialOffset(_ offset: CGSize) {
        spatialOffset = offset
        refreshSpatialPlacement()
    }

    func setListenerYaw(_ yawDegrees: Double) {
        listenerYawDegrees = yawDegrees
        refreshSpatialPlacement()
    }

    func setPlaybackEnvelope(_ samples: [CGFloat]) {
        playbackEnvelope = samples
        reactiveLevel = Double(samples.first ?? 0.18)
    }

    func setVolume(_ volume: Float) {
        self.volume = volume
        player?.volume = volume
        enginePlayerNode?.volume = volume
    }

    func stop() {
        diagnostics.record("stop requested")
        tearDownPlayer(deactivateSession: true)
    }

    func load(
        url: URL,
        autoPlay: Bool = false,
        loop: Bool = false,
        volume: Float = 1.0,
        loopRange: ClosedRange<Double>? = nil
    ) {
        diagnostics.record("load requested: \(Self.fileSummary(for: url))")
        tearDownPlayer(deactivateSession: false)

        loadedURL = url
        shouldLoop = loop
        self.volume = volume
        self.loopRange = loopRange
        duration = Self.assetDuration(for: url)
        currentTime = 0
        reactiveLevel = Double(playbackEnvelope.first ?? 0.18)
        let assetProfile = AudioAssetProfile.inspect(url: url)
        isSpatialPlaybackActive = assetProfile.isTrueSpatialAudio

        if loop, configureEngineLoopIfPossible(url: url, assetProfile: assetProfile) {
            if autoPlay {
                play()
            }
            return
        }

        let item = AVPlayerItem(url: url)
        if loop {
            let queuePlayer = AVQueuePlayer()
            queuePlayer.volume = volume
            queuePlayer.automaticallyWaitsToMinimizeStalling = false
            looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
            player = queuePlayer
            diagnostics.record("loop strategy: AVPlayerLooper enabled for seam-minimized looping")
        } else {
            let player = AVPlayer(playerItem: item)
            player.volume = volume
            player.automaticallyWaitsToMinimizeStalling = false
            self.player = player
        }
        if let player {
            attachObservers(to: player, item: item, url: url)
        }

        diagnostics.record("player created: duration=\(Self.timeString(duration)) loop=\(loop) volume=\(String(format: "%.2f", volume))")
        diagnostics.record(
            assetProfile.isTrueSpatialAudio
                ? "spatial audio playback check: true (\(assetProfile.diagnosticSummary))"
                : "spatial audio playback check: false (\(assetProfile.diagnosticSummary))"
        )

        if autoPlay {
            play()
        }
    }

    private func play() {
        if usesEngineLoop {
            playEngineLoop()
            return
        }

        guard let player else {
            diagnostics.record("play ignored: player missing")
            return
        }

        do {
            try preparePlaybackSession()
            diagnostics.record("play start: route=\(Self.routeDescription())")
            player.play()
            isPlaying = true
            schedulePlaybackProbe()
        } catch {
            diagnostics.record("play failed: session error=\(error.localizedDescription)")
            tearDownPlayer(deactivateSession: true)
        }
    }

    private func pause() {
        if usesEngineLoop {
            enginePlayerNode?.pause()
            currentTime = currentEnginePlaybackTime()
            isPlaying = false
            diagnostics.record("pause at \(Self.timeString(currentTime))")
            return
        }

        player?.pause()
        if let seconds = player?.currentTime().seconds, seconds.isFinite {
            currentTime = seconds
        }
        isPlaying = false
        diagnostics.record("pause at \(Self.timeString(currentTime))")
    }

    private func preparePlaybackSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetoothA2DP])
            try session.setActive(true)
            diagnostics.record("audio session active: category=\(session.category.rawValue) mode=\(session.mode.rawValue) strategy=preferred")
        } catch {
            diagnostics.record("audio session preferred strategy failed: \(error.localizedDescription)")
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowAirPlay, .allowBluetoothA2DP])
            try session.setActive(true)
            diagnostics.record("audio session active: category=\(session.category.rawValue) mode=\(session.mode.rawValue) strategy=compatibility")
        }
    }

    private func attachObservers(to player: AVPlayer, item: AVPlayerItem, url: URL) {
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    let resolvedDuration = item.asset.duration.seconds.isFinite ? item.asset.duration.seconds : self.duration
                    self.duration = resolvedDuration
                    self.diagnostics.record("item ready: \(url.lastPathComponent) duration=\(Self.timeString(resolvedDuration))")
                case .failed:
                    self.diagnostics.record("item failed: \(item.error?.localizedDescription ?? "unknown error")")
                case .unknown:
                    self.diagnostics.record("item status unknown")
                @unknown default:
                    self.diagnostics.record("item status unknown-default")
                }
            }
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                let waitingReason = player.reasonForWaitingToPlay.map { "\($0.rawValue)" } ?? "none"
                self.diagnostics.record("time control -> \(player.timeControlStatus.diagnosticLabel) waiting=\(waitingReason) rate=\(String(format: "%.2f", player.rate))")
            }
        }

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite {
                    self.currentTime = seconds
                    if !self.playbackEnvelope.isEmpty, self.duration > 0 {
                        let progress = max(0, min(seconds / max(self.duration, 0.1), 0.999))
                        let index = min(Int(progress * Double(self.playbackEnvelope.count)), self.playbackEnvelope.count - 1)
                        self.reactiveLevel = Double(self.playbackEnvelope[index])
                    }
                }
            }
        }

        guard !shouldLoop else { return }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isPlaying = false
            self.currentTime = self.duration
            self.diagnostics.record("playback finished")
        }
    }

    private func schedulePlaybackProbe() {
        let expectedURL = loadedURL
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, self.loadedURL == expectedURL, self.isPlaying else { return }

            let current = self.usesEngineLoop ? self.currentEnginePlaybackTime() : (self.player?.currentTime().seconds ?? self.currentTime)
            let rate = self.usesEngineLoop ? (self.isPlaying ? 1 : 0) : (self.player?.rate ?? 0)
            let itemStatus = self.usesEngineLoop ? "engine-loop" : (self.player?.currentItem?.status.diagnosticLabel ?? "nil")
            self.diagnostics.record(
                "play probe: time=\(Self.timeString(current)) rate=\(String(format: "%.2f", rate)) item=\(itemStatus) route=\(Self.routeDescription())"
            )
        }
    }

    private func configureEngineLoopIfPossible(url: URL, assetProfile: AudioAssetProfile) -> Bool {
        guard
            let engineBundle = try? Self.makeLoopEngineBundle(for: url, loopRange: loopRange)
        else {
            diagnostics.record("loop strategy: engine loop unavailable, falling back to AVPlayerLooper")
            return false
        }

        engine = engineBundle.engine
        enginePlayerNode = engineBundle.playerNode
        environmentNode = engineBundle.environmentNode
        enginePlayerNode?.volume = volume
        engineDuration = engineBundle.duration
        duration = engineBundle.duration
        usesEngineLoop = true
        player = nil
        looper = nil
        refreshSpatialPlacement()

        diagnostics.record(
            "loop strategy: AVAudioEngine seamless loop enabled range=\(Self.timeString(engineBundle.range.lowerBound))-\(Self.timeString(engineBundle.range.upperBound))"
        )
        diagnostics.record(
            assetProfile.isTrueSpatialAudio
                ? "spatial audio playback check: true (\(assetProfile.diagnosticSummary))"
                : "spatial audio playback check: false (\(assetProfile.diagnosticSummary))"
        )
        return true
    }

    private func playEngineLoop() {
        guard let engine, let enginePlayerNode else {
            diagnostics.record("play ignored: engine missing")
            return
        }

        do {
            try preparePlaybackSession()
            if !engine.isRunning {
                try engine.start()
            }
            diagnostics.record("play start: route=\(Self.routeDescription())")
            if !enginePlayerNode.isPlaying {
                enginePlayerNode.play()
            }
            isPlaying = true
            startEngineProgressTimer()
            schedulePlaybackProbe()
        } catch {
            diagnostics.record("play failed: session error=\(error.localizedDescription)")
            tearDownPlayer(deactivateSession: true)
        }
    }

    private func startEngineProgressTimer() {
        engineProgressTimer?.invalidate()
        guard engineDuration > 0 else { return }
        engineProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let seconds = self.currentEnginePlaybackTime()
            self.currentTime = seconds
            if !self.playbackEnvelope.isEmpty, self.engineDuration > 0 {
                let progress = max(0, min(seconds / max(self.engineDuration, 0.1), 0.999))
                let index = min(Int(progress * Double(self.playbackEnvelope.count)), self.playbackEnvelope.count - 1)
                self.reactiveLevel = Double(self.playbackEnvelope[index])
            }
        }
    }

    private func currentEnginePlaybackTime() -> TimeInterval {
        guard
            let enginePlayerNode,
            let lastRenderTime = enginePlayerNode.lastRenderTime,
            let playerTime = enginePlayerNode.playerTime(forNodeTime: lastRenderTime),
            playerTime.sampleRate > 0,
            engineDuration > 0
        else {
            return currentTime
        }

        let elapsed = Double(playerTime.sampleTime) / playerTime.sampleRate
        let loopDuration = max(engineDuration, 0.001)
        let wrapped = elapsed.truncatingRemainder(dividingBy: loopDuration)
        guard wrapped.isFinite else { return 0 }

        let clamped = min(max(wrapped, 0), max(loopDuration - 0.001, 0))
        if loopDuration - clamped < 0.005 {
            return 0
        }
        return clamped
    }

    private func refreshSpatialPlacement() {
        guard let enginePlayerNode else { return }

        let yawRadians = listenerYawDegrees * .pi / 180.0
        let lateralBase = Double(spatialPan) * 1.35 + Double(spatialOffset.width / 34.0)
        let verticalBase = max(-0.45, min(0.45, Double(-spatialOffset.height / 82.0)))
        let rotatedLateral = max(-1.8, min(1.8, lateralBase + (sin(yawRadians) * 0.95)))
        let depth = max(-2.3, min(-0.75, -1.45 - (cos(yawRadians) * 0.24)))
        enginePlayerNode.position = AVAudio3DPoint(
            x: Float(rotatedLateral),
            y: Float(verticalBase),
            z: Float(depth)
        )
    }

    private func tearDownPlayer(deactivateSession: Bool) {
        engineProgressTimer?.invalidate()
        engineProgressTimer = nil
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        itemStatusObservation = nil
        timeControlObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil

        player?.pause()
        player = nil
        looper = nil
        enginePlayerNode?.stop()
        engine?.stop()
        enginePlayerNode = nil
        environmentNode = nil
        engine = nil
        engineDuration = 0
        loopRange = nil
        usesEngineLoop = false
        loadedURL = nil
        shouldLoop = false
        isPlaying = false
        isSpatialPlaybackActive = false
        playbackEnvelope = []
        duration = 0
        currentTime = 0
        reactiveLevel = 0.18

        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

private extension AudioPlayerController {
    static func assetDuration(for url: URL) -> TimeInterval {
        let duration = AVURLAsset(url: url).duration.seconds
        return duration.isFinite ? duration : 0
    }

    struct LoopEngineBundle {
        let engine: AVAudioEngine
        let playerNode: AVAudioPlayerNode
        let environmentNode: AVAudioEnvironmentNode
        let duration: TimeInterval
        let range: ClosedRange<Double>
    }

    static func makeLoopEngineBundle(for url: URL, loopRange: ClosedRange<Double>?) throws -> LoopEngineBundle {
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.processingFormat.sampleRate
        let totalFrameCount = AVAudioFramePosition(file.length)
        guard totalFrameCount > 0, sampleRate > 0 else {
            throw NSError(domain: "ResonanceLoopEngine", code: -1, userInfo: nil)
        }

        let startFrame = max(0, min(totalFrameCount - 1, AVAudioFramePosition((loopRange?.lowerBound ?? 0) * sampleRate)))
        let endFrame = max(
            startFrame + 1,
            min(totalFrameCount, AVAudioFramePosition((loopRange?.upperBound ?? (Double(totalFrameCount) / sampleRate)) * sampleRate))
        )
        let frameCount = AVAudioFrameCount(endFrame - startFrame)
        guard
            frameCount > 1,
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)
        else {
            throw NSError(domain: "ResonanceLoopEngine", code: -2, userInfo: nil)
        }

        file.framePosition = startFrame
        try file.read(into: buffer, frameCount: frameCount)

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        let environmentNode = AVAudioEnvironmentNode()
        engine.attach(playerNode)
        engine.attach(environmentNode)
        engine.connect(playerNode, to: environmentNode, format: buffer.format)
        engine.connect(environmentNode, to: engine.mainMixerNode, format: buffer.format)
        playerNode.renderingAlgorithm = .HRTFHQ
        playerNode.volume = 1.0
        playerNode.scheduleBuffer(buffer, at: nil, options: [.loops])

        let resolvedRange = (Double(startFrame) / sampleRate)...(Double(endFrame) / sampleRate)
        return LoopEngineBundle(
            engine: engine,
            playerNode: playerNode,
            environmentNode: environmentNode,
            duration: Double(frameCount) / sampleRate,
            range: resolvedRange
        )
    }

    static func fileSummary(for url: URL) -> String {
        let fileExists = FileManager.default.fileExists(atPath: url.path)
        let fileSize: String
        if
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let bytes = attributes[.size] as? NSNumber
        {
            fileSize = ByteCountFormatter.string(fromByteCount: bytes.int64Value, countStyle: .file)
        } else {
            fileSize = "unknown"
        }

        let formatDescription: String
        if let audioFile = try? AVAudioFile(forReading: url) {
            formatDescription = "sr=\(Int(audioFile.processingFormat.sampleRate))Hz ch=\(audioFile.processingFormat.channelCount) fmt=\(audioFile.processingFormat.commonFormat.rawValue)"
        } else {
            formatDescription = "format unreadable"
        }

        let assetProfile = AudioAssetProfile.inspect(url: url)
        return "file=\(url.lastPathComponent) exists=\(fileExists) size=\(fileSize) \(formatDescription) \(assetProfile.diagnosticSummary)"
    }

    static func routeDescription() -> String {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }
        return outputs.isEmpty ? "none" : outputs.joined(separator: ", ")
    }

    static func timeString(_ time: TimeInterval) -> String {
        guard time.isFinite else { return "nan" }
        return String(format: "%.2fs", time)
    }
}

private extension AVPlayer.TimeControlStatus {
    var diagnosticLabel: String {
        switch self {
        case .paused:
            return "paused"
        case .waitingToPlayAtSpecifiedRate:
            return "waiting"
        case .playing:
            return "playing"
        @unknown default:
            return "unknown"
        }
    }
}

private extension AVPlayerItem.Status {
    var diagnosticLabel: String {
        switch self {
        case .unknown:
            return "unknown"
        case .readyToPlay:
            return "ready"
        case .failed:
            return "failed"
        @unknown default:
            return "unknown-default"
        }
    }
}

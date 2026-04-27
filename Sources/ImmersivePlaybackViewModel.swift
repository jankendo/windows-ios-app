import Combine
import CoreMotion
import Foundation

@MainActor
final class ImmersivePlaybackViewModel: ObservableObject {
    let player = AudioPlayerController()

    @Published private(set) var hotspotHeadingDegrees = 0.0

    private let motionManager = CMMotionManager()
    private var playerChangeCancellable: AnyCancellable?
    private var preferredPlaybackURL: URL?
    private var baseSpatialOffset: CGSize = .zero
    private var dragTranslation: CGSize = .zero
    private var smoothedYawDegrees = 0.0

    init() {
        playerChangeCancellable = player.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func loadAmbientLoop(
        playbackURL: URL?,
        analysisURL: URL?,
        waveform: [CGFloat],
        loopRange: ClosedRange<Double>?,
        volume: Float
    ) {
        preferredPlaybackURL = analysisURL ?? playbackURL
        player.setPlaybackEnvelope(waveform)
        player.setVolume(volume)
        guard let preferredPlaybackURL else {
            player.stop()
            return
        }
        player.load(
            url: preferredPlaybackURL,
            autoPlay: true,
            loop: true,
            volume: volume,
            loopRange: loopRange
        )
    }

    func togglePlayback() {
        player.togglePlayback(for: preferredPlaybackURL)
    }

    func updateBaseSpatialOffset(_ offset: CGSize) {
        baseSpatialOffset = offset
        applySpatialState()
    }

    func updateDrag(_ translation: CGSize) {
        dragTranslation = translation
        applySpatialState()
    }

    func resetDrag() {
        dragTranslation = .zero
        applySpatialState()
    }

    func startMotionTracking() {
        guard UserDefaults.standard.object(forKey: ResonancePreferenceKey.immersiveGazeLinkedAudioEnabled) == nil
                ? true
                : UserDefaults.standard.bool(forKey: ResonancePreferenceKey.immersiveGazeLinkedAudioEnabled) else {
            player.setListenerYaw(0)
            hotspotHeadingDegrees = 0
            return
        }
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let yawDegrees = motion.attitude.yaw * 180.0 / .pi
            self.smoothedYawDegrees = (self.smoothedYawDegrees * 0.82) + (yawDegrees * 0.18)
            self.hotspotHeadingDegrees = -self.smoothedYawDegrees
            self.player.setListenerYaw(-self.smoothedYawDegrees)
        }
    }

    func stop() {
        if motionManager.isDeviceMotionActive {
            motionManager.stopDeviceMotionUpdates()
        }
        hotspotHeadingDegrees = 0
        smoothedYawDegrees = 0
        player.stop()
    }

    private func applySpatialState() {
        let combinedOffset = CGSize(
            width: baseSpatialOffset.width + (dragTranslation.width * 0.22),
            height: baseSpatialOffset.height + (dragTranslation.height * 0.16)
        )
        player.setPan(Float(dragTranslation.width / 180.0))
        player.setSpatialOffset(combinedOffset)
    }
}

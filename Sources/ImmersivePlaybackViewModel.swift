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
    private var smoothedHeadingVector: (x: Double, y: Double)?

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
        preferredPlaybackURL = playbackURL ?? analysisURL
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
            smoothedHeadingVector = nil
            return
        }
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }
        guard
            let referenceFrame = ImmersiveDirectionSpace.preferredMotionReferenceFrame(),
            ImmersiveDirectionSpace.isCompassReferenced(referenceFrame)
        else {
            player.setListenerYaw(0)
            hotspotHeadingDegrees = 0
            smoothedHeadingVector = nil
            return
        }
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(using: referenceFrame, to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let headingDegrees = ImmersiveDirectionSpace.headingDegrees(fromYawRadians: motion.attitude.yaw)
            let smoothedHeadingDegrees = self.smoothedHeading(from: headingDegrees)
            self.hotspotHeadingDegrees = smoothedHeadingDegrees
            self.player.setListenerYaw(smoothedHeadingDegrees)
        }
    }

    func stop() {
        if motionManager.isDeviceMotionActive {
            motionManager.stopDeviceMotionUpdates()
        }
        hotspotHeadingDegrees = 0
        smoothedHeadingVector = nil
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

    private func smoothedHeading(from headingDegrees: Double) -> Double {
        let headingRadians = headingDegrees * .pi / 180.0
        let targetVector = (x: sin(headingRadians), y: cos(headingRadians))
        let blendedVector: (x: Double, y: Double)

        if let smoothedHeadingVector {
            blendedVector = (
                x: (smoothedHeadingVector.x * 0.88) + (targetVector.x * 0.12),
                y: (smoothedHeadingVector.y * 0.88) + (targetVector.y * 0.12)
            )
        } else {
            blendedVector = targetVector
        }

        let magnitude = max(hypot(blendedVector.x, blendedVector.y), 0.0001)
        let normalizedVector = (
            x: blendedVector.x / magnitude,
            y: blendedVector.y / magnitude
        )
        smoothedHeadingVector = normalizedVector
        return ImmersiveDirectionSpace.normalizedDegrees(atan2(normalizedVector.x, normalizedVector.y) * 180.0 / .pi)
    }
}

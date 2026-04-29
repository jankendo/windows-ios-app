import ARKit
import AVFoundation
import CoreImage
import SceneKit
import SwiftUI
import UIKit

private enum SpatialScanCaptureFinalizationError: LocalizedError {
    case optimizedAssetUnavailable

    var errorDescription: String? {
        switch self {
        case .optimizedAssetUnavailable:
            return "3Dスキャンを最適化できませんでした。もう一度、同じ地点から360度をゆっくりスキャンしてください。"
        }
    }
}

struct SpatialScanLivePreviewPoint: Identifiable, Hashable {
    let id: Int
    let x: Float
    let y: Float
    let z: Float
}

@MainActor
final class SpatialScanCaptureModel: NSObject, ObservableObject, @preconcurrency ARSessionDelegate {
    private enum CaptureConstants {
        static let frameSamplingInterval: TimeInterval = 0.045
        static let frameImageSamplingInterval: TimeInterval = 0.11
        static let coverageFrameImageSamplingInterval: TimeInterval = 0.055
        static let minimumTranslationMeters: Float = 0.0025
        static let minimumRotationRadians: Float = 0.007
        static let minimumQualityEvaluationDuration: TimeInterval = 24
        static let preferredFrameCount = 280
        static let headingCoverageBucketCount = 12
        static let verticalCoverageBandCount = 3
        static let preferredHeadingSpanDegrees = 356.0
        static let preferredVerticalSpanDegrees = 96.0
        static let highQualityScore = 0.985
        static let minimumHighQualityFrameCount = 144
        static let minimumHighQualityHeadingSpanDegrees = 340.0
        static let minimumHighQualityVerticalSpanDegrees = 72.0
        static let idealStationaryDriftMeters = 0.85
        static let maximumStationaryDriftMeters = 1.6
        static let maximumPointSamplesPerFrame = 16_000
        static let pointIdentifierResampleInterval = 1
        static let preferredPointSampleCount = 320_000
        static let minimumHighQualityPointSampleCount = 80_000
        static let minimumFeaturePointDistanceMeters: Float = 0.025
        static let maximumFeaturePointDistanceMeters: Float = 18.0
        static let maximumLivePreviewPointCount = 36_000
        static let livePreviewPointStride = 3
        static let sessionBindingPollCount = 20
        static let sessionBindingPollNanoseconds: UInt64 = 50_000_000
        static let sessionReadyTimeout: TimeInterval = 2.5
    }

    @Published private(set) var isScanning = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var sampledFrameCount = 0
    @Published private(set) var guidanceText = "足を止めたまま、その場で360度の輪郭を集めます。"
    @Published private(set) var qualityPercent = 0
    @Published private(set) var headingCoverage = 0.0
    @Published private(set) var verticalCoverage = 0.0
    @Published private(set) var stationaryCoverage = 0.0
    @Published private(set) var pointCloudCoverage = 0.0
    @Published private(set) var trackingStability = 0.0
    @Published private(set) var captureCoverageCells = Array(
        repeating: false,
        count: CaptureConstants.headingCoverageBucketCount * CaptureConstants.verticalCoverageBandCount
    )
    @Published private(set) var coverageFocusText = "取得範囲を解析中"
    @Published private(set) var collectedPointCount = 0
    @Published private(set) var qualityStatusText = "精度を測定しています"
    @Published private(set) var motionHintText = "端末を胸の前で構え、足を止めてください。"
    @Published private(set) var isHighQualityReady = false
    @Published private(set) var isImprovingAfterReady = false
    @Published private(set) var isOptimizingScan = false
    @Published private(set) var optimizationProgress = 0.0
    @Published private(set) var optimizationStatusText = "3Dデータを最適化しています"
    @Published private(set) var livePreviewPoints: [SpatialScanLivePreviewPoint] = []

    private weak var arSession: ARSession?
    private let ciContext = CIContext()
    private let audioSession = AVCaptureSession()
    private let ambientAudioCapture = AmbientAudioCaptureCoordinator()

    private var audioInput: AVCaptureDeviceInput?
    private var captureContinuation: CheckedContinuation<CapturedMemoryDraft, Error>?
    private var captureTimerTask: Task<Void, Never>?
    private var startedAt: Date?
    private var bundleURL: URL?
    private var frameSamples: [SpatialScanFrameSample] = []
    private var poseSamples: [CapturePoseSample] = []
    private var pointSamples: [SpatialScanPointSample] = []
    private var seenPointIdentifiers: [UInt64: Int] = [:]
    private var savedFrameCoverageCells = Set<Int>()
    private var firstFrameTimestamp: TimeInterval?
    private var lastFrameTimestamp: TimeInterval = 0
    private var lastCameraTransform: simd_float4x4?
    private var lastSavedFrameTimestamp: TimeInterval?
    private var lastSavedCameraTransform: simd_float4x4?
    private var previewImageData: Data?
    private var previewImageFileName = "preview.jpg"
    private var worldMapFileName: String?
    private var captureResolved = false
    private var isFinishingCapture = false
    private var hasSentHighQualityFeedback = false
    private var livePreviewPointID = 0

    private struct CaptureQualityState {
        let score: Double
        let headingCoverage: Double
        let verticalCoverage: Double
        let stationaryCoverage: Double
        let pointCloudCoverage: Double
        let surfaceCoverage: Double
        let trackingStability: Double
        let coverageCells: [Bool]
        let coverageFocusText: String
        let isTrackingStable: Bool
        let isHighQuality: Bool
    }

    private struct CaptureCoverageMap {
        let cells: [Bool]
        let coverageScore: Double
        let focusText: String
    }

    private struct CapturePoseSample {
        let timeOffset: TimeInterval
        let cameraTransform: simd_float4x4

        var translationVector: (x: Double, y: Double, z: Double) {
            (
                x: Double(cameraTransform.columns.3.x),
                y: Double(cameraTransform.columns.3.y),
                z: Double(cameraTransform.columns.3.z)
            )
        }

        var headingDegrees: Double? {
            let forwardX = -Double(cameraTransform.columns.2.x)
            let forwardZ = -Double(cameraTransform.columns.2.z)
            let magnitude = sqrt((forwardX * forwardX) + (forwardZ * forwardZ))
            guard magnitude > 0 else { return nil }
            let degrees = atan2(forwardX / magnitude, -(forwardZ / magnitude)) * 180 / .pi
            return ImmersiveDirectionSpace.normalizedDegrees(degrees)
        }

        var pitchDegrees: Double {
            let forwardY = -Double(cameraTransform.columns.2.y)
            let clampedForwardY = min(max(forwardY, -1), 1)
            return asin(clampedForwardY) * 180 / .pi
        }
    }

    deinit {
        if arSession?.delegate === self {
            arSession?.delegate = nil
        }
    }

    func bind(session: ARSession) {
        if let currentSession = arSession,
           currentSession !== session,
           currentSession.delegate === self {
            currentSession.delegate = nil
        }
        guard arSession !== session else { return }
        arSession = session
        session.delegate = self
    }

    func unbind() {
        if arSession?.delegate === self {
            arSession?.delegate = nil
        }
        arSession = nil
    }

    func captureScan() async throws -> CapturedMemoryDraft {
        guard ARWorldTrackingConfiguration.isSupported else {
            throw CaptureError.spatialScanUnavailable
        }
        if arSession == nil {
            for _ in 0..<CaptureConstants.sessionBindingPollCount {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: CaptureConstants.sessionBindingPollNanoseconds)
                if arSession != nil {
                    break
                }
            }
        }
        guard let arSession else {
            throw CaptureError.sessionNotReady
        }
        guard !isScanning, captureContinuation == nil else {
            throw CaptureError.busy
        }

        prepareForNewCapture()
        bundleURL = try createBundleFolder()

        do {
            try configureAudioCapture()
            let configuration = ARWorldTrackingConfiguration()
            configuration.worldAlignment = .gravityAndHeading
            configuration.environmentTexturing = .automatic
            configuration.planeDetection = [.horizontal, .vertical]
            if let videoFormat = preferredVideoFormat() {
                configuration.videoFormat = videoFormat
            }
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                configuration.frameSemantics.insert(.sceneDepth)
            }
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
                configuration.frameSemantics.insert(.smoothedSceneDepth)
            }
            arSession.run(configuration, options: [.resetTracking, .removeExistingAnchors])
            try await waitForSessionReadiness()
            _ = try ambientAudioCapture.startRecording()
        } catch {
            ambientAudioCapture.cancelRecording()
            if let bundleURL {
                try? FileManager.default.removeItem(at: bundleURL)
            }
            resetCaptureState()
            throw error
        }

        startedAt = .now
        isScanning = true
        updateCaptureQuality(trackingState: arSession.currentFrame?.camera.trackingState, elapsed: 0)

        return try await withCheckedThrowingContinuation { continuation in
            self.captureResolved = false
            captureContinuation = continuation

            captureTimerTask = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard let startedAt = self.startedAt else { continue }
                    let elapsed = Date().timeIntervalSince(startedAt)
                    await MainActor.run {
                        self.updateCaptureQuality(
                            trackingState: self.arSession?.currentFrame?.camera.trackingState,
                            elapsed: elapsed
                        )
                    }
                }
            }
        }
    }

    func cancelCapture() {
        guard !isOptimizingScan else { return }
        ambientAudioCapture.cancelRecording()
        let discardedBundleURL = bundleURL
        resolveCapture(.failure(CancellationError()))
        if let discardedBundleURL {
            try? FileManager.default.removeItem(at: discardedBundleURL)
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        Task { @MainActor [weak self] in
            self?.handle(frame: frame)
        }
    }

    private func handle(frame: ARFrame) {
        guard isScanning, let bundleURL else { return }

        let elapsed = resolvedElapsed(for: frame)
        let shouldSampleFrame = shouldSample(frame: frame, elapsed: elapsed)
        if shouldSampleFrame {
            appendPoseSample(from: frame, elapsed: elapsed)
            let savedFrameIndex = appendFrameSampleIfNeeded(from: frame, elapsed: elapsed, bundleURL: bundleURL)
            appendPointSamples(
                from: frame,
                sourceFrameIndex: savedFrameIndex ?? nearestSavedFrameIndex,
                observationIndex: max(poseSamples.count - 1, 0)
            )
            sampledFrameCount = poseSamples.count
            lastCameraTransform = frame.camera.transform
            lastFrameTimestamp = max(elapsed, lastFrameTimestamp)
        }

        updateCaptureQuality(trackingState: frame.camera.trackingState, elapsed: elapsed)
    }

    private func shouldSample(frame: ARFrame, elapsed: TimeInterval) -> Bool {
        guard elapsed >= 0 else { return false }
        guard elapsed - lastFrameTimestamp >= CaptureConstants.frameSamplingInterval else { return false }

        guard let lastCameraTransform else {
            return true
        }

        let translation = simd_length(frame.camera.transform.columns.3.xyz - lastCameraTransform.columns.3.xyz)
        let forward = simd_normalize(frame.camera.transform.columns.2.xyz)
        let previousForward = simd_normalize(lastCameraTransform.columns.2.xyz)
        let rotationDelta = acos(max(-1, min(1, simd_dot(forward, previousForward))))
        return translation >= CaptureConstants.minimumTranslationMeters
            || rotationDelta >= CaptureConstants.minimumRotationRadians
    }

    func finishHighQualityCapture() {
        guard isHighQualityReady else {
            qualityStatusText = "まだ高精度化中です"
            guidanceText = "360度の方位と上下の角度が十分に揃うまで、保存はできません。足を止めたまま続けてください。"
            motionHintText = "もう少し続ける"
            return
        }

        Task { @MainActor [weak self] in
            await self?.finishCapture()
        }
    }

    private func finishCapture() async {
        guard isScanning, !isFinishingCapture, let bundleURL else { return }
        isFinishingCapture = true
        qualityStatusText = "空間を仕上げています"
        guidanceText = "高精度の360度スキャンを保存用の空間データへまとめています。"
        motionHintText = "端末をそのまま安定させてください。"
        isOptimizingScan = true
        optimizationProgress = 0.05
        optimizationStatusText = "スキャンデータを固定しています"

        captureTimerTask?.cancel()
        captureTimerTask = nil

        if previewImageData == nil || frameSamples.isEmpty,
           let currentFrame = arSession?.currentFrame {
            let elapsed = resolvedElapsed(for: currentFrame)
            _ = appendFrameSample(from: currentFrame, elapsed: elapsed, bundleURL: bundleURL)
        }

        arSession?.pause()
        isScanning = false

        let worldMap = await currentWorldMap()
        if let worldMap,
           let archivedData = try? NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true) {
            let fileName = "worldMap.arexperience"
            try? archivedData.write(to: bundleURL.appendingPathComponent(fileName), options: .atomic)
            worldMapFileName = fileName
        }

        ambientAudioCapture.stopRecording { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                self.completeCapture(with: result)
            }
        }
    }

    private func completeCapture(with result: Result<AmbientAudioCaptureResult, Error>) {
        guard !captureResolved else { return }
        guard let bundleURL, let previewImageData else {
            resolveCapture(.failure(CaptureError.photoCaptureFailed))
            return
        }

        switch result {
        case .success(let audioResult):
            Task { @MainActor [weak self] in
                await self?.finalizeOptimizedCapture(
                    audioResult: audioResult,
                    bundleURL: bundleURL,
                    previewImageData: previewImageData
                )
            }
        case .failure(let error):
            try? FileManager.default.removeItem(at: bundleURL)
            resolveCapture(.failure(error))
        }
    }

    private func finalizeOptimizedCapture(
        audioResult: AmbientAudioCaptureResult,
        bundleURL: URL,
        previewImageData: Data
    ) async {
        guard !captureResolved else { return }

        isOptimizingScan = true
        optimizationProgress = 0.12
        optimizationStatusText = "写真色付きの3D空間を解析しています"
        qualityStatusText = "3D最適化中"
        guidanceText = "最適化済みの3Dデータを生成しています。完了するまでそのままお待ちください。"
        motionHintText = "処理中"

        let capturedPointSamples = pointSamples
        let capturedFrameSamples = frameSamples
        let capturedAt = startedAt ?? .now
        let capturedDuration = max(audioResult.duration, lastFrameTimestamp)
        let capturedHeading = captureHeadingDegrees(from: lastCameraTransform)
        let capturedWorldMapFileName = worldMapFileName
        let capturedPreviewFileName = previewImageFileName

        do {
            let optimizationResult = try await Task.detached(priority: .userInitiated) {
                try SpatialScanPointCloudOptimizer.optimize(
                    pointSamples: capturedPointSamples,
                    frameSamples: capturedFrameSamples,
                    bundleURL: bundleURL
                )
            }.value

            optimizationProgress = 0.68
            optimizationStatusText = "画像を3Dスプラットへ焼き付けています"

            let manifest = SpatialScanManifest(
                capturedAt: capturedAt,
                captureDuration: capturedDuration,
                frameCount: capturedFrameSamples.count,
                fieldOfViewLimited: true,
                anchorHeadingDegrees: capturedHeading,
                previewImageFileName: capturedPreviewFileName,
                worldMapFileName: capturedWorldMapFileName,
                reconstructionState: .captured,
                optimizedPointCloudFileName: optimizationResult.relativePath,
                optimizedPointCloudPointCount: optimizationResult.pointCount,
                pointSamples: [],
                frameSamples: capturedFrameSamples
            )
            let preparedManifest = try SpatialScanReconstructionPipeline.prepare(manifest: manifest, in: bundleURL)
            guard preparedManifest.reconstructionState == .ready else {
                throw SpatialScanCaptureFinalizationError.optimizedAssetUnavailable
            }

            optimizationProgress = 0.9
            optimizationStatusText = "最適化済みデータを保存しています"

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(preparedManifest)
            try data.write(to: bundleURL.appendingPathComponent("manifest.json"), options: .atomic)

            optimizationProgress = 1
            optimizationStatusText = "3Dスキャンの最適化が完了しました"

            let draft = CapturedMemoryDraft(
                photoData: previewImageData,
                audioTempURL: audioResult.primaryURL,
                analysisAudioTempURL: audioResult.analysisURL ?? audioResult.primaryURL,
                spatialScanPayload: SpatialScanCapturePayload(bundleURL: bundleURL, manifest: preparedManifest),
                capturedAt: preparedManifest.capturedAt,
                audioDuration: audioResult.duration,
                isSpatialAudio: audioResult.isSpatialAudio,
                recoveryState: .none,
                placeLabel: nil,
                photoCaption: nil,
                photoCaptionSource: nil,
                photoCaptionStyle: nil,
                sensorSnapshot: nil,
                minimumDecibels: nil,
                maximumDecibels: nil
            )
            resolveCapture(.success(draft))
        } catch {
            try? FileManager.default.removeItem(at: bundleURL)
            resolveCapture(.failure(error))
        }
    }

    private func currentWorldMap() async -> ARWorldMap? {
        guard let arSession else { return nil }
        return await withCheckedContinuation { continuation in
            arSession.getCurrentWorldMap { worldMap, _ in
                continuation.resume(returning: worldMap)
            }
        }
    }

    private func configureAudioCapture() throws {
        if let audioInput {
            audioSession.beginConfiguration()
            if !audioSession.inputs.contains(where: { $0 === audioInput }) {
                guard audioSession.canAddInput(audioInput) else {
                    audioSession.commitConfiguration()
                    throw CaptureError.audioRecordingFailed
                }
                audioSession.addInput(audioInput)
            }
            _ = try ambientAudioCapture.configure(session: audioSession, audioInput: audioInput)
            audioSession.commitConfiguration()
            if !audioSession.isRunning {
                audioSession.startRunning()
            }
            return
        }

        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw CaptureError.audioRecordingFailed
        }

        let input = try AVCaptureDeviceInput(device: device)
        audioSession.beginConfiguration()
        guard audioSession.canAddInput(input) else {
            audioSession.commitConfiguration()
            throw CaptureError.audioRecordingFailed
        }
        audioSession.addInput(input)
        _ = try ambientAudioCapture.configure(session: audioSession, audioInput: input)
        audioSession.commitConfiguration()
        audioSession.startRunning()
        audioInput = input
    }

    private func createBundleFolder() throws -> URL {
        let draftsFolderURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ResonanceCaptureDrafts", isDirectory: true)
            .appendingPathComponent("SpatialScans", isDirectory: true)
        try FileManager.default.createDirectory(at: draftsFolderURL, withIntermediateDirectories: true)
        let url = draftsFolderURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func prepareForNewCapture() {
        if let bundleURL {
            try? FileManager.default.removeItem(at: bundleURL)
        }
        captureTimerTask?.cancel()
        captureTimerTask = nil
        captureContinuation = nil
        startedAt = nil
        progress = 0
        guidanceText = "足を止めたまま、その場で360度の輪郭を集めます。"
        qualityPercent = 0
        headingCoverage = 0
        verticalCoverage = 0
        stationaryCoverage = 0
        pointCloudCoverage = 0
        trackingStability = 0
        captureCoverageCells = Self.emptyCoverageCells
        coverageFocusText = "取得範囲を解析中"
        collectedPointCount = 0
        qualityStatusText = "精度を測定しています"
        motionHintText = "端末を胸の前で構え、足を止めてください。"
        isHighQualityReady = false
        isImprovingAfterReady = false
        isOptimizingScan = false
        optimizationProgress = 0
        optimizationStatusText = "3Dデータを最適化しています"
        sampledFrameCount = 0
        frameSamples = []
        poseSamples = []
        pointSamples = []
        livePreviewPoints = []
        livePreviewPointID = 0
        seenPointIdentifiers = [:]
        savedFrameCoverageCells = []
        firstFrameTimestamp = nil
        lastFrameTimestamp = 0
        lastCameraTransform = nil
        lastSavedFrameTimestamp = nil
        lastSavedCameraTransform = nil
        previewImageData = nil
        previewImageFileName = "preview.jpg"
        worldMapFileName = nil
        isFinishingCapture = false
        hasSentHighQualityFeedback = false
        captureResolved = false
        isScanning = false
    }

    private func preferredVideoFormat() -> ARConfiguration.VideoFormat? {
        ARWorldTrackingConfiguration.supportedVideoFormats
            .filter { $0.framesPerSecond >= 30 }
            .max { lhs, rhs in
                let lhsArea = lhs.imageResolution.width * lhs.imageResolution.height
                let rhsArea = rhs.imageResolution.width * rhs.imageResolution.height
                if lhsArea == rhsArea {
                    return lhs.framesPerSecond < rhs.framesPerSecond
                }
                return lhsArea < rhsArea
            }
    }

    private func resetCaptureState() {
        captureTimerTask?.cancel()
        captureTimerTask = nil
        captureContinuation = nil
        startedAt = nil
        isScanning = false
        progress = 0
        sampledFrameCount = 0
        qualityPercent = 0
        headingCoverage = 0
        verticalCoverage = 0
        stationaryCoverage = 0
        pointCloudCoverage = 0
        trackingStability = 0
        captureCoverageCells = Self.emptyCoverageCells
        coverageFocusText = "取得範囲を解析中"
        collectedPointCount = 0
        qualityStatusText = "精度を測定しています"
        motionHintText = "端末を胸の前で構え、足を止めてください。"
        guidanceText = "足を止めたまま、その場で360度の輪郭を集めます。"
        isHighQualityReady = false
        isImprovingAfterReady = false
        isOptimizingScan = false
        optimizationProgress = 0
        optimizationStatusText = "3Dデータを最適化しています"
        if audioSession.isRunning {
            audioSession.stopRunning()
        }
        arSession?.pause()
        bundleURL = nil
        firstFrameTimestamp = nil
        lastFrameTimestamp = 0
        lastCameraTransform = nil
        lastSavedFrameTimestamp = nil
        lastSavedCameraTransform = nil
        previewImageData = nil
        previewImageFileName = "preview.jpg"
        worldMapFileName = nil
        frameSamples = []
        poseSamples = []
        pointSamples = []
        livePreviewPoints = []
        livePreviewPointID = 0
        seenPointIdentifiers = [:]
        savedFrameCoverageCells = []
        isFinishingCapture = false
        hasSentHighQualityFeedback = false
        captureResolved = true
    }

    private func resolveCapture(_ result: Result<CapturedMemoryDraft, Error>) {
        guard !captureResolved else { return }
        let continuation = captureContinuation
        resetCaptureState()
        continuation?.resume(with: result)
    }

    private func waitForSessionReadiness() async throws {
        guard let arSession else {
            throw CaptureError.sessionNotReady
        }

        let deadline = Date().addingTimeInterval(CaptureConstants.sessionReadyTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let currentFrame = arSession.currentFrame {
                switch currentFrame.camera.trackingState {
                case .notAvailable:
                    break
                default:
                    guidanceText = guidanceText(for: currentFrame.camera.trackingState)
                    return
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        throw CaptureError.sessionNotReady
    }

    private func resolvedElapsed(for frame: ARFrame) -> TimeInterval {
        if firstFrameTimestamp == nil {
            firstFrameTimestamp = frame.timestamp
        }
        return max(frame.timestamp - (firstFrameTimestamp ?? frame.timestamp), 0)
    }

    @discardableResult
    private func appendFrameSampleIfNeeded(from frame: ARFrame, elapsed: TimeInterval, bundleURL: URL) -> Int? {
        guard shouldPersistFrameSample(from: frame, elapsed: elapsed) else { return nil }
        return appendFrameSample(from: frame, elapsed: elapsed, bundleURL: bundleURL)
    }

    private func appendPoseSample(from frame: ARFrame, elapsed: TimeInterval) {
        poseSamples.append(
            CapturePoseSample(
                timeOffset: max(elapsed, 0),
                cameraTransform: frame.camera.transform
            )
        )
    }

    private func shouldPersistFrameSample(from frame: ARFrame, elapsed: TimeInterval) -> Bool {
        if previewImageData == nil || frameSamples.isEmpty {
            return true
        }

        let poseSample = CapturePoseSample(timeOffset: max(elapsed, 0), cameraTransform: frame.camera.transform)
        let coverageCell = coverageCellIndex(heading: poseSample.headingDegrees, pitch: poseSample.pitchDegrees)
        let fillsNewCoverageCell = coverageCell.map { !savedFrameCoverageCells.contains($0) } ?? false
        let requiredInterval = fillsNewCoverageCell
            ? CaptureConstants.coverageFrameImageSamplingInterval
            : CaptureConstants.frameImageSamplingInterval

        if let lastSavedFrameTimestamp,
           elapsed - lastSavedFrameTimestamp < requiredInterval {
            return false
        }
        guard let lastSavedCameraTransform else { return true }
        if fillsNewCoverageCell {
            return true
        }

        let translation = simd_length(frame.camera.transform.columns.3.xyz - lastSavedCameraTransform.columns.3.xyz)
        let forward = simd_normalize(frame.camera.transform.columns.2.xyz)
        let previousForward = simd_normalize(lastSavedCameraTransform.columns.2.xyz)
        let rotationDelta = acos(max(-1, min(1, simd_dot(forward, previousForward))))
        return translation >= CaptureConstants.minimumTranslationMeters * 1.5
            || rotationDelta >= CaptureConstants.minimumRotationRadians * 1.5
    }

    @discardableResult
    private func appendFrameSample(from frame: ARFrame, elapsed: TimeInterval, bundleURL: URL) -> Int? {
        let framesFolderURL = bundleURL.appendingPathComponent("frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: framesFolderURL, withIntermediateDirectories: true)

        let frameIndex = frameSamples.count + 1
        let imageFileName = String(format: "frame-%03d.jpg", frameIndex)
        let imageURL = framesFolderURL.appendingPathComponent(imageFileName)

        guard let frameJPEGData = jpegData(from: frame.capturedImage) else { return nil }
        do {
            try frameJPEGData.write(to: imageURL, options: .atomic)
        } catch {
            return nil
        }

        if previewImageData == nil {
            let previewData = previewJPEGData(from: frame.capturedImage) ?? frameJPEGData
            previewImageData = previewData
            let previewURL = bundleURL.appendingPathComponent(previewImageFileName)
            try? previewData.write(to: previewURL, options: .atomic)
        }

        let sample = SpatialScanFrameSample(
            imageFileName: "frames/\(imageFileName)",
            timeOffset: max(elapsed, 0),
            cameraTransform: flattenedMatrix(frame.camera.transform),
            cameraIntrinsics: flattenedMatrix(frame.camera.intrinsics),
            imageWidth: CVPixelBufferGetWidth(frame.capturedImage),
            imageHeight: CVPixelBufferGetHeight(frame.capturedImage)
        )
        frameSamples.append(sample)
        if let cell = coverageCellIndex(heading: sample.headingDegrees, pitch: sample.pitchDegrees) {
            savedFrameCoverageCells.insert(cell)
        }
        lastSavedFrameTimestamp = elapsed
        lastSavedCameraTransform = frame.camera.transform
        return frameIndex - 1
    }

    private var nearestSavedFrameIndex: Int? {
        guard !frameSamples.isEmpty else { return nil }
        return frameSamples.count - 1
    }

    private func appendPointSamples(from frame: ARFrame, sourceFrameIndex: Int?, observationIndex: Int) {
        guard let pointCloud = frame.rawFeaturePoints else {
            return
        }

        let points = pointCloud.points
        guard !points.isEmpty else { return }

        let identifiers = pointCloud.identifiers
        let cameraPosition = frame.camera.transform.columns.3.xyz
        let sampleStride = max(points.count / CaptureConstants.maximumPointSamplesPerFrame, 1)
        var addedCount = 0
        var newLivePreviewPoints: [SpatialScanLivePreviewPoint] = []
        newLivePreviewPoints.reserveCapacity(min(points.count / CaptureConstants.livePreviewPointStride, 2_400))

        for index in stride(from: 0, to: points.count, by: sampleStride) {
            guard addedCount < CaptureConstants.maximumPointSamplesPerFrame else {
                break
            }

            let identifier = identifiers.indices.contains(index) ? identifiers[index] : nil
            if let identifier,
               let previousObservationIndex = seenPointIdentifiers[identifier],
               observationIndex - previousObservationIndex < CaptureConstants.pointIdentifierResampleInterval {
                continue
            }

            let point = points[index]
            let distance = simd_length(point - cameraPosition)
            guard distance >= CaptureConstants.minimumFeaturePointDistanceMeters,
                  distance <= CaptureConstants.maximumFeaturePointDistanceMeters else {
                continue
            }
            if let identifier {
                seenPointIdentifiers[identifier] = observationIndex
            }

            pointSamples.append(
                SpatialScanPointSample(
                    identifier: identifier,
                    sourceFrameIndex: sourceFrameIndex,
                    x: point.x,
                    y: point.y,
                    z: point.z
                )
            )
            if addedCount % CaptureConstants.livePreviewPointStride == 0 {
                livePreviewPointID += 1
                newLivePreviewPoints.append(
                    SpatialScanLivePreviewPoint(
                        id: livePreviewPointID,
                        x: point.x,
                        y: point.y,
                        z: point.z
                    )
                )
            }
            addedCount += 1
        }

        appendLivePreviewPoints(newLivePreviewPoints)
    }

    private func appendLivePreviewPoints(_ points: [SpatialScanLivePreviewPoint]) {
        guard !points.isEmpty else { return }
        livePreviewPoints.append(contentsOf: points)
        let overage = livePreviewPoints.count - CaptureConstants.maximumLivePreviewPointCount
        if overage > 0 {
            livePreviewPoints.removeFirst(overage)
        }
    }

    private func updateCaptureQuality(trackingState: ARCamera.TrackingState?, elapsed: TimeInterval) {
        let quality = captureQualityState(trackingState: trackingState, elapsed: elapsed)
        progress = quality.score
        qualityPercent = Int((quality.score * 100).rounded())
        headingCoverage = quality.headingCoverage
        verticalCoverage = quality.verticalCoverage
        stationaryCoverage = quality.stationaryCoverage
        pointCloudCoverage = quality.pointCloudCoverage
        trackingStability = quality.trackingStability
        captureCoverageCells = quality.coverageCells
        coverageFocusText = quality.coverageFocusText
        collectedPointCount = pointSamples.count
        guidanceText = guidanceText(for: trackingState, quality: quality)
        motionHintText = motionHint(for: quality, trackingState: trackingState)

        if quality.isHighQuality {
            if !isHighQualityReady && !hasSentHighQualityFeedback {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                hasSentHighQualityFeedback = true
            }
            isHighQualityReady = true
            isImprovingAfterReady = true
            qualityStatusText = "保存まで自動で高密度化中"
        } else {
            isHighQualityReady = false
            isImprovingAfterReady = false
            qualityStatusText = qualityStatus(for: quality)
        }
    }

    private func captureQualityState(
        trackingState: ARCamera.TrackingState?,
        elapsed: TimeInterval
    ) -> CaptureQualityState {
        let poseFrameScore = min(Double(poseSamples.count) / Double(CaptureConstants.preferredFrameCount), 1)
        let savedFrameScore = min(Double(frameSamples.count) / Double(CaptureConstants.minimumHighQualityFrameCount), 1)
        let frameScore = min((poseFrameScore * 0.68) + (savedFrameScore * 0.32), 1)
        let translationExtent = translationExtentMeters(for: poseSamples)
        let stationaryScore = stationaryScore(forTranslationExtent: translationExtent)
        let headingSpan = headingSpanDegrees(for: poseSamples.compactMap(\.headingDegrees))
        let verticalSpan = linearSpanDegrees(for: poseSamples.map(\.pitchDegrees))
        let coverageMap = captureCoverageMap(for: poseSamples)
        let headingScore = min(headingSpan / CaptureConstants.preferredHeadingSpanDegrees, 1)
        let verticalScore = min(verticalSpan / CaptureConstants.preferredVerticalSpanDegrees, 1)
        let trackingScore = trackingScore(for: trackingState)
        let durationScore = min(elapsed / CaptureConstants.minimumQualityEvaluationDuration, 1)
        let adaptivePointTarget = adaptivePointTarget(
            headingScore: headingScore,
            verticalScore: verticalScore,
            frameScore: frameScore,
            surfaceCoverage: coverageMap.coverageScore
        )
        let pointDensityScore = min(Double(pointSamples.count) / adaptivePointTarget, 1)
        let visualCoverageScore = min(coverageMap.coverageScore / 0.74, 1)
        let pointScore = min((pointDensityScore * 0.78) + (visualCoverageScore * 0.22), 1)
        let score = min(
            (headingScore * 0.26)
                + (verticalScore * 0.18)
                + (pointScore * 0.16)
                + (frameScore * 0.16)
                + (trackingScore * 0.11)
                + (stationaryScore * 0.08)
                + (durationScore * 0.05),
            1
        )
        let isTrackingStable = trackingScore >= 0.9
        let isHighQuality = elapsed >= CaptureConstants.minimumQualityEvaluationDuration
            && poseSamples.count >= CaptureConstants.minimumHighQualityFrameCount
            && frameSamples.count >= CaptureConstants.minimumHighQualityFrameCount
            && headingSpan >= CaptureConstants.minimumHighQualityHeadingSpanDegrees
            && verticalSpan >= CaptureConstants.minimumHighQualityVerticalSpanDegrees
            && pointSamples.count >= CaptureConstants.minimumHighQualityPointSampleCount
            && coverageMap.coverageScore >= 0.64
            && score >= CaptureConstants.highQualityScore
            && stationaryScore >= 0.55
            && isTrackingStable

        return CaptureQualityState(
            score: score,
            headingCoverage: headingScore,
            verticalCoverage: verticalScore,
            stationaryCoverage: stationaryScore,
            pointCloudCoverage: pointScore,
            surfaceCoverage: coverageMap.coverageScore,
            trackingStability: trackingScore,
            coverageCells: coverageMap.cells,
            coverageFocusText: coverageMap.focusText,
            isTrackingStable: isTrackingStable,
            isHighQuality: isHighQuality
        )
    }

    private func guidanceText(
        for trackingState: ARCamera.TrackingState?,
        quality: CaptureQualityState? = nil
    ) -> String {
        guard let trackingState else {
            return "空間の準備を整えています。端末を安定させて少しお待ちください。"
        }

        switch trackingState {
        case .limited(.initializing):
            return "初期化中です。端末を胸の前で安定させて、少しだけ待ってください。"
        case .limited(.insufficientFeatures):
            return "壁・家具・床の境目が入るように、足は止めたまま上下左右へゆっくり向けてください。"
        case .limited(.excessiveMotion):
            return "動きが速すぎます。前へ進まず、体を軸にしてゆっくり回ってください。"
        case .limited(.relocalizing):
            return "位置合わせ中です。直前に見た場所へゆっくり戻してください。"
        case .limited:
            return "追跡を整えています。端末を胸の前へ戻し、同じ地点から輪郭を重ねてください。"
        case .normal:
            guard let quality else {
                return "足を止めて、その場でゆっくり360度回転してください。"
            }
            if quality.isHighQuality {
                if isImprovingAfterReady {
                    return "高精度に到達済みです。さらに良くするには、同じ場所で2周目をゆっくり続けてください。"
                }
                return "高精度に到達しました。保存できます。続けるとフレーム密度がさらに上がります。"
            }
            if sampledFrameCount < 10 {
                return "まず足を止め、端末を胸の前で構えたまま周囲の輪郭を集めています。"
            }
            if quality.stationaryCoverage < 0.55 {
                return "前後左右へ歩かず、体の中心へ端末を戻してください。同じ地点からの360度を優先します。"
            }
            if quality.headingCoverage < 0.82 {
                return "その場でゆっくり回転し、背後まで含めて360度の方位を埋めてください。"
            }
            if quality.verticalCoverage < 0.75 {
                return "足は止めたまま、端末を上段・正面・下段へゆっくり向けて上下の情報を足してください。"
            }
            if quality.pointCloudCoverage < 0.72 {
                return "カメラ内の黄色い点が少ない面を狙ってください。\(quality.coverageFocusText)"
            }
            if frameSamples.count < CaptureConstants.minimumHighQualityFrameCount {
                return "360度と点群は取れています。色付き3D化に必要な保存フレームをもう少し集めています。"
            }
            if sampledFrameCount < CaptureConstants.minimumHighQualityFrameCount {
                return "角度は揃ってきました。同じ地点でもう少しゆっくり続け、フレーム密度を上げています。"
            }
            return "良好です。速度を保ち、輪郭が重なるようにその場で仕上げています。"
        case .notAvailable:
            return "空間の準備を整えています。端末を安定させて少しお待ちください。"
        }
    }

    private func qualityStatus(for quality: CaptureQualityState) -> String {
        if quality.trackingStability < 0.5 {
            return "追跡を整えています"
        }
        if sampledFrameCount < 10 {
            return "輪郭を収集中"
        }
        if quality.stationaryCoverage < 0.55 {
            return "同じ地点へ戻してください"
        }
        if quality.headingCoverage < 0.82 {
            return "360度を収集中"
        }
        if quality.verticalCoverage < 0.75 {
            return "上下レンジを収集中"
        }
        if quality.pointCloudCoverage < 0.55 {
            return "3D点群を収集中"
        }
        if quality.surfaceCoverage < 0.64 {
            return "未取得方向を補完中"
        }
        if frameSamples.count < CaptureConstants.minimumHighQualityFrameCount {
            return "保存フレームを収集中"
        }
        if sampledFrameCount < CaptureConstants.minimumHighQualityFrameCount {
            return "フレーム密度を収集中"
        }
        return "高精度化中"
    }

    private func motionHint(for quality: CaptureQualityState, trackingState: ARCamera.TrackingState?) -> String {
        if case .limited(.excessiveMotion) = trackingState {
            return "速すぎます。端末をなめらかに戻してください。"
        }
        if quality.stationaryCoverage < 0.55 {
            return "足を止めて中心へ"
        }
        if quality.headingCoverage < 0.82 {
            return "その場で360度"
        }
        if quality.verticalCoverage < 0.75 {
            return "上・正面・下を追加"
        }
        if quality.pointCloudCoverage < 0.55 {
            return "輪郭を多く入れる"
        }
        if frameSamples.count < CaptureConstants.minimumHighQualityFrameCount {
            return "同じ速度で保存中"
        }
        if sampledFrameCount < CaptureConstants.minimumHighQualityFrameCount {
            return "同じ速度で続ける"
        }
        if quality.trackingStability < 0.9 {
            return "輪郭が多い場所へ"
        }
        return isHighQualityReady ? "保存または継続" : "そのまま高精度化"
    }

    private static var emptyCoverageCells: [Bool] {
        Array(
            repeating: false,
            count: CaptureConstants.headingCoverageBucketCount * CaptureConstants.verticalCoverageBandCount
        )
    }

    private func adaptivePointTarget(
        headingScore: Double,
        verticalScore: Double,
        frameScore: Double,
        surfaceCoverage: Double
    ) -> Double {
        let coverageBonus = min((headingScore + verticalScore + frameScore + surfaceCoverage) / 4, 1)
        let targetRange = Double(CaptureConstants.preferredPointSampleCount - CaptureConstants.minimumHighQualityPointSampleCount)
        return Double(CaptureConstants.minimumHighQualityPointSampleCount) + (targetRange * coverageBonus)
    }

    private func captureCoverageMap(for samples: [CapturePoseSample]) -> CaptureCoverageMap {
        var cells = Self.emptyCoverageCells
        guard !samples.isEmpty else {
            return CaptureCoverageMap(cells: cells, coverageScore: 0, focusText: "まず正面からゆっくり始めてください。")
        }

        for sample in samples {
            guard let heading = sample.headingDegrees else { continue }
            guard let index = coverageCellIndex(heading: heading, pitch: sample.pitchDegrees) else { continue }
            if cells.indices.contains(index) {
                cells[index] = true
            }
        }

        let filledCount = cells.filter { $0 }.count
        let centerBandStart = CaptureConstants.headingCoverageBucketCount
        let centerBandEnd = centerBandStart + CaptureConstants.headingCoverageBucketCount
        let centerFilled = cells[centerBandStart..<centerBandEnd].filter { $0 }.count
        let coverageScore = min(
            (Double(filledCount) / Double(cells.count) * 0.64)
                + (Double(centerFilled) / Double(CaptureConstants.headingCoverageBucketCount) * 0.36),
            1
        )

        let focusText = nextCoverageFocusText(from: cells)
        return CaptureCoverageMap(cells: cells, coverageScore: coverageScore, focusText: focusText)
    }

    private func coverageCellIndex(heading: Double?, pitch: Double?) -> Int? {
        guard let heading else { return nil }
        let pitch = pitch ?? 0
        let band: Int
        if pitch > 18 {
            band = 0
        } else if pitch < -18 {
            band = 2
        } else {
            band = 1
        }

        let normalizedHeading = ImmersiveDirectionSpace.normalizedDegrees(heading)
        let rawBucket = Int((normalizedHeading / 360) * Double(CaptureConstants.headingCoverageBucketCount))
        let bucket = min(max(rawBucket, 0), CaptureConstants.headingCoverageBucketCount - 1)
        return (band * CaptureConstants.headingCoverageBucketCount) + bucket
    }

    private func nextCoverageFocusText(from cells: [Bool]) -> String {
        let bandLabels = ["上段", "正面", "下段"]
        for band in [1, 0, 2] {
            let start = band * CaptureConstants.headingCoverageBucketCount
            let end = start + CaptureConstants.headingCoverageBucketCount
            guard cells.indices.contains(start), cells.indices.contains(end - 1) else { continue }
            let bandCells = Array(cells[start..<end])
            if let missingIndex = bandCells.firstIndex(of: false) {
                let direction = directionLabel(forBucket: missingIndex)
                return "\(bandLabels[band])の\(direction)へ向けると100%に近づきます。"
            }
        }
        return "全方向が埋まっています。同じ場所でもう一周して密度を上げてください。"
    }

    private func directionLabel(forBucket bucket: Int) -> String {
        switch bucket {
        case 0, 11:
            return "北側"
        case 1, 2:
            return "北東側"
        case 3:
            return "東側"
        case 4, 5:
            return "南東側"
        case 6:
            return "南側"
        case 7, 8:
            return "南西側"
        case 9:
            return "西側"
        default:
            return "北西側"
        }
    }

    private func trackingScore(for trackingState: ARCamera.TrackingState?) -> Double {
        guard let trackingState else { return 0 }
        switch trackingState {
        case .normal:
            return 1
        case .limited(.insufficientFeatures):
            return 0.42
        case .limited(.excessiveMotion):
            return 0.22
        case .limited(.initializing):
            return 0.18
        case .limited(.relocalizing):
            return 0.25
        case .limited:
            return 0.35
        case .notAvailable:
            return 0
        }
    }

    private func translationExtentMeters(for samples: [CapturePoseSample]) -> Double {
        let translations = samples.map(\.translationVector)
        guard let first = translations.first else { return 0 }

        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        var minZ = first.z
        var maxZ = first.z

        for translation in translations.dropFirst() {
            minX = min(minX, translation.x)
            maxX = max(maxX, translation.x)
            minY = min(minY, translation.y)
            maxY = max(maxY, translation.y)
            minZ = min(minZ, translation.z)
            maxZ = max(maxZ, translation.z)
        }

        let deltaX = maxX - minX
        let deltaY = maxY - minY
        let deltaZ = maxZ - minZ
        return sqrt((deltaX * deltaX) + (deltaY * deltaY) + (deltaZ * deltaZ))
    }

    private func headingSpanDegrees(for headings: [Double]) -> Double {
        guard headings.count > 1 else { return 0 }
        let normalized = headings
            .map(ImmersiveDirectionSpace.normalizedDegrees)
            .sorted()

        guard let first = normalized.first, let last = normalized.last else { return 0 }
        var largestGap = first + 360 - last
        for pair in zip(normalized, normalized.dropFirst()) {
            largestGap = max(largestGap, pair.1 - pair.0)
        }
        return min(max(360 - largestGap, 0), 360)
    }

    private func linearSpanDegrees(for values: [Double]) -> Double {
        guard let minimum = values.min(), let maximum = values.max() else { return 0 }
        return min(max(maximum - minimum, 0), 180)
    }

    private func stationaryScore(forTranslationExtent translationExtent: Double) -> Double {
        if translationExtent <= CaptureConstants.idealStationaryDriftMeters {
            return 1
        }
        if translationExtent >= CaptureConstants.maximumStationaryDriftMeters {
            return 0
        }
        let range = CaptureConstants.maximumStationaryDriftMeters - CaptureConstants.idealStationaryDriftMeters
        return 1 - ((translationExtent - CaptureConstants.idealStationaryDriftMeters) / range)
    }

    private func captureHeadingDegrees(from transform: simd_float4x4?) -> Double? {
        guard let transform else { return nil }
        let forward = -transform.columns.2.xyz
        let magnitude = simd_length(forward)
        guard magnitude > 0 else { return nil }
        let normalizedForward = forward / magnitude
        let degrees = atan2(Double(normalizedForward.x), Double(-normalizedForward.z)) * 180 / .pi
        return degrees >= 0 ? degrees : degrees + 360
    }

    private func jpegData(from pixelBuffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 1.0)
    }

    private func previewJPEGData(from pixelBuffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(
            cgImage: cgImage,
            scale: 1,
            orientation: previewImageOrientation
        ).jpegData(compressionQuality: 0.96)
    }

    private var previewImageOrientation: UIImage.Orientation {
        switch UIDevice.current.orientation {
        case .landscapeLeft:
            return .up
        case .landscapeRight:
            return .down
        case .portraitUpsideDown:
            return .left
        default:
            return .right
        }
    }

    private func flattenedMatrix(_ matrix: simd_float4x4) -> [Float] {
        [
            matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z, matrix.columns.0.w,
            matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z, matrix.columns.1.w,
            matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z, matrix.columns.2.w,
            matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z, matrix.columns.3.w
        ]
    }

    private func flattenedMatrix(_ matrix: simd_float3x3) -> [Float] {
        [
            matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z,
            matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z,
            matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z
        ]
    }
}

private extension simd_float4 {
    var xyz: simd_float3 {
        simd_float3(x, y, z)
    }
}

struct SpatialScanCaptureView: View {
    let onComplete: (CapturedMemoryDraft) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SpatialScanCaptureModel()
    @State private var hasStarted = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            SpatialScanPreviewContainer { session in
                model.bind(session: session)
            }
            .ignoresSafeArea()

            LinearGradient(colors: [.black.opacity(0.6), .clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            if model.isOptimizingScan {
                SpatialScanOptimizationStage(
                    progress: model.optimizationProgress,
                    statusText: model.optimizationStatusText
                )
                .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    topBar
                    HStack {
                        Spacer()
                        livePointCloudPanel
                    }
                    .padding(.top, 10)
                    Spacer()
                    bottomPanel
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 12)
            }
        }
        .task {
            guard !hasStarted else { return }
            hasStarted = true
            do {
                let draft = try await model.captureScan()
                dismiss()
                onComplete(draft)
            } catch is CancellationError {
                dismiss()
                onCancel()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        .alert("3Dスキャンを完了できませんでした", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("閉じる") {
                let hadError = errorMessage != nil
                errorMessage = nil
                if hadError {
                    dismiss()
                    onCancel()
                }
            }
        } message: {
            Text(errorMessage ?? "")
        }
        .interactiveDismissDisabled(model.isScanning || model.isOptimizingScan)
        .onDisappear {
            if model.isScanning {
                model.cancelCapture()
            }
            model.unbind()
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                model.cancelCapture()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(.black.opacity(0.42), in: Circle())
            }

            Spacer()

            VStack(spacing: 4) {
                Text("3D Scan")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(model.qualityStatusText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
            }

            Spacer()

            Text("\(model.qualityPercent)%")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.black.opacity(0.42), in: Capsule())
        }
    }

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            motionGuide
            if !model.isHighQualityReady {
                scanNavigationGuide
            }

            ProgressView(value: model.progress)
                .tint(.white)

            Text(model.guidanceText)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.78))

            scanCoverageRadar

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                scanHintChip(title: "360°", value: "\(Int((model.headingCoverage * 100).rounded()))%")
                scanHintChip(title: "上下", value: "\(Int((model.verticalCoverage * 100).rounded()))%")
                scanHintChip(title: "点群", value: "\(Int((model.pointCloudCoverage * 100).rounded()))%")
                scanHintChip(title: "静止", value: "\(Int((model.stationaryCoverage * 100).rounded()))%")
                scanHintChip(title: "安定", value: "\(Int((model.trackingStability * 100).rounded()))%")
            }

            if model.isHighQualityReady {
                highQualityActions
            }
        }
        .padding(14)
        .background(.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.14))
        }
    }

    private var livePointCloudPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "cube.transparent")
                    .font(.caption.weight(.bold))
                Text("Live 3D")
                    .font(.caption.weight(.bold))
                Spacer()
                Text("\(model.livePreviewPoints.count)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .foregroundStyle(.white)

            SpatialScanLivePointCloudView(points: model.livePreviewPoints)
                .frame(width: 148, height: 118)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(10)
        .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.16))
        }
        .accessibilityLabel("リアルタイム3D取得プレビュー")
    }

    private var motionGuide: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.34), lineWidth: 2)
                    .frame(width: 86, height: 86)

                Image(systemName: "arrow.clockwise")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white.opacity(0.86))
                    .offset(x: 31, y: -30)

                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.65), lineWidth: 2)
                    .frame(width: 54, height: 82)
                    .rotationEffect(.degrees(-12 + (model.headingCoverage * 24)))

                Circle()
                    .fill(.white.opacity(0.7))
                    .frame(width: 8, height: 8)

                Image(systemName: "arrow.up.and.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .offset(x: -34, y: 0)
            }
            .frame(width: 90, height: 96)

            VStack(alignment: .leading, spacing: 7) {
                Text(model.motionHintText)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.84)

                Text("足は動かさず、体を軸に360度。端末は上段・正面・下段へゆっくり向けます。")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.74))
            }
        }
    }

    private var scanNavigationGuide: some View {
        VStack(alignment: .leading, spacing: 8) {
            scanStepRow(index: "1", text: "足をその場に固定し、端末を胸の前に戻す")
            scanStepRow(index: "2", text: "体ごとゆっくり360度回り、背後まで埋める")
            scanStepRow(index: "3", text: "同じ地点から上・正面・下へ向けて密度を足す")
        }
        .padding(.vertical, 2)
    }

    private func scanStepRow(index: String, text: String) -> some View {
        HStack(spacing: 9) {
            Text(index)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 20, height: 20)
                .background(.white, in: Circle())
            Text(text)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.76))
                .lineLimit(2)
                .minimumScaleFactor(0.82)
        }
    }

    private var scanCoverageRadar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("取得マップ", systemImage: "viewfinder")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(model.collectedPointCount) pts")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
            }

            VStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { band in
                    HStack(spacing: 5) {
                        Text(coverageBandLabel(band))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.66))
                            .frame(width: 18, alignment: .leading)

                        ForEach(0..<12, id: \.self) { bucket in
                            Capsule()
                                .fill(.white.opacity(coverageCellOpacity(band: band, bucket: bucket)))
                                .frame(height: 8)
                        }
                    }
                }
            }

            Text(model.coverageFocusText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(2)
                .minimumScaleFactor(0.86)
        }
        .padding(12)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12))
        }
    }

    private func coverageBandLabel(_ band: Int) -> String {
        switch band {
        case 0:
            return "上"
        case 2:
            return "下"
        default:
            return "正"
        }
    }

    private func coverageCellOpacity(band: Int, bucket: Int) -> Double {
        let index = (band * 12) + bucket
        guard model.captureCoverageCells.indices.contains(index) else { return 0.14 }
        return model.captureCoverageCells[index] ? 0.9 : 0.14
    }

    private var highQualityActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("高精度に到達済み。保存を押すまで自動で記録を続け、密度を上げ続けます。")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)

            Button {
                model.finishHighQualityCapture()
            } label: {
                Label("保存して最適化", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.black)
        }
        .padding(12)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.16))
        }
    }

    private func scanHintChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.62))
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct SpatialScanOptimizationStage: View {
    let progress: Double
    let statusText: String

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(.white.opacity(0.16), lineWidth: 13)
                    .frame(width: 132, height: 132)
                Circle()
                    .trim(from: 0, to: min(max(progress, 0), 1))
                    .stroke(.white, style: StrokeStyle(lineWidth: 13, lineCap: .round))
                    .frame(width: 132, height: 132)
                    .rotationEffect(.degrees(-90))
                Image(systemName: "cube.transparent")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 10) {
                Text("3Dを最適化中")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text(statusText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.86))
                Text("点群を軽量な3Dプレビュー用データへ変換しています。完了後に記録画面へ進みます。")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: 310)
            }

            ProgressView(value: min(max(progress, 0), 1))
                .tint(.white)
                .frame(maxWidth: 260)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(.black.opacity(0.42))
    }
}

private struct SpatialScanLivePointCloudView: UIViewRepresentable {
    let points: [SpatialScanLivePreviewPoint]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SCNView {
        context.coordinator.makeView()
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.update(points: points)
    }

    final class Coordinator {
        private let scene = SCNScene()
        private let modelRoot = SCNNode()
        private let pointNode = SCNNode()
        private let cameraNode = SCNNode()
        private var signature = ""

        func makeView() -> SCNView {
            scene.background.contents = UIColor.clear
            scene.rootNode.addChildNode(modelRoot)
            modelRoot.addChildNode(pointNode)
            modelRoot.eulerAngles = SCNVector3(-0.32, 0.58, 0)

            let camera = SCNCamera()
            camera.fieldOfView = 58
            camera.zNear = 0.01
            camera.zFar = 80
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(0, 0.08, 3.2)
            scene.rootNode.addChildNode(cameraNode)

            let view = SCNView()
            view.scene = scene
            view.pointOfView = cameraNode
            view.backgroundColor = .clear
            view.isOpaque = false
            view.isPlaying = false
            view.rendersContinuously = false
            view.preferredFramesPerSecond = 24
            view.antialiasingMode = .none
            view.allowsCameraControl = false
            return view
        }

        func update(points: [SpatialScanLivePreviewPoint]) {
            let nextSignature = "\(points.count):\(points.first?.id ?? 0):\(points.last?.id ?? 0)"
            guard nextSignature != signature else { return }
            signature = nextSignature

            guard points.count > 3 else {
                pointNode.geometry = nil
                return
            }

            let vertices = normalizedVertices(from: points)
            guard !vertices.isEmpty else {
                pointNode.geometry = nil
                return
            }

            var colors: [SIMD4<Float>] = []
            colors.reserveCapacity(vertices.count)
            let denominator = max(Float(vertices.count - 1), 1)
            for index in vertices.indices {
                let recency = Float(index) / denominator
                colors.append(
                    SIMD4<Float>(
                        0.34 + (recency * 0.48),
                        0.72 + (recency * 0.22),
                        1.0,
                        1.0
                    )
                )
            }

            let vertexSource = SCNGeometrySource(vertices: vertices)
            let colorData = colors.withUnsafeBytes { Data($0) }
            let colorSource = SCNGeometrySource(
                data: colorData,
                semantic: .color,
                vectorCount: colors.count,
                usesFloatComponents: true,
                componentsPerVector: 4,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<SIMD4<Float>>.stride
            )
            let indices: [Int32] = vertices.indices.map { Int32($0) }
            let indexData = indices.withUnsafeBytes { Data($0) }
            let element = SCNGeometryElement(
                data: indexData,
                primitiveType: .point,
                primitiveCount: vertices.count,
                bytesPerIndex: MemoryLayout<Int32>.size
            )
            element.pointSize = 4
            element.minimumPointScreenSpaceRadius = 2
            element.maximumPointScreenSpaceRadius = 7

            let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = UIColor.white
            material.emission.contents = UIColor.white.withAlphaComponent(0.12)
            material.blendMode = .alpha
            material.readsFromDepthBuffer = false
            material.writesToDepthBuffer = false
            geometry.materials = [material]
            pointNode.geometry = geometry
        }

        private func normalizedVertices(from points: [SpatialScanLivePreviewPoint]) -> [SCNVector3] {
            guard let first = points.first else { return [] }
            var minX = first.x
            var maxX = first.x
            var minY = first.y
            var maxY = first.y
            var minZ = first.z
            var maxZ = first.z

            for point in points.dropFirst() {
                minX = min(minX, point.x)
                maxX = max(maxX, point.x)
                minY = min(minY, point.y)
                maxY = max(maxY, point.y)
                minZ = min(minZ, point.z)
                maxZ = max(maxZ, point.z)
            }

            let centerX = (minX + maxX) / 2
            let centerY = (minY + maxY) / 2
            let centerZ = (minZ + maxZ) / 2
            let extent = max(maxX - minX, maxY - minY, maxZ - minZ, 0.2)
            let scale = min(2.1 / extent, 5.4)

            return points.map { point in
                SCNVector3(
                    (point.x - centerX) * scale,
                    ((point.y - centerY) * scale) + 0.04,
                    (point.z - centerZ) * scale
                )
            }
        }
    }
}

private struct SpatialScanPreviewContainer: UIViewRepresentable {
    let onSessionReady: (ARSession) -> Void

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.automaticallyUpdatesLighting = true
        view.debugOptions = [.showFeaturePoints]
        view.preferredFramesPerSecond = 60
        view.scene = SCNScene()
        view.contentMode = .scaleAspectFill
        onSessionReady(view.session)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        uiView.debugOptions = [.showFeaturePoints]
        onSessionReady(uiView.session)
    }
}

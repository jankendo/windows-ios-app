import ARKit
import AVFoundation
import CoreImage
import SceneKit
import SwiftUI
import UIKit

@MainActor
final class SpatialScanCaptureModel: NSObject, ObservableObject, @preconcurrency ARSessionDelegate {
    private enum CaptureConstants {
        static let frameSamplingInterval: TimeInterval = 0.28
        static let minimumTranslationMeters: Float = 0.018
        static let minimumRotationRadians: Float = 0.045
        static let minimumQualityEvaluationDuration: TimeInterval = 10
        static let preferredFrameCount = 48
        static let preferredHeadingSpanDegrees = 330.0
        static let preferredVerticalSpanDegrees = 70.0
        static let highQualityScore = 0.92
        static let minimumHighQualityFrameCount = 34
        static let minimumHighQualityHeadingSpanDegrees = 300.0
        static let minimumHighQualityVerticalSpanDegrees = 52.0
        static let idealStationaryDriftMeters = 0.85
        static let maximumStationaryDriftMeters = 1.6
        static let maximumPointSampleCount = 9_000
        static let maximumPointSamplesPerFrame = 220
        static let preferredPointSampleCount = 4_800
        static let minimumHighQualityPointSampleCount = 1_800
        static let minimumFeaturePointDistanceMeters: Float = 0.25
        static let maximumFeaturePointDistanceMeters: Float = 7.0
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
    @Published private(set) var qualityStatusText = "精度を測定しています"
    @Published private(set) var motionHintText = "端末を胸の前で構え、足を止めてください。"
    @Published private(set) var isHighQualityReady = false
    @Published private(set) var isImprovingAfterReady = false

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
    private var pointSamples: [SpatialScanPointSample] = []
    private var seenPointIdentifiers = Set<UInt64>()
    private var firstFrameTimestamp: TimeInterval?
    private var lastFrameTimestamp: TimeInterval = 0
    private var lastCameraTransform: simd_float4x4?
    private var previewImageData: Data?
    private var previewImageFileName = "preview.jpg"
    private var worldMapFileName: String?
    private var captureResolved = false
    private var isFinishingCapture = false
    private var hasSentHighQualityFeedback = false

    private struct CaptureQualityState {
        let score: Double
        let headingCoverage: Double
        let verticalCoverage: Double
        let stationaryCoverage: Double
        let pointCloudCoverage: Double
        let trackingStability: Double
        let isTrackingStable: Bool
        let isHighQuality: Bool
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
            _ = appendFrameSample(from: frame, elapsed: elapsed, bundleURL: bundleURL)
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

    func continueImprovingCapture() {
        guard isHighQualityReady else { return }
        isImprovingAfterReady = true
        qualityStatusText = "高精度を超えて強化中"
        guidanceText = "保存できます。さらに密度を上げる場合は、その場で2周目をゆっくり続けてください。"
        motionHintText = "続けて密度を上げる"
    }

    private func finishCapture() async {
        guard isScanning, !isFinishingCapture, let bundleURL else { return }
        isFinishingCapture = true
        qualityStatusText = "空間を仕上げています"
        guidanceText = "高精度の360度スキャンを保存用の空間データへまとめています。"
        motionHintText = "端末をそのまま安定させてください。"

        captureTimerTask?.cancel()
        captureTimerTask = nil

        if previewImageData == nil || frameSamples.isEmpty,
           let currentFrame = arSession?.currentFrame {
            let elapsed = resolvedElapsed(for: currentFrame)
            _ = appendFrameSample(from: currentFrame, elapsed: elapsed, bundleURL: bundleURL)
        }

        arSession?.pause()

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
            let manifest = SpatialScanManifest(
                capturedAt: startedAt ?? .now,
                captureDuration: max(audioResult.duration, lastFrameTimestamp),
                frameCount: frameSamples.count,
                fieldOfViewLimited: true,
                anchorHeadingDegrees: captureHeadingDegrees(from: lastCameraTransform),
                previewImageFileName: previewImageFileName,
                worldMapFileName: worldMapFileName,
                reconstructionState: .captured,
                pointSamples: pointSamples,
                frameSamples: frameSamples
            )

            let manifestURL = bundleURL.appendingPathComponent("manifest.json")
            do {
                let data = try JSONEncoder().encode(manifest)
                try data.write(to: manifestURL, options: .atomic)
                let draft = CapturedMemoryDraft(
                    photoData: previewImageData,
                    audioTempURL: audioResult.primaryURL,
                    analysisAudioTempURL: audioResult.analysisURL ?? audioResult.primaryURL,
                    spatialScanPayload: SpatialScanCapturePayload(bundleURL: bundleURL, manifest: manifest),
                    capturedAt: manifest.capturedAt,
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
        case .failure(let error):
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
        qualityStatusText = "精度を測定しています"
        motionHintText = "端末を胸の前で構え、足を止めてください。"
        isHighQualityReady = false
        isImprovingAfterReady = false
        sampledFrameCount = 0
        frameSamples = []
        pointSamples = []
        seenPointIdentifiers = []
        firstFrameTimestamp = nil
        lastFrameTimestamp = 0
        lastCameraTransform = nil
        previewImageData = nil
        previewImageFileName = "preview.jpg"
        worldMapFileName = nil
        isFinishingCapture = false
        hasSentHighQualityFeedback = false
        captureResolved = false
        isScanning = false
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
        qualityStatusText = "精度を測定しています"
        motionHintText = "端末を胸の前で構え、足を止めてください。"
        guidanceText = "足を止めたまま、その場で360度の輪郭を集めます。"
        isHighQualityReady = false
        isImprovingAfterReady = false
        if audioSession.isRunning {
            audioSession.stopRunning()
        }
        arSession?.pause()
        bundleURL = nil
        firstFrameTimestamp = nil
        lastFrameTimestamp = 0
        lastCameraTransform = nil
        previewImageData = nil
        previewImageFileName = "preview.jpg"
        worldMapFileName = nil
        frameSamples = []
        pointSamples = []
        seenPointIdentifiers = []
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
    private func appendFrameSample(from frame: ARFrame, elapsed: TimeInterval, bundleURL: URL) -> Bool {
        let framesFolderURL = bundleURL.appendingPathComponent("frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: framesFolderURL, withIntermediateDirectories: true)

        let frameIndex = frameSamples.count + 1
        let imageFileName = String(format: "frame-%03d.jpg", frameIndex)
        let imageURL = framesFolderURL.appendingPathComponent(imageFileName)

        guard let frameJPEGData = jpegData(from: frame.capturedImage) else { return false }
        do {
            try frameJPEGData.write(to: imageURL, options: .atomic)
        } catch {
            return false
        }

        if previewImageData == nil {
            let previewData = previewJPEGData(from: frame.capturedImage) ?? frameJPEGData
            previewImageData = previewData
            let previewURL = bundleURL.appendingPathComponent(previewImageFileName)
            try? previewData.write(to: previewURL, options: .atomic)
        }

        frameSamples.append(
            SpatialScanFrameSample(
                imageFileName: "frames/\(imageFileName)",
                timeOffset: max(elapsed, 0),
                cameraTransform: flattenedMatrix(frame.camera.transform),
                cameraIntrinsics: flattenedMatrix(frame.camera.intrinsics),
                imageWidth: CVPixelBufferGetWidth(frame.capturedImage),
                imageHeight: CVPixelBufferGetHeight(frame.capturedImage)
            )
        )
        appendPointSamples(from: frame, sourceFrameIndex: frameIndex - 1)
        sampledFrameCount = frameSamples.count
        lastCameraTransform = frame.camera.transform
        lastFrameTimestamp = max(elapsed, lastFrameTimestamp)
        return true
    }

    private func appendPointSamples(from frame: ARFrame, sourceFrameIndex: Int) {
        guard pointSamples.count < CaptureConstants.maximumPointSampleCount,
              let pointCloud = frame.rawFeaturePoints else {
            return
        }

        let points = pointCloud.points
        guard !points.isEmpty else { return }

        let identifiers = pointCloud.identifiers
        let cameraPosition = frame.camera.transform.columns.3.xyz
        let sampleStride = max(points.count / CaptureConstants.maximumPointSamplesPerFrame, 1)
        var addedCount = 0

        for index in stride(from: 0, to: points.count, by: sampleStride) {
            guard pointSamples.count < CaptureConstants.maximumPointSampleCount,
                  addedCount < CaptureConstants.maximumPointSamplesPerFrame else {
                break
            }

            let identifier = identifiers.indices.contains(index) ? identifiers[index] : nil
            if let identifier, seenPointIdentifiers.contains(identifier) {
                continue
            }

            let point = points[index]
            let distance = simd_length(point - cameraPosition)
            guard distance >= CaptureConstants.minimumFeaturePointDistanceMeters,
                  distance <= CaptureConstants.maximumFeaturePointDistanceMeters else {
                continue
            }
            if let identifier {
                seenPointIdentifiers.insert(identifier)
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
            addedCount += 1
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
        guidanceText = guidanceText(for: trackingState, quality: quality)
        motionHintText = motionHint(for: quality, trackingState: trackingState)

        if quality.isHighQuality {
            if !isHighQualityReady && !hasSentHighQualityFeedback {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                hasSentHighQualityFeedback = true
            }
            isHighQualityReady = true
            qualityStatusText = isImprovingAfterReady ? "高精度を超えて強化中" : "高精度に到達"
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
        let frameScore = min(Double(frameSamples.count) / Double(CaptureConstants.preferredFrameCount), 1)
        let translationExtent = translationExtentMeters(for: frameSamples)
        let stationaryScore = stationaryScore(forTranslationExtent: translationExtent)
        let headingSpan = headingSpanDegrees(for: frameSamples.compactMap(\.headingDegrees))
        let verticalSpan = linearSpanDegrees(for: frameSamples.compactMap(\.pitchDegrees))
        let headingScore = min(headingSpan / CaptureConstants.preferredHeadingSpanDegrees, 1)
        let verticalScore = min(verticalSpan / CaptureConstants.preferredVerticalSpanDegrees, 1)
        let pointScore = min(Double(pointSamples.count) / Double(CaptureConstants.preferredPointSampleCount), 1)
        let trackingScore = trackingScore(for: trackingState)
        let durationScore = min(elapsed / CaptureConstants.minimumQualityEvaluationDuration, 1)
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
            && frameSamples.count >= CaptureConstants.minimumHighQualityFrameCount
            && headingSpan >= CaptureConstants.minimumHighQualityHeadingSpanDegrees
            && verticalSpan >= CaptureConstants.minimumHighQualityVerticalSpanDegrees
            && pointSamples.count >= CaptureConstants.minimumHighQualityPointSampleCount
            && score >= CaptureConstants.highQualityScore
            && stationaryScore >= 0.55
            && isTrackingStable

        return CaptureQualityState(
            score: score,
            headingCoverage: headingScore,
            verticalCoverage: verticalScore,
            stationaryCoverage: stationaryScore,
            pointCloudCoverage: pointScore,
            trackingStability: trackingScore,
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
            if quality.pointCloudCoverage < 0.55 {
                return "3D点群を増やしています。壁・家具・床の境目を入れたまま、同じ地点でもう一周してください。"
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
        if sampledFrameCount < CaptureConstants.minimumHighQualityFrameCount {
            return "同じ速度で続ける"
        }
        if quality.trackingStability < 0.9 {
            return "輪郭が多い場所へ"
        }
        return isHighQualityReady ? "保存または継続" : "そのまま高精度化"
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

    private func translationExtentMeters(for samples: [SpatialScanFrameSample]) -> Double {
        let translations = samples.compactMap(\.translationVector)
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
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.82)
    }

    private func previewJPEGData(from pixelBuffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(
            cgImage: cgImage,
            scale: 1,
            orientation: previewImageOrientation
        ).jpegData(compressionQuality: 0.86)
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

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomPanel
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
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
        .interactiveDismissDisabled(model.isScanning)
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
        VStack(alignment: .leading, spacing: 14) {
            motionGuide
            scanNavigationGuide

            ProgressView(value: model.progress)
                .tint(.white)

            Text(model.guidanceText)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.78))

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
        .padding(18)
        .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.14))
        }
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

    private var highQualityActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.isImprovingAfterReady ? "高精度に到達済み。続けるほど密度が上がります。" : "高精度に到達しました。保存するか、さらに続けられます。")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)

            HStack(spacing: 10) {
                Button {
                    model.finishHighQualityCapture()
                } label: {
                    Label("保存", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)

                Button {
                    model.continueImprovingCapture()
                } label: {
                    Label("続ける", systemImage: "plus.viewfinder")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
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

private struct SpatialScanPreviewContainer: UIViewRepresentable {
    let onSessionReady: (ARSession) -> Void

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.automaticallyUpdatesLighting = true
        view.scene = SCNScene()
        view.contentMode = .scaleAspectFill
        onSessionReady(view.session)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        onSessionReady(uiView.session)
    }
}

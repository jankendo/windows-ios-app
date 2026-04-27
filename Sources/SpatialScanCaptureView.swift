import ARKit
import AVFoundation
import CoreImage
import SceneKit
import SwiftUI
import UIKit

@MainActor
final class SpatialScanCaptureModel: NSObject, ObservableObject, @preconcurrency ARSessionDelegate {
    @Published private(set) var isScanning = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var sampledFrameCount = 0
    @Published private(set) var guidanceText = "空間をゆっくり見渡して、その場の輪郭を集めます。"

    private weak var arSession: ARSession?
    private let ciContext = CIContext()
    private let audioSession = AVCaptureSession()
    private let ambientAudioCapture = AmbientAudioCaptureCoordinator()

    private var audioInput: AVCaptureDeviceInput?
    private var captureContinuation: CheckedContinuation<CapturedMemoryDraft, Error>?
    private var captureTimerTask: Task<Void, Never>?
    private var startedAt: Date?
    private var targetDuration: TimeInterval = 8
    private var bundleURL: URL?
    private var frameSamples: [SpatialScanFrameSample] = []
    private var firstFrameTimestamp: TimeInterval?
    private var lastFrameTimestamp: TimeInterval = 0
    private var lastCameraTransform: simd_float4x4?
    private var previewImageData: Data?
    private var previewImageFileName = "preview.jpg"
    private var worldMapFileName: String?

    func bind(session: ARSession) {
        guard arSession !== session else { return }
        arSession = session
        session.delegate = self
    }

    func captureScan(duration: TimeInterval) async throws -> CapturedMemoryDraft {
        guard ARWorldTrackingConfiguration.isSupported else {
            throw CaptureError.configurationFailed
        }
        if arSession == nil {
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if arSession != nil {
                    break
                }
            }
        }
        guard let arSession else {
            throw CaptureError.sessionNotReady
        }
        guard !isScanning else {
            throw CaptureError.busy
        }

        targetDuration = max(3, min(duration, 15))
        remainingSeconds = Int(targetDuration.rounded(.up))
        progress = 0
        guidanceText = "空間を滑らかになぞり、少しずつ向きを変えてください。"
        sampledFrameCount = 0
        frameSamples = []
        firstFrameTimestamp = nil
        lastFrameTimestamp = 0
        lastCameraTransform = nil
        previewImageData = nil
        previewImageFileName = "preview.jpg"
        worldMapFileName = nil
        bundleURL = try createBundleFolder()

        try configureAudioCapture()
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravityAndHeading
        configuration.environmentTexturing = .automatic
        arSession.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        _ = try ambientAudioCapture.startRecording()
        startedAt = .now
        isScanning = true

        return try await withCheckedThrowingContinuation { continuation in
            captureContinuation = continuation

            captureTimerTask = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard let startedAt = self.startedAt else { continue }
                    let elapsed = Date().timeIntervalSince(startedAt)
                    await MainActor.run {
                        self.progress = min(elapsed / self.targetDuration, 1)
                        self.remainingSeconds = max(Int((self.targetDuration - elapsed).rounded(.up)), 0)
                        if self.sampledFrameCount < 5 {
                            self.guidanceText = "その場で半歩ぶんだけ視線を動かし、重なりを保ちながら集めています。"
                        } else {
                            self.guidanceText = "良好です。端を一度なぞるように見渡すと精度が安定します。"
                        }
                    }

                    if elapsed >= self.targetDuration {
                        await self.finishCapture()
                        break
                    }
                }
            }
        }
    }

    func cancelCapture() {
        captureTimerTask?.cancel()
        captureTimerTask = nil
        arSession?.pause()
        if audioSession.isRunning {
            audioSession.stopRunning()
        }
        ambientAudioCapture.cancelRecording()
        if let bundleURL {
            try? FileManager.default.removeItem(at: bundleURL)
        }
        bundleURL = nil
        startedAt = nil
        isScanning = false
        captureContinuation?.resume(throwing: CancellationError())
        captureContinuation = nil
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        Task { @MainActor [weak self] in
            self?.handle(frame: frame)
        }
    }

    private func handle(frame: ARFrame) {
        guard isScanning, let bundleURL else { return }

        if firstFrameTimestamp == nil {
            firstFrameTimestamp = frame.timestamp
        }
        let elapsed = frame.timestamp - (firstFrameTimestamp ?? frame.timestamp)
        guard shouldSample(frame: frame, elapsed: elapsed) else { return }

        let framesFolderURL = bundleURL.appendingPathComponent("frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: framesFolderURL, withIntermediateDirectories: true)

        let frameIndex = frameSamples.count + 1
        let imageFileName = String(format: "frame-%03d.jpg", frameIndex)
        let imageURL = framesFolderURL.appendingPathComponent(imageFileName)

        guard let jpegData = jpegData(from: frame.capturedImage) else { return }
        do {
            try jpegData.write(to: imageURL, options: .atomic)
        } catch {
            return
        }

        if previewImageData == nil {
            previewImageData = jpegData
            let previewURL = bundleURL.appendingPathComponent(previewImageFileName)
            try? jpegData.write(to: previewURL, options: .atomic)
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
        sampledFrameCount = frameSamples.count
        lastCameraTransform = frame.camera.transform
        lastFrameTimestamp = elapsed
    }

    private func shouldSample(frame: ARFrame, elapsed: TimeInterval) -> Bool {
        guard elapsed >= 0 else { return false }
        guard elapsed - lastFrameTimestamp >= 0.35 else { return false }

        guard let lastCameraTransform else {
            return true
        }

        let translation = simd_length(frame.camera.transform.columns.3.xyz - lastCameraTransform.columns.3.xyz)
        let forward = simd_normalize(frame.camera.transform.columns.2.xyz)
        let previousForward = simd_normalize(lastCameraTransform.columns.2.xyz)
        let rotationDelta = acos(max(-1, min(1, simd_dot(forward, previousForward))))
        return translation >= 0.045 || rotationDelta >= 0.09
    }

    private func finishCapture() async {
        guard isScanning, let bundleURL else { return }

        captureTimerTask?.cancel()
        captureTimerTask = nil
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
        defer {
            startedAt = nil
            isScanning = false
            if audioSession.isRunning {
                audioSession.stopRunning()
            }
        }

        guard let bundleURL, let previewImageData else {
            captureContinuation?.resume(throwing: CaptureError.photoCaptureFailed)
            captureContinuation = nil
            return
        }

        switch result {
        case .success(let audioResult):
            let manifest = SpatialScanManifest(
                capturedAt: startedAt ?? .now,
                captureDuration: audioResult.duration,
                frameCount: frameSamples.count,
                fieldOfViewLimited: true,
                anchorHeadingDegrees: nil,
                previewImageFileName: previewImageFileName,
                worldMapFileName: worldMapFileName,
                reconstructionState: .captured,
                frameSamples: frameSamples
            )

            let manifestURL = bundleURL.appendingPathComponent("manifest.json")
            if let data = try? JSONEncoder().encode(manifest) {
                try? data.write(to: manifestURL, options: .atomic)
            }

            captureContinuation?.resume(
                returning: CapturedMemoryDraft(
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
            )
        case .failure(let error):
            try? FileManager.default.removeItem(at: bundleURL)
            captureContinuation?.resume(throwing: error)
        }

        captureContinuation = nil
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
            if !audioSession.inputs.contains(where: { $0 === audioInput }) {
                audioSession.addInput(audioInput)
            }
            _ = try ambientAudioCapture.configure(session: audioSession, audioInput: audioInput)
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func jpegData(from pixelBuffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.82)
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
    let duration: TimeInterval
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
                let draft = try await model.captureScan(duration: duration)
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
                Text("\(model.sampledFrameCount) frames")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
            }

            Spacer()

            Text("\(model.remainingSeconds)秒")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.black.opacity(0.42), in: Capsule())
        }
    }

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("人の視野に近い短時間 sweep で、空間の輪郭と環境音を一緒に束ねます。")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.84))

            ProgressView(value: model.progress)
                .tint(.white)

            Text(model.guidanceText)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.78))

            HStack(spacing: 12) {
                scanHintChip(title: "短時間", value: "\(Int(duration.rounded()))秒")
                scanHintChip(title: "方式", value: "on-device")
                scanHintChip(title: "音声", value: "ambient")
            }
        }
        .padding(18)
        .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.14))
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

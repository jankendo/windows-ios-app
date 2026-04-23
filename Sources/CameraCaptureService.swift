import AVFoundation
import SwiftUI
import UIKit

struct CapturedMemoryDraft: Identifiable {
    let id = UUID()
    let photoData: Data
    let audioTempURL: URL?
    let analysisAudioTempURL: URL?
    let capturedAt: Date
    let audioDuration: TimeInterval
    let isSpatialAudio: Bool
    var recoveryState: PartialCaptureRecoveryState
    var placeLabel: String?
    var photoCaption: String?
    var photoCaptionSource: PhotoCaptionSource?
    var photoCaptionStyle: PhotoCaptionStyle?
    var sensorSnapshot: CaptureEnvironmentSnapshot?
    var minimumDecibels: Double?
    var maximumDecibels: Double?

    var atmosphereStyle: AtmosphereStyle {
        AtmosphereStyle(date: capturedAt)
    }

    var analysisAudioURL: URL? {
        analysisAudioTempURL ?? audioTempURL
    }
}

enum CaptureError: LocalizedError {
    case permissionsDenied
    case configurationFailed
    case sessionNotReady
    case busy
    case invalidDuration
    case photoCaptureFailed
    case audioRecordingFailed
    case captureInterrupted(reason: InterruptionReason)
    case captureInterruptedTooShort(reason: InterruptionReason)

    var errorDescription: String? {
        switch self {
        case .permissionsDenied:
            return "カメラまたはマイクの権限が不足しています。"
        case .configurationFailed:
            return "カメラセッションの初期化に失敗しました。"
        case .sessionNotReady:
            return "カメラの準備が整ってから再度お試しください。"
        case .busy:
            return "前の撮影処理が完了するまでお待ちください。"
        case .invalidDuration:
            return "録音秒数の設定が不正です。"
        case .photoCaptureFailed:
            return "写真の取得に失敗しました。"
        case .audioRecordingFailed:
            return "環境音の録音に失敗しました。"
        case .captureInterrupted(let reason):
            return "\(reason.localizedLabel)により録音が終了しました。部分的な記録を確認してください。"
        case .captureInterruptedTooShort(let reason):
            return "\(reason.localizedLabel)により録音が3秒未満で中断されたため保存できませんでした。"
        }
    }
}

@MainActor
final class CameraCaptureService: NSObject, ObservableObject, @preconcurrency AVCapturePhotoCaptureDelegate {
    enum PermissionState {
        case unknown
        case ready
        case denied
    }

    @Published private(set) var permissionState: PermissionState = .unknown
    @Published private(set) var isSessionRunning = false
    @Published private(set) var isCapturing = false
    @Published private(set) var isProcessingCapture = false
    @Published private(set) var isPreparingSession = true
    @Published private(set) var isWaitingForRecordingStart = false
    @Published private(set) var captureProgress = 0.0
    @Published private(set) var remainingRecordingSeconds = 6
    @Published private(set) var liveMeterSamples: [CGFloat] = Array(repeating: 0.18, count: 24)
    @Published var statusText = "写真と環境音を一緒に保存できます。"

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "resonance.camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private var pendingCapture: PendingCapture?
    private let ambientAudioCapture = AmbientAudioCaptureCoordinator()
    private var isConfigured = false
    private var isConfiguring = false
    private var progressTimer: Timer?
    private var recordingStartWorkItem: DispatchWorkItem?
    private var recordingFinishWorkItem: DispatchWorkItem?
    private var minimumCapturedDecibels: Float?
    private var maximumCapturedDecibels: Float?
    private let audioDiagnostics = AudioPlaybackDiagnostics.shared
    private var notificationTokens: [NSObjectProtocol] = []

    var isReadyToCapture: Bool {
        permissionState == .ready && isSessionRunning && !isCapturing
    }

    override init() {
        super.init()
        registerSystemObservers()
    }

    deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    func prepare() {
        isPreparingSession = true
        ambientAudioCapture.latestAveragePower = -60
        Task {
            let granted = await requestPermissions()
            guard granted else {
                permissionState = .denied
                isPreparingSession = false
                statusText = "権限が必要です。設定からカメラとマイクを許可してください。"
                return
            }

            permissionState = .ready
            configureSessionIfNeeded()
        }
    }

    func suspend() {
        if isCapturing || pendingCapture != nil {
            failPendingCapture(CaptureError.sessionNotReady)
        }
        cancelScheduledCaptureWork()
        progressTimer?.invalidate()
        progressTimer = nil
        ambientAudioCapture.cancelRecording()
        isWaitingForRecordingStart = false

        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async {
                self.isSessionRunning = false
                self.isPreparingSession = false
                if self.permissionState == .ready {
                    self.statusText = "記録タブに戻るとカメラを再開できます。"
                }
            }
        }
    }

    func captureMemory(
        duration: TimeInterval,
        delayRecordingUntilAfterShutter: Bool,
        completion: @escaping (Result<CapturedMemoryDraft, Error>) -> Void
    ) {
        guard duration >= 1 else {
            completion(.failure(CaptureError.invalidDuration))
            return
        }
        guard permissionState == .ready else {
            completion(.failure(CaptureError.permissionsDenied))
            return
        }
        guard isSessionRunning else {
            completion(.failure(CaptureError.sessionNotReady))
            return
        }
        guard !isCapturing else {
            completion(.failure(CaptureError.busy))
            return
        }

        cancelScheduledCaptureWork()

        let pending = PendingCapture(
            audioURL: nil,
            capturedAt: .now,
            requestedDuration: duration,
            delayRecordingUntilAfterShutter: delayRecordingUntilAfterShutter,
            completion: completion
        )
        pendingCapture = pending
        isCapturing = true
        isProcessingCapture = false
        isWaitingForRecordingStart = delayRecordingUntilAfterShutter
        resetLiveMeter()

        if delayRecordingUntilAfterShutter {
            statusText = "写真を撮影しています。シャッターの余韻が収まってから環境音を録音します。"
            captureProgress = 0
            remainingRecordingSeconds = max(Int(ceil(duration)), 1)
        } else {
            do {
                pending.audioURL = try startAmbientCapture()
                statusText = "写真を撮影し、\(Int(duration.rounded()))秒の環境音を録音しています。"
                startCaptureProgress(duration: duration)
                scheduleAudioCaptureFinish(after: duration)
            } catch {
                ambientAudioCapture.cancelRecording()
                pendingCapture = nil
                isCapturing = false
                isWaitingForRecordingStart = false
                completion(.failure(CaptureError.audioRecordingFailed))
                return
            }
        }

        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .quality
        if photoOutput.isHighResolutionCaptureEnabled {
            settings.isHighResolutionPhotoEnabled = true
        }
        if photoOutput.isDepthDataDeliveryEnabled {
            settings.isDepthDataDeliveryEnabled = true
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func configureSessionIfNeeded() {
        guard !isConfigured else {
            if isSessionRunning {
                isPreparingSession = false
                statusText = "カメラの準備ができました。"
            } else {
                sessionQueue.async { [weak self] in
                    guard let self else { return }
                    guard !self.session.isRunning else {
                        DispatchQueue.main.async {
                            self.isSessionRunning = true
                            self.isPreparingSession = false
                            self.statusText = "カメラの準備ができました。"
                        }
                        return
                    }
                    self.session.startRunning()
                    DispatchQueue.main.async {
                        self.isSessionRunning = true
                        self.isPreparingSession = false
                        self.statusText = "カメラの準備ができました。"
                    }
                }
            }
            return
        }
        guard !isConfiguring else { return }

        isConfiguring = true

        let session = session
        let photoOutput = photoOutput
        sessionQueue.async { [weak self, session, photoOutput] in
            guard let self else { return }

            session.beginConfiguration()
            session.sessionPreset = .photo

            guard
                let camera = Self.preferredBackCamera(),
                let input = try? AVCaptureDeviceInput(device: camera),
                session.canAddInput(input)
            else {
                DispatchQueue.main.async {
                    self.isConfiguring = false
                    self.isPreparingSession = false
                    self.statusText = CaptureError.configurationFailed.localizedDescription
                }
                session.commitConfiguration()
                return
            }

            session.addInput(input)

            guard
                let audioDevice = AVCaptureDevice.default(for: .audio),
                let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
                session.canAddInput(audioInput)
            else {
                DispatchQueue.main.async {
                    self.isConfiguring = false
                    self.isPreparingSession = false
                    self.statusText = CaptureError.configurationFailed.localizedDescription
                }
                session.commitConfiguration()
                return
            }

            session.addInput(audioInput)
            do {
                let spatialAvailable = try self.ambientAudioCapture.configure(session: session, audioInput: audioInput)
                DispatchQueue.main.async {
                    self.audioDiagnostics.record("capture capability spatial=\(spatialAvailable)")
                }
            } catch {
                DispatchQueue.main.async {
                    self.isConfiguring = false
                    self.isPreparingSession = false
                    self.statusText = CaptureError.configurationFailed.localizedDescription
                }
                session.commitConfiguration()
                return
            }

            guard session.canAddOutput(photoOutput) else {
                DispatchQueue.main.async {
                    self.isConfiguring = false
                    self.isPreparingSession = false
                    self.statusText = CaptureError.configurationFailed.localizedDescription
                }
                session.commitConfiguration()
                return
            }

            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
            photoOutput.isHighResolutionCaptureEnabled = true
            if photoOutput.isDepthDataDeliverySupported {
                photoOutput.isDepthDataDeliveryEnabled = true
            }

            session.commitConfiguration()
            session.startRunning()

            DispatchQueue.main.async {
                self.isConfiguring = false
                self.isConfigured = true
                self.isSessionRunning = true
                self.isPreparingSession = false
                self.statusText = "カメラの準備ができました。"
            }
        }
    }

    private func requestPermissions() async -> Bool {
        let cameraGranted = await requestPermission(for: .video)
        let microphoneGranted = await requestPermission(for: .audio)
        return cameraGranted && microphoneGranted
    }

    private func requestPermission(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: mediaType) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    private func startAmbientCapture() throws -> URL {
        minimumCapturedDecibels = nil
        maximumCapturedDecibels = nil
        return try ambientAudioCapture.startRecording()
    }

    private func startCaptureProgress(duration: TimeInterval) {
        progressTimer?.invalidate()
        captureProgress = 0
        remainingRecordingSeconds = max(Int(ceil(duration)), 1)

        let startedAt = Date()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    timer.invalidate()
                    return
                }

                let elapsed = min(Date().timeIntervalSince(startedAt), duration)
                self.captureProgress = duration > 0 ? elapsed / duration : 1
                self.remainingRecordingSeconds = max(Int(ceil(duration - elapsed)), 0)
                let averagePower = self.ambientAudioCapture.latestAveragePower
                let normalizedLevel = max(0.08, min(1, CGFloat((averagePower + 60) / 60)))
                self.minimumCapturedDecibels = min(self.minimumCapturedDecibels ?? averagePower, averagePower)
                self.maximumCapturedDecibels = max(self.maximumCapturedDecibels ?? averagePower, averagePower)
                self.liveMeterSamples.append(normalizedLevel)
                if self.liveMeterSamples.count > 24 {
                    self.liveMeterSamples.removeFirst(self.liveMeterSamples.count - 24)
                }

                if elapsed >= duration {
                    timer.invalidate()
                }
            }
        }
    }

    private func resetCaptureProgress() {
        progressTimer?.invalidate()
        progressTimer = nil
        captureProgress = 0
        remainingRecordingSeconds = 6
    }

    private func cancelScheduledCaptureWork() {
        recordingStartWorkItem?.cancel()
        recordingStartWorkItem = nil
        recordingFinishWorkItem?.cancel()
        recordingFinishWorkItem = nil
    }

    private func resetLiveMeter() {
        liveMeterSamples = Array(repeating: 0.18, count: 24)
    }

    private func finishAudioCapture() {
        cancelScheduledCaptureWork()
        isWaitingForRecordingStart = false
        isProcessingCapture = true
        statusText = "記憶のシーンを仕上げています。"
        resetCaptureProgress()
        if let audioURL = pendingCapture?.audioURL {
            audioDiagnostics.record("recorder stop requested: file=\(audioURL.lastPathComponent)")
        }
        ambientAudioCapture.stopRecording { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let recording):
                self.pendingCapture?.audioURL = recording.primaryURL
                self.pendingCapture?.analysisAudioURL = recording.analysisURL
                self.pendingCapture?.recordedDuration = recording.duration
                self.pendingCapture?.isSpatialAudio = recording.isSpatialAudio
                self.pendingCapture?.audioFinished = true
                self.audioDiagnostics.record(
                    recording.isSpatialAudio
                        ? "spatial audio capture confirmed: \(recording.assetProfile.diagnosticSummary)"
                        : "spatial audio capture unavailable: \(recording.assetProfile.diagnosticSummary)"
                )
                self.completePendingCaptureIfPossible()
            case .failure(let error):
                self.failPendingCapture(error)
            }
        }
    }

    private func completePendingCaptureIfPossible() {
        guard let pendingCapture else { return }
        guard pendingCapture.audioFinished, let photoData = pendingCapture.photoData else { return }

        let completion = pendingCapture.completion
        let audioURL = pendingCapture.audioURL
        let analysisAudioURL = pendingCapture.analysisAudioURL
        let capturedAt = pendingCapture.capturedAt
        let audioDuration: TimeInterval

        if let recordedDuration = pendingCapture.recordedDuration {
            audioDuration = recordedDuration
        } else if let audioURL {
            let asset = AVURLAsset(url: audioURL)
            audioDuration = asset.duration.seconds.isFinite ? asset.duration.seconds : 0
        } else {
            audioDuration = 0
            audioDiagnostics.record("capture completed without audio file")
        }

        self.pendingCapture = nil
        isCapturing = false
        isProcessingCapture = false
        statusText = "レビューして保存できます。"
        resetLiveMeter()
        completion(.success(CapturedMemoryDraft(
            photoData: photoData,
            audioTempURL: audioURL,
            analysisAudioTempURL: analysisAudioURL,
            capturedAt: capturedAt,
            audioDuration: audioDuration,
            isSpatialAudio: pendingCapture.isSpatialAudio,
            recoveryState: pendingCapture.recoveryState,
            placeLabel: nil,
            photoCaption: nil,
            photoCaptionSource: nil,
            photoCaptionStyle: nil,
            sensorSnapshot: nil,
            minimumDecibels: minimumCapturedDecibels.map(Double.init),
            maximumDecibels: maximumCapturedDecibels.map(Double.init)
        )))
        minimumCapturedDecibels = nil
        maximumCapturedDecibels = nil
    }

    private func failPendingCapture(_ error: Error) {
        let audioURL = pendingCapture?.audioURL
        let analysisAudioURL = pendingCapture?.analysisAudioURL
        let completion = pendingCapture?.completion
        cancelScheduledCaptureWork()
        pendingCapture = nil
        isCapturing = false
        isProcessingCapture = false
        isWaitingForRecordingStart = false
        ambientAudioCapture.cancelRecording()
        resetCaptureProgress()
        resetLiveMeter()
        if let audioURL {
            try? FileManager.default.removeItem(at: audioURL)
        }
        if let analysisAudioURL, analysisAudioURL != audioURL {
            try? FileManager.default.removeItem(at: analysisAudioURL)
        }
        minimumCapturedDecibels = nil
        maximumCapturedDecibels = nil
        statusText = error.localizedDescription
        audioDiagnostics.record("capture failed: \(error.localizedDescription)")
        completion?(.failure(error))
    }

    private func registerSystemObservers() {
        let center = NotificationCenter.default

        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleAudioInterruption(notification)
            }
        )

        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleAudioRouteChange(notification)
            }
        )

        notificationTokens.append(
            center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleCaptureInterruption(reason: .appBackgrounded)
            }
        )
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else {
            return
        }

        switch type {
        case .began:
            handleCaptureInterruption(reason: .phoneCall)
        case .ended:
            let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            if options.contains(.shouldResume) {
                audioDiagnostics.record("capture interruption ended with shouldResume; partial review is available instead of auto-resume", category: "capture")
            } else {
                audioDiagnostics.record("capture interruption ended without resume option", category: "capture")
            }
        @unknown default:
            handleCaptureInterruption(reason: .unknown)
        }
    }

    private func handleAudioRouteChange(_ notification: Notification) {
        guard isCapturing else { return }

        let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        guard let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else { return }

        if reason == .oldDeviceUnavailable {
            audioDiagnostics.record("audio route changed: previous device unavailable, continuing capture on active route", category: "capture")
            statusText = "音声ルートが切り替わりましたが、録音は継続しています。"
        }
    }

    private func handleCaptureInterruption(reason: InterruptionReason) {
        guard isCapturing, pendingCapture != nil else { return }

        let capturedDuration = ambientAudioCapture.currentRecordingDuration
        audioDiagnostics.record(
            "capture interrupted reason=\(reason.rawValue) duration=\(String(format: "%.2f", capturedDuration))",
            category: "capture"
        )

        if capturedDuration >= ambientAudioCapture.minimumViableDuration {
            pendingCapture?.recoveryState = .recovered(duration: capturedDuration, reason: reason)
            finishAudioCapture()
        } else {
            pendingCapture?.recoveryState = .failed(reason: reason)
            failPendingCapture(CaptureError.captureInterruptedTooShort(reason: reason))
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            failPendingCapture(error)
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            failPendingCapture(CaptureError.photoCaptureFailed)
            return
        }

        pendingCapture?.photoData = data
        if pendingCapture?.delayRecordingUntilAfterShutter == true {
            statusText = "写真を撮影しました。シャッター音が落ち着いてから環境音を始めます。"
            startAudioCaptureAfterQuietDelay()
        } else {
            statusText = "写真を撮影しました。環境音を録音中です。"
        }
        completePendingCaptureIfPossible()
    }

    private func startAudioCaptureAfterQuietDelay() {
        guard let pendingCapture else { return }

        let quietDelay = 0.75
        isWaitingForRecordingStart = true
        cancelScheduledCaptureWork()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let pendingCapture = self.pendingCapture else { return }

            do {
                pendingCapture.audioURL = try self.startAmbientCapture()
                self.isWaitingForRecordingStart = false
                self.statusText = "環境音の録音を始めました。"
                self.startCaptureProgress(duration: pendingCapture.requestedDuration)
                self.scheduleAudioCaptureFinish(after: pendingCapture.requestedDuration)
            } catch {
                self.failPendingCapture(CaptureError.audioRecordingFailed)
            }
        }

        recordingStartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + quietDelay, execute: workItem)
    }

    private func scheduleAudioCaptureFinish(after duration: TimeInterval) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.finishAudioCapture()
        }
        recordingFinishWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }
}

private extension CameraCaptureService {
    static func preferredBackCamera() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }
}

private final class PendingCapture {
    var audioURL: URL?
    var analysisAudioURL: URL?
    let capturedAt: Date
    let requestedDuration: TimeInterval
    let delayRecordingUntilAfterShutter: Bool
    let completion: (Result<CapturedMemoryDraft, Error>) -> Void

    var photoData: Data?
    var audioFinished = false
    var recordedDuration: TimeInterval?
    var isSpatialAudio = false
    var recoveryState: PartialCaptureRecoveryState = .none

    init(
        audioURL: URL?,
        capturedAt: Date,
        requestedDuration: TimeInterval,
        delayRecordingUntilAfterShutter: Bool,
        completion: @escaping (Result<CapturedMemoryDraft, Error>) -> Void
    ) {
        self.audioURL = audioURL
        self.capturedAt = capturedAt
        self.requestedDuration = requestedDuration
        self.delayRecordingUntilAfterShutter = delayRecordingUntilAfterShutter
        self.completion = completion
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

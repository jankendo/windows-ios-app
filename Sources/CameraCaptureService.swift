import AVFoundation
import SwiftUI
import UIKit

struct CapturedMemoryDraft: Identifiable {
    let id = UUID()
    let photoData: Data
    let audioTempURL: URL?
    let capturedAt: Date
    let audioDuration: TimeInterval
    var placeLabel: String?
    var sensorSnapshot: CaptureEnvironmentSnapshot?
    var weatherSnapshot: MemoryWeatherSnapshot?

    var atmosphereStyle: AtmosphereStyle {
        AtmosphereStyle(date: capturedAt)
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
    @Published private(set) var captureProgress = 0.0
    @Published private(set) var remainingRecordingSeconds = 6
    @Published private(set) var liveMeterSamples: [CGFloat] = Array(repeating: 0.18, count: 24)
    @Published var statusText = "写真と環境音を一緒に保存できます。"

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "resonance.camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private var pendingCapture: PendingCapture?
    private var audioRecorder: AVAudioRecorder?
    private var isConfigured = false
    private var isConfiguring = false
    private var progressTimer: Timer?

    var isReadyToCapture: Bool {
        permissionState == .ready && isSessionRunning && !isCapturing
    }

    func prepare() {
        isPreparingSession = true
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

    func captureMemory(duration: TimeInterval, completion: @escaping (Result<CapturedMemoryDraft, Error>) -> Void) {
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

        do {
            try startAudioRecorder()
        } catch {
            completion(.failure(CaptureError.audioRecordingFailed))
            return
        }

        let pending = PendingCapture(audioURL: audioRecorder?.url, capturedAt: .now, completion: completion)
        pendingCapture = pending
        isCapturing = true
        isProcessingCapture = false
        resetLiveMeter()
        statusText = "写真を撮影し、\(Int(duration.rounded()))秒の環境音を録音しています。"
        startCaptureProgress(duration: duration)

        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .quality
        if photoOutput.isHighResolutionCaptureEnabled {
            settings.isHighResolutionPhotoEnabled = true
        }
        photoOutput.capturePhoto(with: settings, delegate: self)

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.finishAudioCapture()
        }
    }

    private func configureSessionIfNeeded() {
        guard !isConfigured else {
            if !isSessionRunning {
                sessionQueue.async { [weak self] in
                    guard let self else { return }
                    guard !self.session.isRunning else { return }
                    self.session.startRunning()
                    DispatchQueue.main.async {
                        self.isSessionRunning = true
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
                let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
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

    private func startAudioRecorder() throws {
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
        audioRecorder?.isMeteringEnabled = true
        audioRecorder?.record()
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
                self.audioRecorder?.updateMeters()
                let averagePower = self.audioRecorder?.averagePower(forChannel: 0) ?? -60
                let normalizedLevel = max(0.08, min(1, CGFloat((averagePower + 60) / 60)))
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

    private func resetLiveMeter() {
        liveMeterSamples = Array(repeating: 0.18, count: 24)
    }

    private func finishAudioCapture() {
        pendingCapture?.audioFinished = true
        audioRecorder?.stop()
        audioRecorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isProcessingCapture = true
        statusText = "記憶のシーンを整えています。"
        resetCaptureProgress()
        completePendingCaptureIfPossible()
    }

    private func completePendingCaptureIfPossible() {
        guard let pendingCapture else { return }
        guard pendingCapture.audioFinished, let photoData = pendingCapture.photoData else { return }

        let completion = pendingCapture.completion
        let audioURL = pendingCapture.audioURL
        let capturedAt = pendingCapture.capturedAt
        let audioDuration: TimeInterval

        if let audioURL {
            let asset = AVURLAsset(url: audioURL)
            audioDuration = asset.duration.seconds.isFinite ? asset.duration.seconds : 0
        } else {
            audioDuration = 0
        }

        self.pendingCapture = nil
        isCapturing = false
        isProcessingCapture = false
        statusText = "レビューして保存できます。"
        resetLiveMeter()
        completion(.success(CapturedMemoryDraft(photoData: photoData, audioTempURL: audioURL, capturedAt: capturedAt, audioDuration: audioDuration, placeLabel: nil)))
    }

    private func failPendingCapture(_ error: Error) {
        let audioURL = pendingCapture?.audioURL
        let completion = pendingCapture?.completion
        pendingCapture = nil
        isCapturing = false
        isProcessingCapture = false
        audioRecorder?.stop()
        audioRecorder = nil
        resetCaptureProgress()
        resetLiveMeter()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if let audioURL {
            try? FileManager.default.removeItem(at: audioURL)
        }
        statusText = error.localizedDescription
        completion?(.failure(error))
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
        statusText = "写真を撮影しました。環境音を録音中です。"
        completePendingCaptureIfPossible()
    }
}

private final class PendingCapture {
    let audioURL: URL?
    let capturedAt: Date
    let completion: (Result<CapturedMemoryDraft, Error>) -> Void

    var photoData: Data?
    var audioFinished = false

    init(audioURL: URL?, capturedAt: Date, completion: @escaping (Result<CapturedMemoryDraft, Error>) -> Void) {
        self.audioURL = audioURL
        self.capturedAt = capturedAt
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

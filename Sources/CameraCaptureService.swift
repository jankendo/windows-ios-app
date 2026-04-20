import AVFoundation
import SwiftUI
import UIKit

struct CapturedMemoryDraft {
    let photoData: Data
    let audioTempURL: URL?
    let capturedAt: Date
}

enum CaptureError: LocalizedError {
    case permissionsDenied
    case configurationFailed
    case busy
    case photoCaptureFailed
    case audioRecordingFailed

    var errorDescription: String? {
        switch self {
        case .permissionsDenied:
            return "カメラまたはマイクの権限が不足しています。"
        case .configurationFailed:
            return "カメラセッションの初期化に失敗しました。"
        case .busy:
            return "前の撮影処理が完了するまでお待ちください。"
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
    @Published var statusText = "写真と6秒の環境音を一緒に保存できます。"

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "resonance.camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private var pendingCapture: PendingCapture?
    private var audioRecorder: AVAudioRecorder?

    func prepare() {
        Task {
            let granted = await requestPermissions()
            guard granted else {
                permissionState = .denied
                statusText = "権限が必要です。設定からカメラとマイクを許可してください。"
                return
            }

            permissionState = .ready
            configureSessionIfNeeded()
        }
    }

    func captureMemory(completion: @escaping (Result<CapturedMemoryDraft, Error>) -> Void) {
        guard permissionState == .ready else {
            completion(.failure(CaptureError.permissionsDenied))
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
        statusText = "撮影中… 周囲の空気感を記録しています。"

        let settings = AVCapturePhotoSettings()
        settings.isHighResolutionPhotoEnabled = true
        photoOutput.capturePhoto(with: settings, delegate: self)

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.finishAudioCapture()
        }
    }

    private func configureSessionIfNeeded() {
        guard !isSessionRunning else { return }

        sessionQueue.async { [weak self] in
            guard let self else { return }

            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            guard
                let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                let input = try? AVCaptureDeviceInput(device: camera),
                self.session.canAddInput(input)
            else {
                DispatchQueue.main.async {
                    self.statusText = CaptureError.configurationFailed.localizedDescription
                }
                self.session.commitConfiguration()
                return
            }

            self.session.addInput(input)

            guard self.session.canAddOutput(self.photoOutput) else {
                DispatchQueue.main.async {
                    self.statusText = CaptureError.configurationFailed.localizedDescription
                }
                self.session.commitConfiguration()
                return
            }

            self.session.addOutput(self.photoOutput)
            self.photoOutput.maxPhotoQualityPrioritization = .quality
            self.session.commitConfiguration()
            self.session.startRunning()

            DispatchQueue.main.async {
                self.isSessionRunning = true
                self.statusText = "カメラ準備完了。写真と環境音を残せます。"
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
        audioRecorder?.record()
    }

    private func finishAudioCapture() {
        pendingCapture?.audioFinished = true
        audioRecorder?.stop()
        audioRecorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        completePendingCaptureIfPossible()
    }

    private func completePendingCaptureIfPossible() {
        guard let pendingCapture else { return }
        guard pendingCapture.audioFinished, let photoData = pendingCapture.photoData else { return }

        let completion = pendingCapture.completion
        let audioURL = pendingCapture.audioURL
        let capturedAt = pendingCapture.capturedAt

        self.pendingCapture = nil
        isCapturing = false
        statusText = "メモリーの保存準備ができました。"
        completion(.success(CapturedMemoryDraft(photoData: photoData, audioTempURL: audioURL, capturedAt: capturedAt)))
    }

    private func failPendingCapture(_ error: Error) {
        let audioURL = pendingCapture?.audioURL
        let completion = pendingCapture?.completion
        pendingCapture = nil
        isCapturing = false
        audioRecorder?.stop()
        audioRecorder = nil
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

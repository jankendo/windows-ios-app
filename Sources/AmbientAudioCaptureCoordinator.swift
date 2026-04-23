import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

struct AmbientAudioCaptureResult {
    let primaryURL: URL
    let analysisURL: URL?
    let duration: TimeInterval
    let isSpatialAudio: Bool
    let assetProfile: AudioAssetProfile
}

enum AmbientAudioCaptureError: LocalizedError {
    case configurationFailed
    case recorderUnavailable
    case writerFailed(String)
    case missingStereoFallback

    var errorDescription: String? {
        switch self {
        case .configurationFailed:
            return "空間オーディオ録音の準備に失敗しました。"
        case .recorderUnavailable:
            return "環境音の録音を開始できませんでした。"
        case .writerFailed(let detail):
            return "環境音の書き出しに失敗しました: \(detail)"
        case .missingStereoFallback:
            return "空間オーディオの補助トラックを取り出せませんでした。"
        }
    }
}

final class AmbientAudioCaptureCoordinator: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let captureQueue = DispatchQueue(label: "resonance.audio.capture")

    private var standardOutput: AVCaptureAudioDataOutput?
    private var spatialOutput: AVCaptureAudioDataOutput?
    private var stereoFallbackOutput: AVCaptureAudioDataOutput?
    private var spatialMetadataGenerator: AVCaptureSpatialAudioMetadataSampleGenerator?

    private var assetWriter: AVAssetWriter?
    private var standardWriterInput: AVAssetWriterInput?
    private var spatialWriterInput: AVAssetWriterInput?
    private var stereoWriterInput: AVAssetWriterInput?
    private var metadataWriterInput: AVAssetWriterInput?

    private var currentFileURL: URL?
    private var isRecording = false
    private var hasStartedWriting = false

    var latestAveragePower: Float = -60
    private(set) var supportsSpatialCapture = false

    func configure(session: AVCaptureSession, audioInput: AVCaptureDeviceInput) throws -> Bool {
        if standardOutput != nil || spatialOutput != nil || stereoFallbackOutput != nil {
            return supportsSpatialCapture
        }

        if #available(iOS 26.0, *), audioInput.isMultichannelAudioModeSupported(.firstOrderAmbisonics) {
            audioInput.multichannelAudioMode = .firstOrderAmbisonics

            let spatialOutput = AVCaptureAudioDataOutput()
            spatialOutput.spatialAudioChannelLayoutTag = AudioAssetProfile.foaLayoutTag
            let stereoOutput = AVCaptureAudioDataOutput()
            stereoOutput.spatialAudioChannelLayoutTag = kAudioChannelLayoutTag_Stereo

            guard session.canAddOutput(spatialOutput), session.canAddOutput(stereoOutput) else {
                throw AmbientAudioCaptureError.configurationFailed
            }

            session.addOutput(spatialOutput)
            session.addOutput(stereoOutput)
            spatialOutput.setSampleBufferDelegate(self, queue: captureQueue)
            stereoOutput.setSampleBufferDelegate(self, queue: captureQueue)

            self.spatialOutput = spatialOutput
            self.stereoFallbackOutput = stereoOutput
            self.spatialMetadataGenerator = AVCaptureSpatialAudioMetadataSampleGenerator()
            self.supportsSpatialCapture = true
            log("capture path configured: true spatial capture available (FOA + stereo fallback)")
            return true
        }

        let standardOutput = AVCaptureAudioDataOutput()
        guard session.canAddOutput(standardOutput) else {
            throw AmbientAudioCaptureError.configurationFailed
        }

        session.addOutput(standardOutput)
        standardOutput.setSampleBufferDelegate(self, queue: captureQueue)
        self.standardOutput = standardOutput
        self.supportsSpatialCapture = false
        log("capture path configured: standard ambient capture")
        return false
    }

    func startRecording() throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(supportsSpatialCapture ? "mov" : "m4a")

        try captureQueue.sync {
            guard assetWriter == nil else {
                throw AmbientAudioCaptureError.recorderUnavailable
            }

            try prepareWriter(for: fileURL)
            currentFileURL = fileURL
            latestAveragePower = -60
            hasStartedWriting = false
            isRecording = true
        }

        log("recorder started: file=\(fileURL.lastPathComponent) route=\(Self.routeDescription()) mode=\(supportsSpatialCapture ? "spatial-foa" : "standard")")
        log(
            supportsSpatialCapture
                ? "spatial audio capture check: true (FOA 4ch + stereo fallback + metadata)"
                : "spatial audio capture check: false (device does not expose FOA capture, using standard recording)"
        )
        return fileURL
    }

    func stopRecording(completion: @escaping (Result<AmbientAudioCaptureResult, Error>) -> Void) {
        captureQueue.async {
            guard let fileURL = self.currentFileURL, let writer = self.assetWriter else {
                DispatchQueue.main.async {
                    completion(.failure(AmbientAudioCaptureError.recorderUnavailable))
                }
                return
            }

            self.isRecording = false

            if self.supportsSpatialCapture {
                self.appendSpatialMetadataSampleIfPossible()
            }

            self.standardWriterInput?.markAsFinished()
            self.spatialWriterInput?.markAsFinished()
            self.stereoWriterInput?.markAsFinished()
            self.metadataWriterInput?.markAsFinished()

            if !self.hasStartedWriting {
                writer.cancelWriting()
                self.resetWriterState()
                try? FileManager.default.removeItem(at: fileURL)
                DispatchQueue.main.async {
                    completion(.failure(AmbientAudioCaptureError.recorderUnavailable))
                }
                return
            }

            writer.finishWriting {
                let status = writer.status
                let error = writer.error
                self.resetWriterState()

                guard status == .completed else {
                    try? FileManager.default.removeItem(at: fileURL)
                    DispatchQueue.main.async {
                        completion(.failure(AmbientAudioCaptureError.writerFailed(error?.localizedDescription ?? "unknown")) )
                    }
                    return
                }

                Task {
                    let assetProfile = AudioAssetProfile.inspect(url: fileURL)
                    let duration = try await AVURLAsset(url: fileURL).load(.duration).seconds
                    let resolvedDuration = duration.isFinite ? duration : 0
                    let analysisURL: URL?

                    if self.supportsSpatialCapture {
                        analysisURL = try? await Self.exportStereoFallback(from: fileURL)
                    } else {
                        analysisURL = nil
                    }

                    self.log("capture completed: file=\(fileURL.lastPathComponent) duration=\(String(format: "%.2fs", resolvedDuration)) \(assetProfile.diagnosticSummary)")
                    DispatchQueue.main.async {
                        completion(.success(AmbientAudioCaptureResult(
                            primaryURL: fileURL,
                            analysisURL: analysisURL,
                            duration: resolvedDuration,
                            isSpatialAudio: assetProfile.isTrueSpatialAudio,
                            assetProfile: assetProfile
                        )))
                    }
                }
            }
        }
    }

    func cancelRecording() {
        captureQueue.sync {
            isRecording = false
            assetWriter?.cancelWriting()
            if let currentFileURL {
                try? FileManager.default.removeItem(at: currentFileURL)
            }
            resetWriterState()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording, let writer = assetWriter else { return }

        if !hasStartedWriting {
            writer.startWriting()
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            hasStartedWriting = true
        }

        guard writer.status == .writing else { return }

        updateAveragePower(using: sampleBuffer, from: output)

        if output === spatialOutput {
            spatialMetadataGenerator?.analyzeAudioSample(sampleBuffer)
            if spatialWriterInput?.isReadyForMoreMediaData == true, let copied = makeSampleBufferCopy(sampleBuffer) {
                spatialWriterInput?.append(copied)
            }
            return
        }

        if output === stereoFallbackOutput {
            if stereoWriterInput?.isReadyForMoreMediaData == true {
                stereoWriterInput?.append(sampleBuffer)
            }
            return
        }

        if output === standardOutput, standardWriterInput?.isReadyForMoreMediaData == true {
            standardWriterInput?.append(sampleBuffer)
        }
    }

    func captureOutput(_ captureOutput: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        log("dropped sample buffer")
    }
}

private extension AmbientAudioCaptureCoordinator {
    func prepareWriter(for fileURL: URL) throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }

        let fileType: AVFileType = supportsSpatialCapture ? .mov : .m4a
        let writer = try AVAssetWriter(url: fileURL, fileType: fileType)

        if supportsSpatialCapture {
            guard
                let spatialOutput,
                let stereoFallbackOutput,
                let metadataFormat = spatialMetadataGenerator?.timedMetadataSampleBufferFormatDescription
            else {
                throw AmbientAudioCaptureError.configurationFailed
            }

            let spatialSettings = spatialOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov)
            let stereoSettings = stereoFallbackOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov)

            let spatialInput = AVAssetWriterInput(mediaType: .audio, outputSettings: spatialSettings)
            spatialInput.expectsMediaDataInRealTime = true
            let stereoInput = AVAssetWriterInput(mediaType: .audio, outputSettings: stereoSettings)
            stereoInput.expectsMediaDataInRealTime = true
            let metadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: metadataFormat)
            metadataInput.expectsMediaDataInRealTime = true

            guard writer.canAdd(spatialInput), writer.canAdd(stereoInput), writer.canAdd(metadataInput) else {
                throw AmbientAudioCaptureError.configurationFailed
            }

            writer.add(spatialInput)
            writer.add(stereoInput)
            writer.add(metadataInput)

            if metadataInput.canAddTrackAssociation(withTrackOf: spatialInput, type: AVAssetTrack.AssociationType.metadataReferent.rawValue) {
                metadataInput.addTrackAssociation(withTrackOf: spatialInput, type: AVAssetTrack.AssociationType.metadataReferent.rawValue)
            }
            if stereoInput.canAddTrackAssociation(withTrackOf: spatialInput, type: AVAssetTrack.AssociationType.audioFallback.rawValue) {
                stereoInput.addTrackAssociation(withTrackOf: spatialInput, type: AVAssetTrack.AssociationType.audioFallback.rawValue)
            }

            spatialInput.languageCode = "und"
            spatialInput.extendedLanguageTag = "und"
            stereoInput.languageCode = "und"
            stereoInput.extendedLanguageTag = "und"
            stereoInput.marksOutputTrackAsEnabled = false

            self.spatialWriterInput = spatialInput
            self.stereoWriterInput = stereoInput
            self.metadataWriterInput = metadataInput
        } else {
            guard let standardOutput else {
                throw AmbientAudioCaptureError.configurationFailed
            }

            let recommendedSettings = standardOutput.recommendedAudioSettingsForAssetWriter(writingTo: .m4a) ?? [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 192_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let standardInput = AVAssetWriterInput(mediaType: .audio, outputSettings: recommendedSettings)
            standardInput.expectsMediaDataInRealTime = true

            guard writer.canAdd(standardInput) else {
                throw AmbientAudioCaptureError.configurationFailed
            }

            writer.add(standardInput)
            self.standardWriterInput = standardInput
        }

        self.assetWriter = writer
    }

    func appendSpatialMetadataSampleIfPossible() {
        guard
            supportsSpatialCapture,
            let metadataSample = spatialMetadataGenerator?.newTimedMetadataSampleBufferAndResetAnalyzer(),
            let metadataWriterInput,
            metadataWriterInput.isReadyForMoreMediaData
        else {
            return
        }

        metadataWriterInput.append(metadataSample.takeRetainedValue())
    }

    func resetWriterState() {
        assetWriter = nil
        standardWriterInput = nil
        spatialWriterInput = nil
        stereoWriterInput = nil
        metadataWriterInput = nil
        currentFileURL = nil
        hasStartedWriting = false
    }

    func updateAveragePower(using sampleBuffer: CMSampleBuffer, from output: AVCaptureOutput) {
        if supportsSpatialCapture && output !== stereoFallbackOutput {
            return
        }

        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
            let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        else {
            return
        }

        let asbd = streamDescription.pointee
        let dataLength = CMBlockBufferGetDataLength(blockBuffer)
        guard dataLength > 0 else { return }

        var data = Data(count: dataLength)
        let status = data.withUnsafeMutableBytes { destination in
            guard let baseAddress = destination.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: dataLength, destination: baseAddress)
        }
        guard status == noErr else { return }

        let amplitude = rmsAmplitude(from: data, asbd: asbd)
        let decibels = Float(max(-60, min(0, 20 * log10(max(amplitude, 0.000_01)))))
        latestAveragePower = decibels
    }

    func rmsAmplitude(from data: Data, asbd: AudioStreamBasicDescription) -> Double {
        if (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0, asbd.mBitsPerChannel == 32 {
            return data.withUnsafeBytes { buffer in
                let values = buffer.bindMemory(to: Float.self)
                guard !values.isEmpty else { return 0.000_01 }
                let squareSum = values.reduce(0.0) { partial, value in
                    let sample = Double(value)
                    return partial + (sample * sample)
                }
                return sqrt(squareSum / Double(values.count))
            }
        }

        if asbd.mBitsPerChannel == 16 {
            return data.withUnsafeBytes { buffer in
                let values = buffer.bindMemory(to: Int16.self)
                guard !values.isEmpty else { return 0.000_01 }
                let squareSum = values.reduce(0.0) { partial, value in
                    let sample = Double(value) / Double(Int16.max)
                    return partial + (sample * sample)
                }
                return sqrt(squareSum / Double(values.count))
            }
        }

        if asbd.mBitsPerChannel == 32 {
            return data.withUnsafeBytes { buffer in
                let values = buffer.bindMemory(to: Int32.self)
                guard !values.isEmpty else { return 0.000_01 }
                let squareSum = values.reduce(0.0) { partial, value in
                    let sample = Double(value) / Double(Int32.max)
                    return partial + (sample * sample)
                }
                return sqrt(squareSum / Double(values.count))
            }
        }

        return 0.000_01
    }

    func makeSampleBufferCopy(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        var copiedBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer, sampleBufferOut: &copiedBuffer)
        guard status == noErr else { return nil }
        return copiedBuffer
    }

    func log(_ message: String) {
        Task { @MainActor in
            AudioPlaybackDiagnostics.shared.record(message)
        }
    }

    static func routeDescription() -> String {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }
        return outputs.isEmpty ? "none" : outputs.joined(separator: ", ")
    }

    static func exportStereoFallback(from spatialURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: spatialURL)
        guard let stereoTrack = AudioAssetProfile.firstStereoTrack(in: asset) else {
            throw AmbientAudioCaptureError.missingStereoFallback
        }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AmbientAudioCaptureError.missingStereoFallback
        }

        let duration = try await asset.load(.duration)
        try compositionTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: stereoTrack, at: .zero)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw AmbientAudioCaptureError.missingStereoFallback
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.shouldOptimizeForNetworkUse = false

        try await withCheckedThrowingContinuation { continuation in
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    continuation.resume(throwing: AmbientAudioCaptureError.writerFailed(exportSession.error?.localizedDescription ?? "stereo fallback export failed"))
                default:
                    continuation.resume(throwing: AmbientAudioCaptureError.writerFailed("stereo fallback export incomplete"))
                }
            }
        }

        return outputURL
    }
}

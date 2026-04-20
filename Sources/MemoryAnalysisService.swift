import AVFoundation
import Speech
import UIKit
import Vision

enum MemoryAnalysisService {
    static func requestSpeechAuthorizationIfNeeded() async {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }

        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { _ in
                continuation.resume()
            }
        }
    }

    static func analyze(photoData: Data, audioURL: URL?) async -> MemoryAnalysis {
        async let visualTags = imageTags(from: photoData)
        async let transcript = transcript(from: audioURL)

        let resolvedVisualTags = await visualTags
        let resolvedTranscript = await transcript
        let resolvedAudioTags = await audioTags(from: audioURL, transcript: resolvedTranscript)
        let mood = inferMood(visualTags: resolvedVisualTags, audioTags: resolvedAudioTags, transcript: resolvedTranscript)

        return MemoryAnalysis(
            visualTags: resolvedVisualTags,
            audioTags: resolvedAudioTags,
            transcript: resolvedTranscript,
            mood: mood.rawValue
        )
    }

    private static func imageTags(from data: Data) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            guard
                let image = UIImage(data: data),
                let cgImage = image.cgImage
            else {
                return [String]()
            }

            let request = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage)

            do {
                try handler.perform([request])
                let labels = request.results?
                    .filter { $0.confidence > 0.15 }
                    .prefix(5)
                    .map { $0.identifier.replacingOccurrences(of: "_", with: " ") } ?? []
                return Array(Set(labels))
            } catch {
                return []
            }
        }.value
    }

    private static func audioTags(from audioURL: URL?, transcript: String) async -> [String] {
        guard let audioURL else { return [] }

        return await Task.detached(priority: .userInitiated) {
            var tags = Set<String>()

            if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                tags.formUnion(["speech", "voice"])
            }

            guard
                let file = try? AVAudioFile(forReading: audioURL),
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: AVAudioFrameCount(file.length)
                )
            else {
                return Array(tags).sorted()
            }

            do {
                try file.read(into: buffer)
            } catch {
                return Array(tags).sorted()
            }

            guard
                let channelData = buffer.floatChannelData?.pointee,
                buffer.frameLength > 0
            else {
                return Array(tags).sorted()
            }

            let sampleCount = Int(buffer.frameLength)
            var sum: Float = 0
            for index in 0..<sampleCount {
                sum += abs(channelData[index])
            }

            let averageAmplitude = sum / Float(sampleCount)
            if averageAmplitude < 0.015 {
                tags.insert("quiet")
            } else if averageAmplitude < 0.05 {
                tags.insert("ambient")
            } else {
                tags.formUnion(["lively", "active"])
            }

            if Double(sampleCount) / file.processingFormat.sampleRate >= 4.5 {
                tags.insert("field recording")
            }

            return Array(tags).sorted()
        }.value
    }

    private static func transcript(from audioURL: URL?) async -> String {
        guard
            let audioURL,
            SFSpeechRecognizer.authorizationStatus() == .authorized
        else {
            return ""
        }

        let locale = Locale.current.identifier
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) ?? SFSpeechRecognizer() else {
            return ""
        }

        return await withCheckedContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: audioURL)
            request.shouldReportPartialResults = false

            var task: SFSpeechRecognitionTask?
            task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    task?.cancel()
                    continuation.resume(returning: result.bestTranscription.formattedString)
                } else if error != nil {
                    task?.cancel()
                    continuation.resume(returning: "")
                }
            }
        }
    }

    private static func inferMood(visualTags: [String], audioTags: [String], transcript: String) -> MemoryMood {
        let corpus = (visualTags + audioTags + [transcript.lowercased()]).joined(separator: " ").lowercased()

        if corpus.contains("laughter") || corpus.contains("laugh") || corpus.contains("cheer") || corpus.contains("smile") {
            return .joyful
        }
        if corpus.contains("ocean") || corpus.contains("sea") || corpus.contains("sunset") || corpus.contains("rain") || corpus.contains("water") {
            return .calm
        }
        if corpus.contains("music") || corpus.contains("speech") || corpus.contains("crowd") || corpus.contains("party") {
            return .lively
        }
        if corpus.contains("street") || corpus.contains("car") || corpus.contains("traffic") || corpus.contains("city") {
            return .urban
        }
        return .reflective
    }
}

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

    static func imageCaption(from data: Data) async -> String? {
        let tags = await imageTags(from: data)
        return generatedCaption(from: tags)
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

    private static func normalizedCaption(_ caption: String?) -> String? {
        guard let caption else { return nil }
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func generatedCaption(from tags: [String]) -> String? {
        let normalizedTags = tags.map { $0.lowercased() }
        guard !normalizedTags.isEmpty else { return nil }

        if containsAny(["sunset", "sunrise", "evening", "dusk"], in: normalizedTags) {
            return "空の色がゆっくり移ろっていく瞬間。"
        }
        if containsAny(["beach", "coast", "ocean", "sea", "shore", "water"], in: normalizedTags) {
            return "水辺のひらけた空気が静かに広がる風景。"
        }
        if containsAny(["mountain", "ridge", "valley", "hill"], in: normalizedTags) {
            return "地形の奥行きが気配ごと残る眺め。"
        }
        if containsAny(["tree", "forest", "woodland", "park", "garden"], in: normalizedTags) {
            return "緑の重なりとやわらかな空気が感じられる場面。"
        }
        if containsAny(["coffee", "espresso", "cup", "cafe"], in: normalizedTags) {
            return "手元の温度まで思い出せそうな静かな一杯。"
        }
        if containsAny(["street", "city", "building", "tower", "car", "road"], in: normalizedTags) {
            return "街の輪郭と流れがそのまま残る都市のワンシーン。"
        }
        if containsAny(["dog", "cat", "bird", "animal"], in: normalizedTags) {
            return "小さな動きまで目に浮かぶ生きものの気配。"
        }
        if containsAny(["person", "portrait", "face", "child", "people"], in: normalizedTags) {
            return "その場の表情と距離感まで思い出せる一枚。"
        }
        if containsAny(["flower", "plant", "leaf"], in: normalizedTags) {
            return "色と質感がやさしく残る、静かな近景。"
        }
        if let primarySubject = localizedPrimarySubject(from: normalizedTags) {
            return "\(primarySubject)が印象に残るシーン。"
        }

        return nil
    }

    private static func containsAny(_ candidates: [String], in tags: [String]) -> Bool {
        candidates.contains { candidate in
            tags.contains { $0.contains(candidate) }
        }
    }

    private static func localizedPrimarySubject(from tags: [String]) -> String? {
        let mappings: [(String, String)] = [
            ("sky", "空"),
            ("cloud", "雲"),
            ("sun", "光"),
            ("water", "水辺"),
            ("beach", "海辺"),
            ("ocean", "海"),
            ("sea", "海"),
            ("mountain", "山並み"),
            ("tree", "樹木"),
            ("forest", "森"),
            ("park", "公園"),
            ("garden", "庭"),
            ("street", "通り"),
            ("city", "街"),
            ("building", "建物"),
            ("coffee", "コーヒー"),
            ("cup", "カップ"),
            ("food", "食べもの"),
            ("person", "人物"),
            ("portrait", "表情"),
            ("child", "子ども"),
            ("dog", "犬"),
            ("cat", "猫"),
            ("bird", "鳥"),
            ("flower", "花"),
            ("plant", "植物")
        ]

        for tag in tags {
            if let subject = mappings.first(where: { tag.contains($0.0) })?.1 {
                return subject
            }
        }

        return nil
    }
}

import AVFoundation
import Speech
import UIKit
import Vision
#if canImport(FoundationModels)
import FoundationModels
#endif

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

    static func imageCaption(from data: Data, title: String? = nil, placeLabel: String? = nil) async -> String? {
        let tags = await imageTags(from: data)
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let baseCaption = generatedCaption(from: tags) ?? "光と空気のあわいが、まだこの写真の中で静かに呼吸している。"

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *),
           !trimmedTitle.isEmpty,
           let aiCaption = await foundationModelCaption(
                title: trimmedTitle,
                placeLabel: placeLabel,
                tags: tags,
                baseCaption: baseCaption
           ) {
            return aiCaption
        }
        #endif

        return refinedFallbackCaption(
            title: trimmedTitle,
            placeLabel: placeLabel,
            tags: tags,
            baseCaption: baseCaption
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

    private static func generatedCaption(from tags: [String]) -> String? {
        let normalizedTags = tags.map { $0.lowercased() }
        guard !normalizedTags.isEmpty else {
            return "光と空気のあわいが、まだこの写真の中で静かに呼吸している。"
        }

        let scene = poeticScene(from: normalizedTags)
        let afterglow = poeticAfterglow(from: normalizedTags)
        return "\(scene)。\(afterglow)。"
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

    private static func poeticScene(from tags: [String]) -> String {
        let scenes: [([String], String)] = [
            (["sunset", "sunrise", "evening", "dusk"], "空の色がほどけながら、光の余韻がゆっくりひろがっている"),
            (["night", "moon", "star"], "夜の静けさが深まり、わずかな光だけが輪郭を残している"),
            (["beach", "coast", "ocean", "sea", "shore", "water"], "水辺のひかりが揺れて、湿度を含んだ空気まで写り込んでいる"),
            (["mountain", "ridge", "valley", "hill"], "地形の重なりが遠くまで続き、空気の奥行きまで感じられる"),
            (["tree", "forest", "woodland", "park", "garden"], "緑の層を抜けるやわらかな空気が、静かな深さをつくっている"),
            (["coffee", "espresso", "cup", "cafe", "food"], "手元の小さな温度が、その場の時間までやさしく包んでいる"),
            (["street", "city", "building", "tower", "car", "road"], "街の輪郭のあいだを、光と気配の流れがゆっくり通り過ぎていく"),
            (["dog", "cat", "bird", "animal"], "生きものの気配がふっと走り、その場の空気にやわらかな動きを残している"),
            (["person", "portrait", "face", "child", "people"], "人の表情と距離感が、そのまま空気の温度として立ち上がっている"),
            (["flower", "plant", "leaf"], "色と質感の繊細な重なりが、静かな呼吸のようにひらいている")
        ]

        if let scene = scenes.first(where: { containsAny($0.0, in: tags) })?.1 {
            return scene
        }
        if let primarySubject = localizedPrimarySubject(from: tags) {
            return "\(primarySubject)の輪郭に、その場の空気が静かににじんでいる"
        }
        return "目の前の景色に触れた空気が、やわらかな層になって残っている"
    }

    private static func poeticAfterglow(from tags: [String]) -> String {
        let afterglows: [([String], String)] = [
            (["sunset", "sunrise", "sky", "cloud", "sun"], "見上げたときの明るさまで思い出せる"),
            (["beach", "coast", "ocean", "sea", "shore", "water"], "波の気配が耳の奥でまだ続いている"),
            (["street", "city", "building", "tower", "car", "road"], "足音や遠いざわめきが、写真の外側にまで残っていく"),
            (["tree", "forest", "woodland", "park", "garden", "flower", "plant", "leaf"], "風の通り道まで静かに想像できる"),
            (["coffee", "espresso", "cup", "cafe", "food"], "その場にあった温度と間合いまでやさしく戻ってくる"),
            (["person", "portrait", "face", "child", "people"], "言葉になる前の気持ちまでそっと浮かび上がる"),
            (["dog", "cat", "bird", "animal"], "小さな動きが今もすぐそばにいるように感じられる")
        ]

        if let afterglow = afterglows.first(where: { containsAny($0.0, in: tags) })?.1 {
            return afterglow
        }
        return "この瞬間の空気だけが、少し遅れて心に届く"
    }

    private static func refinedFallbackCaption(title: String, placeLabel: String?, tags: [String], baseCaption: String) -> String {
        let normalizedTags = tags.map { $0.lowercased() }
        guard !title.isEmpty else { return baseCaption }

        let subject = localizedPrimarySubject(from: normalizedTags) ?? "景色"
        let locationPhrase = placeLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleLine: String

        if let locationPhrase, !locationPhrase.isEmpty {
            titleLine = "「\(title)」という名前に、\(locationPhrase)で触れた\(subject)の気配が静かに重なっている"
        } else {
            titleLine = "「\(title)」という名前に、目の前の\(subject)がそっと意味を結んでいる"
        }

        return "\(titleLine)。\(poeticAfterglow(from: normalizedTags))。"
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func foundationModelCaption(title: String, placeLabel: String?, tags: [String], baseCaption: String) async -> String? {
        let languageModel = SystemLanguageModel.default
        guard languageModel.isAvailable else { return nil }

        let instructions = """
        You write one short poetic Japanese caption for a photo memory app.
        Use the user's title as the emotional anchor.
        Keep the output to exactly two Japanese sentences.
        Do not use bullet points, quotes, emoji, or headings.
        Avoid generic filler and avoid repeating the same sentence across different photos.
        """

        let visualHints = tags.prefix(6).joined(separator: ", ")
        let placePrompt = placeLabel?.isEmpty == false ? "場所ヒント: \(placeLabel!)." : ""
        let prompt = """
        タイトル: \(title)
        視覚ヒント: \(visualHints.isEmpty ? "なし" : visualHints)
        参考文: \(baseCaption)
        \(placePrompt)
        写真の空気感を保ちながら、タイトルに寄り添った日本語の文章を生成してください。
        """

        do {
            let session = LanguageModelSession(model: languageModel) {
                Instructions(instructions)
            }
            let response = try await session.respond(to: prompt)
            let caption = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return caption.isEmpty ? nil : caption
        } catch {
            return nil
        }
    }
    #endif
}

import AVFoundation
import Speech
import UIKit
import Vision
#if canImport(FoundationModels)
import FoundationModels
#endif

struct PhotoCaptionGeneration {
    let text: String
    let source: PhotoCaptionSource
    let style: PhotoCaptionStyle
}

enum MemoryAnalysisService {
    static func requestSpeechAuthorizationIfNeeded() async {
        await log("speech authorization status=\(SFSpeechRecognizer.authorizationStatus().rawValue)", category: "analysis")
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }

        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { _ in
                continuation.resume()
            }
        }
    }

    static func analyze(photoData: Data, audioURL: URL?) async -> MemoryAnalysis {
        await log("analysis started audio=\(audioURL?.lastPathComponent ?? "none") photoBytes=\(photoData.count)", category: "analysis")
        async let visualTags = imageTags(from: photoData)
        async let transcript = transcript(from: audioURL)

        let resolvedVisualTags = await visualTags
        let resolvedTranscript = await transcript
        let resolvedAudioTags = await audioTags(from: audioURL, transcript: resolvedTranscript)
        let mood = inferMood(visualTags: resolvedVisualTags, audioTags: resolvedAudioTags, transcript: resolvedTranscript)

        let analysis = MemoryAnalysis(
            visualTags: resolvedVisualTags,
            audioTags: resolvedAudioTags,
            transcript: resolvedTranscript,
            mood: mood.rawValue
        )
        await log("analysis completed visualTags=\(resolvedVisualTags.count) audioTags=\(resolvedAudioTags.count) transcriptChars=\(resolvedTranscript.count) mood=\(mood.rawValue)", category: "analysis")
        return analysis
    }

    static func imageCaption(
        from data: Data,
        title: String? = nil,
        placeLabel: String? = nil,
        style: PhotoCaptionStyle = ResonancePreferences.defaultCaptionStyle
    ) async -> String? {
        await captionGeneration(from: data, title: title, placeLabel: placeLabel, style: style)?.text
    }

    static func captionGeneration(
        from data: Data,
        title: String? = nil,
        placeLabel: String? = nil,
        style: PhotoCaptionStyle = ResonancePreferences.defaultCaptionStyle
    ) async -> PhotoCaptionGeneration? {
        let tags = await imageTags(from: data)
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let baseCaption = generatedCaption(from: tags, style: style)

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *),
           !trimmedTitle.isEmpty,
            let aiCaption = await foundationModelCaption(
                 title: trimmedTitle,
                 placeLabel: placeLabel,
                 tags: tags,
                 baseCaption: baseCaption,
                 style: style
            ) {
            await log("caption generated with FoundationModels", category: "analysis")
            return PhotoCaptionGeneration(text: aiCaption, source: .foundationModels, style: style)
        }
        #endif

        await log("caption generated with composed fallback", category: "analysis")
        return PhotoCaptionGeneration(
            text: refinedFallbackCaption(
                title: trimmedTitle,
                placeLabel: placeLabel,
                tags: tags,
                baseCaption: baseCaption,
                style: style
             ),
            source: .composedFallback,
            style: style
        )
    }

    static func forceFoundationModelsCaption(
        from data: Data,
        title: String,
        placeLabel: String? = nil,
        style: PhotoCaptionStyle
    ) async throws -> PhotoCaptionGeneration {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw CaptionGenerationError.missingTitle
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let tags = await imageTags(from: data)
            let baseCaption = generatedCaption(from: tags, style: style)
            if let aiCaption = await foundationModelCaption(
                title: trimmedTitle,
                placeLabel: placeLabel,
                tags: tags,
                baseCaption: baseCaption,
                style: style
            ) {
                return PhotoCaptionGeneration(text: aiCaption, source: .foundationModels, style: style)
            }
            throw CaptionGenerationError.foundationModelsUnavailable
        }
        #endif

        throw CaptionGenerationError.foundationModelsUnavailable
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

        guard let recognizer = preferredSpeechRecognizer(), recognizer.isAvailable else {
            await log("transcript skipped: recognizer unavailable", category: "analysis")
            return ""
        }

        return await withCheckedContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: audioURL)
            request.shouldReportPartialResults = false
            request.addsPunctuation = true

            var task: SFSpeechRecognitionTask?
            task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    Task { @MainActor in
                        AudioPlaybackDiagnostics.shared.record("transcript completed locale=\(recognizer.locale.identifier) chars=\(result.bestTranscription.formattedString.count)", category: "analysis")
                    }
                    task?.cancel()
                    continuation.resume(returning: result.bestTranscription.formattedString)
                } else if error != nil {
                    Task { @MainActor in
                        AudioPlaybackDiagnostics.shared.record("transcript failed: \(error?.localizedDescription ?? "unknown")", category: "analysis")
                    }
                    task?.cancel()
                    continuation.resume(returning: "")
                }
            }
        }
    }

    private static func preferredSpeechRecognizer() -> SFSpeechRecognizer? {
        let supportedLocales = SFSpeechRecognizer.supportedLocales()
        let preferredLocales = [
            Locale(identifier: "ja-JP"),
            Locale(identifier: "ja_JP"),
            Locale.current
        ]

        for locale in preferredLocales where supportedLocales.contains(where: {
            $0.identifier.compare(locale.identifier, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                || ($0.language.languageCode?.identifier == locale.language.languageCode?.identifier && locale.language.languageCode?.identifier == "ja")
        }) {
            if let recognizer = SFSpeechRecognizer(locale: locale) {
                return recognizer
            }
        }

        return SFSpeechRecognizer()
    }

    @MainActor
    private static func log(_ message: String, category: String) {
        AudioPlaybackDiagnostics.shared.record(message, category: category)
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

    private static func generatedCaption(from tags: [String], style: PhotoCaptionStyle) -> String {
        switch style {
        case .poetic:
            return poeticCaption(from: tags)
        case .factual:
            return factualCaption(title: nil, placeLabel: nil, tags: tags)
        case .diary:
            return diaryCaption(title: nil, placeLabel: nil, tags: tags)
        case .haiku:
            return haikuCaption(title: nil, placeLabel: nil, tags: tags)
        case .oneLine:
            return oneLineCaption(title: nil, placeLabel: nil, tags: tags)
        }
    }

    private static func poeticCaption(from tags: [String]) -> String {
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

    private static func localizedVisualHints(from tags: [String]) -> [String] {
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

        var hints: [String] = []
        for tag in tags {
            if let localized = mappings.first(where: { tag.contains($0.0) })?.1, !hints.contains(localized) {
                hints.append(localized)
            }
        }

        if hints.isEmpty {
            hints = tags.prefix(4).map { $0.replacingOccurrences(of: "_", with: " ") }
        }

        return Array(hints.prefix(4))
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

    private static func refinedFallbackCaption(
        title: String,
        placeLabel: String?,
        tags: [String],
        baseCaption: String,
        style: PhotoCaptionStyle
    ) -> String {
        switch style {
        case .poetic:
            return refinedPoeticFallbackCaption(title: title, placeLabel: placeLabel, tags: tags, baseCaption: baseCaption)
        case .factual:
            return factualCaption(title: title, placeLabel: placeLabel, tags: tags)
        case .diary:
            return diaryCaption(title: title, placeLabel: placeLabel, tags: tags)
        case .haiku:
            return haikuCaption(title: title, placeLabel: placeLabel, tags: tags)
        case .oneLine:
            return oneLineCaption(title: title, placeLabel: placeLabel, tags: tags)
        }
    }

    private static func refinedPoeticFallbackCaption(title: String, placeLabel: String?, tags: [String], baseCaption: String) -> String {
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

    private static func factualCaption(title: String?, placeLabel: String?, tags: [String]) -> String {
        let timeLine = AtmosphereStyle(date: .now).localizedLabel
        let place = placeLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = localizedVisualHints(from: tags.map { $0.lowercased() }).first ?? "記録"
        let titleLine = title?.trimmingCharacters(in: .whitespacesAndNewlines)

        return [
            place.map { "\($0)で\(timeLine)に撮影。" } ?? "\(timeLine)に撮影。",
            titleLine?.isEmpty == false ? "題名は「\(titleLine!)」で、主な要素は\(tag)。" : "主な要素は\(tag)。"
        ]
        .joined(separator: " ")
    }

    private static func diaryCaption(title: String?, placeLabel: String?, tags: [String]) -> String {
        let subject = localizedPrimarySubject(from: tags.map { $0.lowercased() }) ?? "景色"
        if let placeLabel, !placeLabel.isEmpty {
            return "\(placeLabel)で過ごした時間。\(subject)の気配がまだ心に残っている。"
        }
        if let title, !title.isEmpty {
            return "「\(title)」と名づけたこの時間。\(subject)の気配がまだ心に残っている。"
        }
        return "\(subject)のある時間を、自分のためにそっと残した。"
    }

    private static func haikuCaption(title: String?, placeLabel: String?, tags: [String]) -> String {
        let hints = Array(localizedVisualHints(from: tags.map { $0.lowercased() }).prefix(3))
        let primary = hints.indices.contains(0) ? hints[0] : "光"
        let secondary = hints.indices.contains(1) ? hints[1] : (placeLabel?.isEmpty == false ? placeLabel! : "気配")
        let tertiary = hints.indices.contains(2) ? hints[2] : (title?.isEmpty == false ? title! : "余韻")
        return "\(primary)ゆれ \(secondary)しずかに \(tertiary)"
    }

    private static func oneLineCaption(title: String?, placeLabel: String?, tags: [String]) -> String {
        let subject = localizedPrimarySubject(from: tags.map { $0.lowercased() }) ?? "気配"
        if let placeLabel, !placeLabel.isEmpty {
            return "\(placeLabel)の\(subject)。"
        }
        if let title, !title.isEmpty {
            return "「\(title)」の\(subject)。"
        }
        return "\(subject)の一瞬。"
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func foundationModelCaption(
        title: String,
        placeLabel: String?,
        tags: [String],
        baseCaption: String,
        style: PhotoCaptionStyle
    ) async -> String? {
        let languageModel = SystemLanguageModel.default
        guard languageModel.isAvailable else { return nil }

        let localizedHints = localizedVisualHints(from: tags.map { $0.lowercased() })
        let instructions = foundationModelInstructions(for: style)

        let visualHints = localizedHints.joined(separator: "、")
        let placePrompt = placeLabel?.isEmpty == false ? "場所ヒント: \(placeLabel!)." : ""
        let prompt = """
        タイトル: \(title)
        写真から読み取れた要素: \(visualHints.isEmpty ? "明確な要素なし" : visualHints)
        写真の情景要約: \(baseCaption)
        \(placePrompt)
        出力スタイル: \(style.localizedLabel)
        \(foundationModelStylePrompt(for: style))
        """

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            let caption = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return caption.isEmpty ? nil : caption
        } catch {
            return nil
        }
    }
    #endif

    private static func foundationModelInstructions(for style: PhotoCaptionStyle) -> String {
        switch style {
        case .poetic:
            return """
            You write one short poetic Japanese caption for a photo memory app.
            Keep the output to exactly two Japanese sentences.
            Avoid filler, headings, emoji, quotes, and repetition.
            """
        case .factual:
            return """
            You write a concise factual Japanese caption for a photo memory app.
            Keep the output to one or two sentences.
            Focus on place, time, and observed situation.
            """
        case .diary:
            return """
            You write a gentle first-person Japanese diary line for a photo memory app.
            Keep the output to one or two sentences.
            The tone should be personal and soft.
            """
        case .haiku:
            return """
            You write a haiku-like Japanese caption for a photo memory app.
            Keep the output very short, with a 5-7-5 feeling when possible.
            Do not explain the format.
            """
        case .oneLine:
            return """
            You write a single concise Japanese line for a photo memory app.
            Keep the output within roughly 30 Japanese characters.
            """
        }
    }

    private static func foundationModelStylePrompt(for style: PhotoCaptionStyle) -> String {
        switch style {
        case .poetic:
            return """
            1文目ではタイトルと写真の被写体・情景を結びつけてください。
            2文目では写真から感じられる空気感や余韻を書いてください。
            """
        case .factual:
            return "場所・時間・状況を客観的に整理し、観察事実を優先してください。"
        case .diary:
            return "一人称のやわらかな日記調で、静かな感情の余韻を含めてください。"
        case .haiku:
            return "短く余白のある表現にし、俳句調のリズム感を優先してください。"
        case .oneLine:
            return "一行で簡潔にまとめ、説明を増やしすぎないでください。"
        }
    }
}

enum CaptionGenerationError: LocalizedError {
    case missingTitle
    case foundationModelsUnavailable

    var errorDescription: String? {
        switch self {
        case .missingTitle:
            return "AI内容を作るには、先にタイトルを入力してください。"
        case .foundationModelsUnavailable:
            return "Apple Intelligence を使った生成を実行できませんでした。設定と対応端末をご確認ください。"
        }
    }
}

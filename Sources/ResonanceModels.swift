import CoreGraphics
import CoreLocation
import Foundation
import SwiftData

enum AtmosphereStyle: String, CaseIterable, Codable, Identifiable {
    case dawn
    case day
    case dusk
    case night

    var id: String { rawValue }

    init(date: Date) {
        let hour = Calendar.current.component(.hour, from: date)

        switch hour {
        case 5..<8:
            self = .dawn
        case 8..<17:
            self = .day
        case 17..<20:
            self = .dusk
        default:
            self = .night
        }
    }

    var localizedLabel: String {
        switch self {
        case .dawn:
            return "朝の空気"
        case .day:
            return "昼の光"
        case .dusk:
            return "夕暮れ"
        case .night:
            return "夜の気配"
        }
    }

    var poeticLine: String {
        switch self {
        case .dawn:
            return "やわらかい光と、目覚めはじめた音。"
        case .day:
            return "輪郭のはっきりした光と、今ここにある気配。"
        case .dusk:
            return "色がほどける時間、音だけが少し長く残る。"
        case .night:
            return "静けさの奥に、小さな気配が浮かび上がる。"
        }
    }

    var restorativeLine: String {
        switch self {
        case .dawn:
            return "深く息を入れるたび、やわらかな光が静かにほどけていく。"
        case .day:
            return "肩の力を抜くと、澄んだ明るさだけがゆっくり残る。"
        case .dusk:
            return "余韻に身をゆだねると、気持ちの波がやさしく整っていく。"
        case .night:
            return "静けさに耳を澄ますほど、心のノイズが遠くへほどけていく。"
        }
    }

    var guidedBreathLine: String {
        switch self {
        case .dawn:
            return "4秒吸って、6秒吐く。目覚める光と音を、そのまま静かに受け取る。"
        case .day:
            return "肩をひらき、吐く息を少し長く。場の明るさだけをやさしく残す。"
        case .dusk:
            return "余韻に合わせてゆっくり吐くと、心の波がやわらかく整っていく。"
        case .night:
            return "音の奥行きを追いすぎず、静けさをひとつ深く通していく。"
        }
    }

    var symbolName: String {
        switch self {
        case .dawn:
            return "sunrise.fill"
        case .day:
            return "sun.max.fill"
        case .dusk:
            return "sunset.fill"
        case .night:
            return "moon.stars.fill"
        }
    }
}

enum PhotoCaptionSource: String, Codable {
    case foundationModels
    case composedFallback

    var localizedLabel: String {
        switch self {
        case .foundationModels:
            return "Apple Intelligence"
        case .composedFallback:
            return "画像解析ベース"
        }
    }

    var systemImage: String {
        switch self {
        case .foundationModels:
            return "apple.intelligence"
        case .composedFallback:
            return "sparkles.rectangle.stack"
        }
    }
}

enum InterruptionReason: String, Codable {
    case phoneCall
    case audioRouteLost
    case appBackgrounded
    case unknown

    var localizedLabel: String {
        switch self {
        case .phoneCall:
            return "電話着信"
        case .audioRouteLost:
            return "音声ルート変更"
        case .appBackgrounded:
            return "アプリ遷移"
        case .unknown:
            return "外部要因"
        }
    }
}

enum PartialCaptureRecoveryState: Equatable, Codable {
    case none
    case recovered(duration: TimeInterval, reason: InterruptionReason)
    case failed(reason: InterruptionReason)
}

struct MemoryAtmosphereMetadata: Codable {
    static let currentPhotoCaptionVersion = 3

    var placeLabel: String?
    var waveformFingerprint: [Double]
    var analysisAudioFileName: String?
    var photoCaption: String?
    var photoCaptionSourceRaw: String?
    var photoCaptionStyleRaw: String?
    var photoCaptionVersion: Int?
    var atmosphereStyleRaw: String
    var captureDuration: Double?
    var sensorSnapshot: CaptureEnvironmentSnapshot?
    var minimumDecibels: Double?
    var maximumDecibels: Double?
    var audioFeatureVector: [Float]?
    var seamlessLoopStartPoint: Double?
    var seamlessLoopEndPoint: Double?
    var directionalHotspots: [DirectionalAudioHotspot]
    var capturedSpatialAudio: Bool?

    init(
        placeLabel: String?,
        waveformFingerprint: [Double],
        analysisAudioFileName: String? = nil,
        photoCaption: String? = nil,
        atmosphereStyle: AtmosphereStyle,
        captureDuration: Double? = nil,
        sensorSnapshot: CaptureEnvironmentSnapshot? = nil,
        minimumDecibels: Double? = nil,
        maximumDecibels: Double? = nil,
        audioFeatureVector: [Float]? = nil,
        seamlessLoopStartPoint: Double? = nil,
        seamlessLoopEndPoint: Double? = nil,
        directionalHotspots: [DirectionalAudioHotspot] = [],
        capturedSpatialAudio: Bool? = nil
    ) {
        let trimmedCaption = photoCaption?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCaption = (trimmedCaption?.isEmpty == false) ? trimmedCaption : nil

        self.placeLabel = placeLabel
        self.waveformFingerprint = waveformFingerprint
        self.analysisAudioFileName = analysisAudioFileName
        self.photoCaption = normalizedCaption
        self.photoCaptionSourceRaw = normalizedCaption == nil ? nil : PhotoCaptionSource.composedFallback.rawValue
        self.photoCaptionStyleRaw = normalizedCaption == nil ? nil : PhotoCaptionStyle.poetic.rawValue
        self.photoCaptionVersion = normalizedCaption == nil ? nil : Self.currentPhotoCaptionVersion
        self.atmosphereStyleRaw = atmosphereStyle.rawValue
        self.captureDuration = captureDuration
        self.sensorSnapshot = sensorSnapshot
        self.minimumDecibels = minimumDecibels
        self.maximumDecibels = maximumDecibels
        self.audioFeatureVector = audioFeatureVector
        self.seamlessLoopStartPoint = seamlessLoopStartPoint
        self.seamlessLoopEndPoint = seamlessLoopEndPoint
        self.directionalHotspots = directionalHotspots
        self.capturedSpatialAudio = capturedSpatialAudio
    }

    var atmosphereStyle: AtmosphereStyle {
        AtmosphereStyle(rawValue: atmosphereStyleRaw) ?? .day
    }

    var needsPhotoCaptionRefresh: Bool {
        let hasCaption = !(photoCaption?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return !hasCaption || (photoCaptionVersion ?? 0) < Self.currentPhotoCaptionVersion
    }

    var photoCaptionSource: PhotoCaptionSource? {
        guard let photoCaptionSourceRaw else { return nil }
        return PhotoCaptionSource(rawValue: photoCaptionSourceRaw)
    }

    var photoCaptionStyle: PhotoCaptionStyle {
        guard let photoCaptionStyleRaw else { return .poetic }
        return PhotoCaptionStyle(rawValue: photoCaptionStyleRaw) ?? .poetic
    }

    var hasImmersiveAudioProfile: Bool {
        seamlessLoopStartPoint != nil || seamlessLoopEndPoint != nil || !(audioFeatureVector?.isEmpty ?? true)
    }
}

struct CaptureEnvironmentSnapshot: Codable {
    var latitude: Double?
    var longitude: Double?
    var horizontalAccuracy: Double?
    var altitude: Double?
    var speed: Double?
    var course: Double?
    var heading: Double?
    var pressureKilopascals: Double?
    var relativeAltitudeMeters: Double?
    var pitchDegrees: Double?
    var rollDegrees: Double?
    var yawDegrees: Double?
    var deviceOrientationRaw: String?
    var timeZoneIdentifier: String

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var deviceOrientationLabel: String? {
        switch deviceOrientationRaw {
        case "portrait":
            return "縦向き"
        case "portraitUpsideDown":
            return "逆さ縦向き"
        case "landscapeLeft":
            return "横向き"
        case "landscapeRight":
            return "逆横向き"
        case "faceUp":
            return "上向き"
        case "faceDown":
            return "下向き"
        default:
            return nil
        }
    }
}

@Model
final class MemoryEntry: Identifiable {
    var id: UUID
    var createdAt: Date
    var title: String
    var notes: String
    var isFavorite: Bool
    var photoFileName: String
    var audioFileName: String?
    var audioDuration: Double
    var visualTagsRaw: String
    var audioTagsRaw: String
    var transcript: String
    var mood: String

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        title: String,
        notes: String,
        isFavorite: Bool = false,
        photoFileName: String,
        audioFileName: String?,
        audioDuration: Double,
        visualTags: [String],
        audioTags: [String],
        transcript: String,
        mood: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.notes = notes
        self.isFavorite = isFavorite
        self.photoFileName = photoFileName
        self.audioFileName = audioFileName
        self.audioDuration = audioDuration
        self.visualTagsRaw = Self.encodeTags(visualTags)
        self.audioTagsRaw = Self.encodeTags(audioTags)
        self.transcript = transcript
        self.mood = mood
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? createdAt.formatted(date: .abbreviated, time: .shortened) : trimmed
    }

    var visualTags: [String] {
        Self.decodeTags(visualTagsRaw)
    }

    var audioTags: [String] {
        Self.decodeTags(audioTagsRaw)
    }

    var combinedTags: [String] {
        Array(Set(visualTags + audioTags)).sorted()
    }

    var autoTags: [String] {
        combinedTags
    }

    var searchableText: String {
        [
            title,
            notes,
            transcript,
            mood,
            localizedMood,
            atmosphereStyle.localizedLabel,
            photoCaption ?? "",
            placeLabel ?? "",
            visualTagsRaw.replacingOccurrences(of: "|", with: " "),
            audioTagsRaw.replacingOccurrences(of: "|", with: " ")
        ]
        .joined(separator: " ")
        .lowercased()
    }

    var searchAliasText: String {
        let loweredTags = combinedTags.map { $0.lowercased() }
        var aliases: [String] = []

        for tag in loweredTags {
            aliases.append(contentsOf: MemorySearchEngine.aliases(for: tag))
        }
        aliases.append(contentsOf: MemorySearchEngine.aliases(for: mood.lowercased()))

        return aliases.joined(separator: " ").lowercased()
    }

    var hasAudio: Bool {
        guard let audioFileName else { return false }
        return !audioFileName.isEmpty
    }

    var photoURL: URL {
        MediaStore.photoURL(for: photoFileName)
    }

    var audioURL: URL? {
        guard let audioFileName else { return nil }
        return MediaStore.audioURL(for: audioFileName)
    }

    var analysisAudioURL: URL? {
        guard let analysisAudioFileName = atmosphereMetadata?.analysisAudioFileName else {
            return audioURL
        }
        return MediaStore.audioURL(for: analysisAudioFileName)
    }

    var notePreview: String {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return descriptiveCaption }
        return trimmed
    }

    var localizedMood: String {
        MemoryMood(rawValue: mood)?.localizedLabel ?? mood
    }

    var atmosphereMetadata: MemoryAtmosphereMetadata? {
        MediaStore.loadAtmosphereMetadata(for: id)
    }

    var atmosphereStyle: AtmosphereStyle {
        atmosphereMetadata?.atmosphereStyle ?? AtmosphereStyle(date: createdAt)
    }

    var placeLabel: String? {
        atmosphereMetadata?.placeLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var photoCaption: String? {
        atmosphereMetadata?.photoCaption?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var photoCaptionSource: PhotoCaptionSource? {
        atmosphereMetadata?.photoCaptionSource
    }

    var photoCaptionStyle: PhotoCaptionStyle {
        atmosphereMetadata?.photoCaptionStyle ?? .poetic
    }

    var descriptiveCaption: String {
        if let photoCaption, !photoCaption.isEmpty {
            return photoCaption
        }
        return atmosphereStyle.poeticLine
    }

    var captureDurationSetting: Double {
        atmosphereMetadata?.captureDuration ?? audioDuration
    }

    var sensorSnapshot: CaptureEnvironmentSnapshot? {
        atmosphereMetadata?.sensorSnapshot
    }

    var minimumDecibels: Double? {
        atmosphereMetadata?.minimumDecibels
    }

    var maximumDecibels: Double? {
        atmosphereMetadata?.maximumDecibels
    }

    var coordinate: CLLocationCoordinate2D? {
        sensorSnapshot?.coordinate
    }

    var hasMapLocation: Bool {
        coordinate != nil
    }

    var waveformFingerprint: [CGFloat] {
        let storedSamples = atmosphereMetadata?.waveformFingerprint.map { CGFloat($0) } ?? []
        if !storedSamples.isEmpty {
            return storedSamples
        }
        return WaveformExtractor.samples(from: analysisAudioURL, sampleCount: 28)
    }

    var audioFeatureVector: [Float] {
        if let stored = atmosphereMetadata?.audioFeatureVector, !stored.isEmpty {
            return stored
        }
        return []
    }

    var seamlessLoopStartPoint: Double? {
        atmosphereMetadata?.seamlessLoopStartPoint
    }

    var seamlessLoopEndPoint: Double? {
        atmosphereMetadata?.seamlessLoopEndPoint
    }

    var directionalHotspots: [DirectionalAudioHotspot] {
        atmosphereMetadata?.directionalHotspots ?? []
    }

    var isSpatialCapture: Bool {
        if let stored = atmosphereMetadata?.capturedSpatialAudio {
            return stored
        }
        guard let audioURL else { return false }
        return AudioAssetProfile.inspect(url: audioURL).isTrueSpatialAudio
    }

    var sensorHighlights: [String] {
        var highlights: [String] = []

        if let placeLabel {
            highlights.append(placeLabel)
        }
        if let altitude = sensorSnapshot?.altitude {
            highlights.append(String(format: "標高 %.0fm", altitude))
        }
        if let pressure = sensorSnapshot?.pressureKilopascals {
            highlights.append(String(format: "気圧 %.1fkPa", pressure))
        }
        if let orientation = sensorSnapshot?.deviceOrientationLabel {
            highlights.append(orientation)
        }

        return highlights
    }

    var shareSummary: String {
        [
            displayTitle,
            createdAt.formatted(date: .abbreviated, time: .shortened),
            photoCaption,
            placeLabel,
            notes.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    static func encodeTags(_ tags: [String]) -> String {
        Array(
            Set(
                tags
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .map { $0.lowercased() }
            )
        )
        .sorted()
        .joined(separator: "|")
    }

    static func decodeTags(_ raw: String) -> [String] {
        raw
            .split(separator: "|")
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

struct MemoryAnalysis {
    let visualTags: [String]
    let audioTags: [String]
    let transcript: String
    let mood: String

    static let empty = MemoryAnalysis(visualTags: [], audioTags: [], transcript: "", mood: MemoryMood.reflective.rawValue)
}

enum MemoryMood: String, CaseIterable, Identifiable {
    case calm = "Calm"
    case lively = "Lively"
    case joyful = "Joyful"
    case reflective = "Reflective"
    case urban = "Urban"

    var id: String { rawValue }

    var localizedLabel: String {
        switch self {
        case .calm:
            return "落ち着き"
        case .lively:
            return "にぎやか"
        case .joyful:
            return "楽しい"
        case .reflective:
            return "しみじみ"
        case .urban:
            return "都会的"
        }
    }
}

struct MoodCompassPoint: Equatable {
    var naturalUrban: Double
    var quietLively: Double

    static let zero = MoodCompassPoint(naturalUrban: 0, quietLively: 0)

    var isCentered: Bool {
        abs(naturalUrban) < 0.12 && abs(quietLively) < 0.12
    }

    var localizedLabel: String {
        if isCentered {
            return "すべての空気感"
        }

        let horizontal: String
        if naturalUrban < -0.28 {
            horizontal = "自然"
        } else if naturalUrban > 0.28 {
            horizontal = "都市"
        } else {
            horizontal = "場"
        }

        let vertical: String
        if quietLively < -0.28 {
            vertical = "静かな"
        } else if quietLively > 0.28 {
            vertical = "賑やかな"
        } else {
            vertical = ""
        }

        return "\(vertical)\(horizontal)の空気感"
    }
}

enum MemorySearchEngine {
    static func filter(
        _ entries: [MemoryEntry],
        query: String,
        mood: String?,
        compass: MoodCompassPoint = .zero,
        similaritySeed: MemoryEntry? = nil
    ) -> [MemoryEntry] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let tokenResult = queryTokens(from: normalizedQuery)

        let rankedEntries = entries
            .filter { entry in
                let moodMatches = mood == nil || mood == entry.mood
                let queryMatches = normalizedQuery.isEmpty || matches(entry: entry, query: normalizedQuery, tokens: tokenResult.tokens, conceptGroups: tokenResult.conceptGroups)
                return moodMatches && queryMatches
            }
            .sorted { lhs, rhs in
                let lhsScore = rankingScore(
                    for: lhs,
                    query: normalizedQuery,
                    tokens: tokenResult.tokens,
                    conceptGroups: tokenResult.conceptGroups,
                    compass: compass,
                    similaritySeed: similaritySeed
                )
                let rhsScore = rankingScore(
                    for: rhs,
                    query: normalizedQuery,
                    tokens: tokenResult.tokens,
                    conceptGroups: tokenResult.conceptGroups,
                    compass: compass,
                    similaritySeed: similaritySeed
                )

                if abs(lhsScore - rhsScore) < 0.0001 {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhsScore > rhsScore
            }

        if compass.isCentered {
            return rankedEntries
        }

        let threshold = compassDistanceThreshold(for: compass)
        let narrowedEntries = rankedEntries.filter {
            compassDistance(from: compass, to: compassPoint(for: $0)) <= threshold
        }

        if !narrowedEntries.isEmpty {
            return narrowedEntries
        }

        return Array(rankedEntries.prefix(min(max(entries.count, 1), 12)))
    }

    static func similarEntries(to seed: MemoryEntry, from entries: [MemoryEntry], limit: Int = 6) -> [MemoryEntry] {
        entries
            .filter { $0.id != seed.id }
            .sorted { lhs, rhs in
                let lhsScore = similarityScore(between: seed, and: lhs)
                let rhsScore = similarityScore(between: seed, and: rhs)
                if abs(lhsScore - rhsScore) < 0.0001 {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhsScore > rhsScore
            }
            .prefix(limit)
            .map { $0 }
    }

    static func compassPoint(for entry: MemoryEntry) -> MoodCompassPoint {
        let corpus = [
            entry.autoTags.joined(separator: " "),
            entry.transcript,
            entry.placeLabel ?? "",
            entry.localizedMood,
            entry.descriptiveCaption
        ]
        .joined(separator: " ")
        .lowercased()

        var naturalUrban = 0.0
        var quietLively = 0.0

        for token in ["forest", "tree", "garden", "park", "river", "water", "ocean", "sea", "bird", "rain", "mountain", "beach", "風", "海", "雨", "木", "川", "公園", "森"] where corpus.contains(token) {
            naturalUrban -= 0.22
        }
        for token in ["street", "city", "traffic", "car", "building", "train", "station", "crowd", "都会", "車", "街", "駅", "電車", "人混み"] where corpus.contains(token) {
            naturalUrban += 0.22
        }
        for token in ["quiet", "calm", "silent", "静か", "落ち着き", "しみじみ"] where corpus.contains(token) {
            quietLively -= 0.24
        }
        for token in ["lively", "joyful", "active", "crowd", "music", "speech", "賑やか", "楽しい", "活気", "会話", "音楽"] where corpus.contains(token) {
            quietLively += 0.24
        }

        if entry.audioFeatureVector.count >= 8 {
            let vector = entry.audioFeatureVector
            quietLively += Double(vector[0] * 1.6) + Double(vector[4] * 1.2) + Double(vector[6] * 0.9) - Double(vector[5] * 1.3)
            naturalUrban += Double(vector[7] * 1.4) + Double(vector[3] * 0.6)
        } else {
            let waveformAverage = entry.waveformFingerprint.reduce(0) { $0 + $1 } / CGFloat(max(entry.waveformFingerprint.count, 1))
            quietLively += Double((waveformAverage - 0.25) * 2.2)
        }

        switch MemoryMood(rawValue: entry.mood) {
        case .calm:
            quietLively -= 0.32
        case .lively:
            quietLively += 0.36
        case .joyful:
            quietLively += 0.18
        case .urban:
            naturalUrban += 0.32
        case .reflective:
            quietLively -= 0.16
        case nil:
            break
        }

        return MoodCompassPoint(
            naturalUrban: max(-1, min(1, naturalUrban)),
            quietLively: max(-1, min(1, quietLively))
        )
    }

    static func composedFeatureVector(for entry: MemoryEntry) -> [Float] {
        let audioVector: [Float]
        if !entry.audioFeatureVector.isEmpty {
            audioVector = entry.audioFeatureVector
        } else {
            let waveform = entry.waveformFingerprint.prefix(8).map { Float($0) }
            audioVector = waveform + Array(repeating: 0, count: max(0, 8 - waveform.count))
        }

        let compass = compassPoint(for: entry)
        let atmosphereEncoding: [Float] = AtmosphereStyle.allCases.map {
            $0 == entry.atmosphereStyle ? 1 : 0
        }
        return audioVector + [
            Float(compass.naturalUrban),
            Float(compass.quietLively),
            entry.isFavorite ? 1 : 0
        ] + atmosphereEncoding
    }

    static func similarityScore(between lhs: MemoryEntry, and rhs: MemoryEntry) -> Double {
        let leftVector = composedFeatureVector(for: lhs)
        let rightVector = composedFeatureVector(for: rhs)
        guard leftVector.count == rightVector.count, !leftVector.isEmpty else { return 0 }

        var dot = 0.0
        var lhsNorm = 0.0
        var rhsNorm = 0.0
        for index in leftVector.indices {
            let left = Double(leftVector[index])
            let right = Double(rightVector[index])
            dot += left * right
            lhsNorm += left * left
            rhsNorm += right * right
        }

        guard lhsNorm > 0, rhsNorm > 0 else { return 0 }
        return dot / (sqrt(lhsNorm) * sqrt(rhsNorm))
    }

    private static func rankingScore(
        for entry: MemoryEntry,
        query: String,
        tokens: [String],
        conceptGroups: [[String]],
        compass: MoodCompassPoint,
        similaritySeed: MemoryEntry?
    ) -> Double {
        var score = 0.0

        if !query.isEmpty {
            let reasons = matchReasons(for: entry, query: query)
            score += Double(reasons.count) * 1.4
            if entry.searchableText.contains(query) {
                score += 1.1
            }
        }

        if !compass.isCentered {
            let entryCompass = compassPoint(for: entry)
            let distance = compassDistance(from: compass, to: entryCompass)
            score += max(0, 3.6 - distance * 2.6)
        }

        if let similaritySeed, similaritySeed.id != entry.id {
            score += similarityScore(between: similaritySeed, and: entry) * 2.6
        }

        score += entry.isFavorite ? 0.18 : 0
        score += max(0, 0.18 - (Date.now.timeIntervalSince(entry.createdAt) / (60 * 60 * 24 * 30 * 4)))
        return score
    }

    private static func filter(_ entries: [MemoryEntry], query: String, mood: String?) -> [MemoryEntry] {
        filter(entries, query: query, mood: mood, compass: .zero, similaritySeed: nil)
    }

    private static func compassDistance(from source: MoodCompassPoint, to destination: MoodCompassPoint) -> Double {
        hypot(destination.naturalUrban - source.naturalUrban, destination.quietLively - source.quietLively)
    }

    private static func compassDistanceThreshold(for compass: MoodCompassPoint) -> Double {
        let focus = max(abs(compass.naturalUrban), abs(compass.quietLively))
        return max(0.42, 1.12 - (focus * 0.48))
    }

    static func aliases(for term: String) -> [String] {
        synonymTable.first(where: { $0.keywords.contains(term) })?.aliases ?? []
    }

    static func matchReasons(for entry: MemoryEntry, query: String) -> [String] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return [] }

        let tokens = queryTokens(from: normalizedQuery).tokens
        var reasons: [String] = []

        if contains(query: normalizedQuery, tokens: tokens, in: entry.title) {
            reasons.append("タイトル")
        }
        if contains(query: normalizedQuery, tokens: tokens, in: entry.notes) {
            reasons.append("メモ")
        }
        if contains(query: normalizedQuery, tokens: tokens, in: entry.transcript) {
            reasons.append("文字起こし")
        }
        if contains(query: normalizedQuery, tokens: tokens, in: entry.autoTags.joined(separator: " ")) || entry.searchAliasText.contains(normalizedQuery) {
            reasons.append("タグ")
        }
        if contains(query: normalizedQuery, tokens: tokens, in: entry.mood) || contains(query: normalizedQuery, tokens: tokens, in: entry.localizedMood) {
            reasons.append("ムード")
        }
        if contains(query: normalizedQuery, tokens: tokens, in: entry.placeLabel ?? "") {
            reasons.append("場所")
        }
        if contains(query: normalizedQuery, tokens: tokens, in: entry.atmosphereStyle.localizedLabel) {
            reasons.append("時間帯")
        }

        var orderedReasons: [String] = []
        for reason in reasons where !orderedReasons.contains(reason) {
            orderedReasons.append(reason)
        }
        return orderedReasons
    }

    private static func contains(query: String, tokens: [String], in text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains(query) {
            return true
        }
        return tokens.contains { lowered.contains($0) }
    }

    private static func matches(entry: MemoryEntry, query: String, tokens: [String], conceptGroups: [[String]]) -> Bool {
        let haystacks = [
            entry.searchableText,
            normalizeForLooseMatching(entry.searchableText),
            entry.searchAliasText
        ]

        if haystacks.contains(where: { $0.contains(query) }) {
            return true
        }

        let tokenMatches = tokens.allSatisfy { term in
            haystacks.contains(where: { $0.contains(term) })
        }
        let conceptMatches = conceptGroups.allSatisfy { group in
            group.contains { alias in
                haystacks.contains(where: { $0.contains(alias) })
            }
        }

        return (tokens.isEmpty || tokenMatches) && (conceptGroups.isEmpty || conceptMatches) && (!tokens.isEmpty || !conceptGroups.isEmpty)
    }

    private static func queryTokens(from query: String) -> (tokens: [String], conceptGroups: [[String]]) {
        let tokens = Array(
            Set(
                query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 1 }
                    .map { $0.lowercased() }
            )
        )

        let normalized = normalizeForLooseMatching(query)
        let conceptGroups = synonymTable
            .filter { rule in
                rule.keywords.contains(where: { keyword in
                    normalized.contains(keyword) || query.contains(keyword)
                })
            }
            .map { Array(Set(($0.aliases + $0.keywords).map { $0.lowercased() })) }

        return (tokens, conceptGroups)
    }

    private static func normalizeForLooseMatching(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private static let synonymTable: [(keywords: [String], aliases: [String])] = [
        (keywords: ["calm", "quiet", "relax", "peaceful", "落ち着", "静か", "穏やか", "リラックス"], aliases: ["calm", "quiet", "peaceful", "relaxed", "落ち着く", "静か", "穏やか", "リラックス"]),
        (keywords: ["lively", "energetic", "party", "music", "にぎやか", "賑やか", "活気"], aliases: ["lively", "energetic", "music", "crowd", "にぎやか", "賑やか", "活気"]),
        (keywords: ["joyful", "happy", "laugh", "笑", "楽しい", "嬉しい"], aliases: ["joyful", "happy", "laugh", "smile", "笑い", "楽しい", "嬉しい"]),
        (keywords: ["urban", "city", "street", "都会", "街", "街角"], aliases: ["urban", "city", "street", "traffic", "都会", "街", "街角"]),
        (keywords: ["reflective", "nostalgic", "memory", "ノスタルジ", "思い出"], aliases: ["reflective", "nostalgic", "memory", "ノスタルジック", "思い出"]),
        (keywords: ["ocean", "sea", "wave", "water", "海", "波", "波音"], aliases: ["ocean", "sea", "wave", "water", "海", "波", "波音"]),
        (keywords: ["rain", "雨", "雨音"], aliases: ["rain", "water", "雨", "雨音"]),
        (keywords: ["cafe", "coffee", "カフェ", "コーヒー"], aliases: ["cafe", "coffee", "カフェ", "コーヒー"]),
        (keywords: ["bird", "birds", "birdsong", "鳥", "鳥の声"], aliases: ["bird", "birdsong", "鳥", "鳥の声"]),
        (keywords: ["speech", "voice", "conversation", "会話", "声"], aliases: ["speech", "voice", "conversation", "会話", "声"]),
        (keywords: ["music", "song", "guitar", "音楽", "曲", "ギター"], aliases: ["music", "song", "guitar", "音楽", "曲", "ギター"])
    ]
}

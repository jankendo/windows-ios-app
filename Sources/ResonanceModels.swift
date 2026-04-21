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

struct MemoryAtmosphereMetadata: Codable {
    var placeLabel: String?
    var waveformFingerprint: [Double]
    var photoCaption: String?
    var atmosphereStyleRaw: String
    var captureDuration: Double?
    var sensorSnapshot: CaptureEnvironmentSnapshot?
    var weatherSnapshot: MemoryWeatherSnapshot?
    var minimumDecibels: Double?
    var maximumDecibels: Double?

    init(
        placeLabel: String?,
        waveformFingerprint: [Double],
        photoCaption: String? = nil,
        atmosphereStyle: AtmosphereStyle,
        captureDuration: Double? = nil,
        sensorSnapshot: CaptureEnvironmentSnapshot? = nil,
        weatherSnapshot: MemoryWeatherSnapshot? = nil,
        minimumDecibels: Double? = nil,
        maximumDecibels: Double? = nil
    ) {
        self.placeLabel = placeLabel
        self.waveformFingerprint = waveformFingerprint
        self.photoCaption = photoCaption
        self.atmosphereStyleRaw = atmosphereStyle.rawValue
        self.captureDuration = captureDuration
        self.sensorSnapshot = sensorSnapshot
        self.weatherSnapshot = weatherSnapshot
        self.minimumDecibels = minimumDecibels
        self.maximumDecibels = maximumDecibels
    }

    var atmosphereStyle: AtmosphereStyle {
        AtmosphereStyle(rawValue: atmosphereStyleRaw) ?? .day
    }
}

struct MemoryWeatherSnapshot: Codable {
    var conditionLabel: String
    var temperatureCelsius: Double?
    var apparentTemperatureCelsius: Double?
    var symbolName: String?

    var compactSummary: String {
        let roundedTemperature = temperatureCelsius.map { "\($0.rounded(.toNearestOrEven).formatted(.number.precision(.fractionLength(0))))°C" }
        return [conditionLabel, roundedTemperature]
            .compactMap { $0 }
            .joined(separator: " · ")
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
            weatherSnapshot?.conditionLabel ?? "",
            weatherSnapshot?.compactSummary ?? "",
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

    var weatherSnapshot: MemoryWeatherSnapshot? {
        atmosphereMetadata?.weatherSnapshot
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
        return WaveformExtractor.samples(from: audioURL, sampleCount: 28)
    }

    var sensorHighlights: [String] {
        var highlights: [String] = []

        if let placeLabel {
            highlights.append(placeLabel)
        }
        if let weatherSummary = weatherSnapshot?.compactSummary, !weatherSummary.isEmpty {
            highlights.append(weatherSummary)
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

enum MemorySearchEngine {
    static func filter(_ entries: [MemoryEntry], query: String, mood: String?) -> [MemoryEntry] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let tokenResult = queryTokens(from: normalizedQuery)

        return entries.filter { entry in
            let moodMatches = mood == nil || mood == entry.mood
            let queryMatches = normalizedQuery.isEmpty || matches(entry: entry, query: normalizedQuery, tokens: tokenResult.tokens, conceptGroups: tokenResult.conceptGroups)
            return moodMatches && queryMatches
        }
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

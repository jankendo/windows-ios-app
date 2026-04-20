import Foundation
import SwiftData

@Model
final class MemoryEntry {
    var id: UUID
    var createdAt: Date
    var title: String
    var notes: String
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

    var searchableText: String {
        [
            title,
            notes,
            transcript,
            mood,
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

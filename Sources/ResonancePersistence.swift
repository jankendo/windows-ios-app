import CoreLocation
import Foundation
import SwiftData

@Model
final class MemoryCollection: Identifiable {
    var id: UUID
    var title: String
    var collectionDescription: String
    var colorTintRaw: String
    var coverMemoryId: UUID?
    var createdAt: Date
    var updatedAt: Date
    var isSmartCollection: Bool
    var smartRuleJSON: String?
    var entryIDsRaw: String

    init(
        id: UUID = UUID(),
        title: String,
        collectionDescription: String = "",
        colorTintRaw: String = AtmosphereStyle.day.rawValue,
        coverMemoryId: UUID? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isSmartCollection: Bool = false,
        smartRuleJSON: String? = nil,
        entryIDs: [UUID] = []
    ) {
        self.id = id
        self.title = title
        self.collectionDescription = collectionDescription
        self.colorTintRaw = colorTintRaw
        self.coverMemoryId = coverMemoryId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isSmartCollection = isSmartCollection
        self.smartRuleJSON = smartRuleJSON
        self.entryIDsRaw = Self.encodeIDs(entryIDs)
    }

    var entryIDs: [UUID] {
        get { Self.decodeIDs(entryIDsRaw) }
        set {
            entryIDsRaw = Self.encodeIDs(newValue)
            updatedAt = .now
        }
    }

    var atmosphereStyle: AtmosphereStyle {
        AtmosphereStyle(rawValue: colorTintRaw) ?? .day
    }

    var smartRule: MemoryCollectionSmartRule? {
        guard let smartRuleJSON, !smartRuleJSON.isEmpty else { return nil }
        guard let data = smartRuleJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MemoryCollectionSmartRule.self, from: data)
    }

    func resolvedEntries(from entries: [MemoryEntry]) -> [MemoryEntry] {
        if isSmartCollection, let smartRule {
            return entries
                .filter { smartRule.matches(entry: $0) }
                .sorted { $0.createdAt > $1.createdAt }
        }

        let ids = Set(entryIDs)
        return entries
            .filter { ids.contains($0.id) }
            .sorted { lhs, rhs in
                let lhsIndex = entryIDs.firstIndex(of: lhs.id) ?? .max
                let rhsIndex = entryIDs.firstIndex(of: rhs.id) ?? .max
                if lhsIndex == rhsIndex {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhsIndex < rhsIndex
            }
    }

    func addEntries(_ ids: [UUID]) {
        var updated = entryIDs
        for id in ids where !updated.contains(id) {
            updated.append(id)
        }
        entryIDs = updated
    }

    func removeEntry(_ id: UUID) {
        entryIDs = entryIDs.filter { $0 != id }
        if coverMemoryId == id {
            coverMemoryId = entryIDs.first
        }
    }

    private static func encodeIDs(_ ids: [UUID]) -> String {
        ids.map(\.uuidString).joined(separator: "|")
    }

    private static func decodeIDs(_ rawValue: String) -> [UUID] {
        rawValue
            .split(separator: "|")
            .compactMap { UUID(uuidString: String($0)) }
    }
}

@Model
final class MemoryScene: Identifiable {
    var id: UUID
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var intervalSeconds: Int
    var plannedCount: Int
    var actualCount: Int
    var clipDurationSeconds: Double
    var entryIDsRaw: String

    init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date = .now,
        endedAt: Date? = nil,
        intervalSeconds: Int,
        plannedCount: Int,
        actualCount: Int = 0,
        clipDurationSeconds: Double,
        entryIDs: [UUID] = []
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.intervalSeconds = intervalSeconds
        self.plannedCount = plannedCount
        self.actualCount = actualCount
        self.clipDurationSeconds = clipDurationSeconds
        self.entryIDsRaw = entryIDs.map(\.uuidString).joined(separator: "|")
    }

    var entryIDs: [UUID] {
        get {
            entryIDsRaw
                .split(separator: "|")
                .compactMap { UUID(uuidString: String($0)) }
        }
        set {
            entryIDsRaw = newValue.map(\.uuidString).joined(separator: "|")
            actualCount = newValue.count
        }
    }

    func resolvedEntries(from entries: [MemoryEntry]) -> [MemoryEntry] {
        let ids = Set(entryIDs)
        return entries
            .filter { ids.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func appendEntry(_ id: UUID) {
        var updated = entryIDs
        updated.append(id)
        entryIDs = updated
    }

    func removeEntry(_ id: UUID) {
        entryIDs = entryIDs.filter { $0 != id }
    }
}

enum LibraryDateRangeRule: String, Codable, CaseIterable, Identifiable {
    case all
    case today
    case week
    case month
    case year

    var id: String { rawValue }
}

struct MemoryCollectionSmartRule: Codable {
    var dateRange: LibraryDateRangeRule?
    var moodRaw: String?
    var favoritesOnly: Bool
    var requiredTags: [String]
    var referenceLatitude: Double?
    var referenceLongitude: Double?
    var radiusMeters: Double?

    func matches(entry: MemoryEntry) -> Bool {
        let calendar = Calendar.current

        if let dateRange {
            switch dateRange {
            case .all:
                break
            case .today:
                guard calendar.isDateInToday(entry.createdAt) else { return false }
            case .week:
                guard calendar.isDate(entry.createdAt, equalTo: .now, toGranularity: .weekOfYear) else { return false }
            case .month:
                guard calendar.isDate(entry.createdAt, equalTo: .now, toGranularity: .month) else { return false }
            case .year:
                guard calendar.isDate(entry.createdAt, equalTo: .now, toGranularity: .year) else { return false }
            }
        }

        if let moodRaw, entry.mood != moodRaw {
            return false
        }

        if favoritesOnly && !entry.isFavorite {
            return false
        }

        if !requiredTags.isEmpty {
            let entryTags = Set(entry.autoTags.map { $0.lowercased() })
            let needed = Set(requiredTags.map { $0.lowercased() })
            guard needed.isSubset(of: entryTags) else { return false }
        }

        if
            let latitude = referenceLatitude,
            let longitude = referenceLongitude,
            let radiusMeters,
            let coordinate = entry.coordinate
        {
            let distance = CLLocation(latitude: latitude, longitude: longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            guard distance <= radiusMeters else { return false }
        }

        return true
    }
}

enum ResonanceSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [MemoryEntry.self]
    }
}

enum ResonanceSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [MemoryEntry.self, MemoryCollection.self, MemoryScene.self]
    }
}

enum ResonanceMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [ResonanceSchemaV1.self, ResonanceSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: ResonanceSchemaV1.self, toVersion: ResonanceSchemaV2.self)
        ]
    }
}

enum ResonancePersistence {
    static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        do {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
            return try ModelContainer(
                for: ResonanceSchemaV2.self,
                migrationPlan: ResonanceMigrationPlan.self,
                configurations: configuration
            )
        } catch {
            fatalError("ModelContainer initialization failed: \(error.localizedDescription)")
        }
    }

    static func prune(entryID: UUID, collections: [MemoryCollection], scenes: [MemoryScene]) {
        collections.forEach { $0.removeEntry(entryID) }
        scenes.forEach { $0.removeEntry(entryID) }
    }
}

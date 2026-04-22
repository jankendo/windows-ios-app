import AVFoundation
import Foundation

struct StoredMedia {
    let photoFileName: String
    let audioFileName: String?
    let audioDuration: Double
}

enum MediaStore {
    private static let rootFolderName = "ResonanceMedia"
    private static let photoFolderName = "Photos"
    private static let audioFolderName = "Audio"
    private static let metadataFolderName = "Metadata"
    private static var metadataCache: [UUID: MemoryAtmosphereMetadata] = [:]

    static func save(photoData: Data, audioTempURL: URL?) throws -> StoredMedia {
        try ensureDirectories()

        let photoFileName = UUID().uuidString + ".jpg"
        let photoURL = photoURL(for: photoFileName)
        try photoData.write(to: photoURL, options: .atomic)

        var audioFileName: String?
        var audioDuration = 0.0

        if let audioTempURL, FileManager.default.fileExists(atPath: audioTempURL.path) {
            let audioExtension = audioTempURL.pathExtension.isEmpty ? "caf" : audioTempURL.pathExtension
            audioFileName = UUID().uuidString + ".\(audioExtension)"
            let destinationURL = audioURL(for: audioFileName!)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: audioTempURL, to: destinationURL)
            try? FileManager.default.removeItem(at: audioTempURL)
            let asset = AVURLAsset(url: destinationURL)
            audioDuration = asset.duration.seconds.isFinite ? asset.duration.seconds : 0
        }

        return StoredMedia(
            photoFileName: photoFileName,
            audioFileName: audioFileName,
            audioDuration: audioDuration
        )
    }

    static func deleteAssets(for entry: MemoryEntry) {
        try? FileManager.default.removeItem(at: photoURL(for: entry.photoFileName))
        if let audioFileName = entry.audioFileName {
            try? FileManager.default.removeItem(at: audioURL(for: audioFileName))
        }
        deleteAtmosphereMetadata(for: entry.id)
    }

    static func photoURL(for fileName: String) -> URL {
        folderURL(named: photoFolderName).appendingPathComponent(fileName)
    }

    static func audioURL(for fileName: String) -> URL {
        folderURL(named: audioFolderName).appendingPathComponent(fileName)
    }

    static func saveAtmosphereMetadata(_ metadata: MemoryAtmosphereMetadata, for entryID: UUID) throws {
        try ensureDirectories()
        let fileURL = metadataURL(for: entryID)
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: fileURL, options: .atomic)
        metadataCache[entryID] = metadata
    }

    static func updateAtmosphereMetadata(for entryID: UUID, transform: (inout MemoryAtmosphereMetadata) -> Void) throws {
        guard var metadata = loadAtmosphereMetadata(for: entryID) else { return }
        transform(&metadata)
        try saveAtmosphereMetadata(metadata, for: entryID)
    }

    static func loadAtmosphereMetadata(for entryID: UUID) -> MemoryAtmosphereMetadata? {
        if let cached = metadataCache[entryID] {
            return cached
        }

        let fileURL = metadataURL(for: entryID)
        guard
            let data = try? Data(contentsOf: fileURL),
            let metadata = try? JSONDecoder().decode(MemoryAtmosphereMetadata.self, from: data)
        else {
            return nil
        }

        metadataCache[entryID] = metadata
        return metadata
    }

    static func deleteAtmosphereMetadata(for entryID: UUID) {
        metadataCache[entryID] = nil
        try? FileManager.default.removeItem(at: metadataURL(for: entryID))
    }

    private static func ensureDirectories() throws {
        let fileManager = FileManager.default
        try [folderURL(named: photoFolderName), folderURL(named: audioFolderName), folderURL(named: metadataFolderName)].forEach {
            if !fileManager.fileExists(atPath: $0.path) {
                try fileManager.createDirectory(at: $0, withIntermediateDirectories: true)
            }
        }
    }

    private static func metadataURL(for entryID: UUID) -> URL {
        folderURL(named: metadataFolderName).appendingPathComponent(entryID.uuidString).appendingPathExtension("json")
    }

    private static func folderURL(named name: String) -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return baseURL.appendingPathComponent(rootFolderName).appendingPathComponent(name)
    }
}

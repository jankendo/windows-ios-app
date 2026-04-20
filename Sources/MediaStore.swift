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

    static func save(photoData: Data, audioTempURL: URL?) throws -> StoredMedia {
        try ensureDirectories()

        let photoFileName = UUID().uuidString + ".jpg"
        let photoURL = photoURL(for: photoFileName)
        try photoData.write(to: photoURL, options: .atomic)

        var audioFileName: String?
        var audioDuration = 0.0

        if let audioTempURL, FileManager.default.fileExists(atPath: audioTempURL.path) {
            audioFileName = UUID().uuidString + ".m4a"
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
    }

    static func photoURL(for fileName: String) -> URL {
        folderURL(named: photoFolderName).appendingPathComponent(fileName)
    }

    static func audioURL(for fileName: String) -> URL {
        folderURL(named: audioFolderName).appendingPathComponent(fileName)
    }

    private static func ensureDirectories() throws {
        let fileManager = FileManager.default
        try [folderURL(named: photoFolderName), folderURL(named: audioFolderName)].forEach {
            if !fileManager.fileExists(atPath: $0.path) {
                try fileManager.createDirectory(at: $0, withIntermediateDirectories: true)
            }
        }
    }

    private static func folderURL(named name: String) -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return baseURL.appendingPathComponent(rootFolderName).appendingPathComponent(name)
    }
}

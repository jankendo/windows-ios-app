import AVFoundation
import CoreGraphics
import Foundation

struct StoredMedia {
    let photoFileName: String
    let audioFileName: String?
    let analysisAudioFileName: String?
    let audioDuration: Double
}

enum MediaStoreError: LocalizedError {
    case missingSpatialScanManifest
    case invalidSpatialScanManifest
    case missingSpatialScanPreview
    case missingSpatialScanFrame(String)
    case invalidSpatialScanAssetPath(String)

    var errorDescription: String? {
        switch self {
        case .missingSpatialScanManifest:
            return "3D Scan bundle に manifest.json が見つかりません。"
        case .invalidSpatialScanManifest:
            return "3D Scan bundle の manifest を読み取れませんでした。"
        case .missingSpatialScanPreview:
            return "3D Scan bundle の preview 画像が不足しています。"
        case .missingSpatialScanFrame(let path):
            return "3D Scan bundle の frame が不足しています: \(path)"
        case .invalidSpatialScanAssetPath(let path):
            return "3D Scan bundle に無効な asset path が含まれています: \(path)"
        }
    }
}

enum MediaStore {
    private static let rootFolderName = "ResonanceMedia"
    private static let photoFolderName = "Photos"
    private static let audioFolderName = "Audio"
    private static let metadataFolderName = "Metadata"
    private static let scanFolderName = "Scans"
    private static let scanDraftRootFolderName = "ResonanceCaptureDrafts"
    private static let spatialScanFramesFolderName = "frames"
    private static let spatialScanWorldMapsFolderName = "world-maps"
    private static let spatialScanDerivedFolderName = "derived"
    private static let staleSpatialScanDraftMaxAge: TimeInterval = 24 * 60 * 60
    private static var metadataCache: [UUID: MemoryAtmosphereMetadata] = [:]
    private static var waveformCache: [UUID: [CGFloat]] = [:]
    private static var didCleanTemporarySpatialScanDrafts = false
    private static let waveformCacheLock = NSLock()
    private static let spatialScanCleanupLock = NSLock()

    static func save(photoData: Data, audioTempURL: URL?, analysisAudioTempURL: URL? = nil) throws -> StoredMedia {
        try ensureDirectories()
        Task { @MainActor in
            AudioPlaybackDiagnostics.shared.record("media save started photoBytes=\(photoData.count) audioTemp=\(audioTempURL?.lastPathComponent ?? "none")", category: "storage")
        }

        let photoFileName = UUID().uuidString + ".jpg"
        let photoURL = photoURL(for: photoFileName)
        try photoData.write(to: photoURL, options: .atomic)

        var audioFileName: String?
        var analysisAudioFileName: String?
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

        if let analysisAudioTempURL, FileManager.default.fileExists(atPath: analysisAudioTempURL.path) {
            if analysisAudioTempURL == audioTempURL {
                analysisAudioFileName = audioFileName
            } else {
                let analysisExtension = analysisAudioTempURL.pathExtension.isEmpty ? "caf" : analysisAudioTempURL.pathExtension
                analysisAudioFileName = UUID().uuidString + ".\(analysisExtension)"
                let analysisDestinationURL = audioURL(for: analysisAudioFileName!)
                if FileManager.default.fileExists(atPath: analysisDestinationURL.path) {
                    try FileManager.default.removeItem(at: analysisDestinationURL)
                }
                try FileManager.default.copyItem(at: analysisAudioTempURL, to: analysisDestinationURL)
                try? FileManager.default.removeItem(at: analysisAudioTempURL)
            }
        } else {
            analysisAudioFileName = audioFileName
        }

        Task { @MainActor in
            AudioPlaybackDiagnostics.shared.record(
                "media save completed photo=\(photoFileName) audio=\(audioFileName ?? "none") analysis=\(analysisAudioFileName ?? "none") duration=\(String(format: "%.2fs", audioDuration))",
                category: "storage"
            )
        }

        return StoredMedia(
            photoFileName: photoFileName,
            audioFileName: audioFileName,
            analysisAudioFileName: analysisAudioFileName,
            audioDuration: audioDuration
        )
    }

    static func deleteAssets(for entry: MemoryEntry) {
        Task { @MainActor in
            AudioPlaybackDiagnostics.shared.record("delete assets entry=\(entry.id.uuidString)", category: "storage")
        }
        if !entry.photoFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: photoURL(for: entry.photoFileName))
        }
        if let audioFileName = entry.audioFileName, !audioFileName.isEmpty {
            try? FileManager.default.removeItem(at: audioURL(for: audioFileName))
        }
        if let analysisAudioFileName = entry.atmosphereMetadata?.analysisAudioFileName,
           !analysisAudioFileName.isEmpty,
           analysisAudioFileName != entry.audioFileName {
            try? FileManager.default.removeItem(at: audioURL(for: analysisAudioFileName))
        }
        let scanFolderNames = Set(
            [
                entry.atmosphereMetadata?.storedSpatialScan?.bundleFolderName,
                entry.id.uuidString
            ].compactMap { $0 }
        )
        for scanFolderName in scanFolderNames {
            try? FileManager.default.removeItem(at: spatialScanBundleURL(for: scanFolderName))
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
        var resolvedMetadata = metadata
        if let storedSpatialScan = resolvedMetadata.storedSpatialScan {
            let syncMetadata = spatialScanSyncMetadata(for: storedSpatialScan)
            resolvedMetadata.applyStoredSpatialScan(storedSpatialScan, syncMetadata: syncMetadata)
        } else if resolvedMetadata.hasSpatialScanReference || resolvedMetadata.spatialScanSync != nil {
            resolvedMetadata.applyStoredSpatialScan(nil, syncMetadata: nil)
        }
        let fileURL = metadataURL(for: entryID)
        let data = try JSONEncoder().encode(resolvedMetadata)
        try data.write(to: fileURL, options: .atomic)
        metadataCache[entryID] = resolvedMetadata
        cacheWaveformFingerprint(resolvedMetadata.waveformFingerprint.map { CGFloat($0) }, for: entryID)
        Task { @MainActor in
            AudioPlaybackDiagnostics.shared.record("metadata saved entry=\(entryID.uuidString)", category: "storage")
        }
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

        var resolvedMetadata = metadata
        var shouldPersistResolvedMetadata = false
        if let storedSpatialScan = resolvedMetadata.storedSpatialScan {
            if let validatedSpatialScan = loadStoredSpatialScan(
                bundleFolderName: storedSpatialScan.bundleFolderName,
                manifestFileName: storedSpatialScan.manifestFileName
            ) {
                let syncMetadata = spatialScanSyncMetadata(for: validatedSpatialScan)
                if resolvedMetadata.spatialScan == nil
                    || validatedSpatialScan != storedSpatialScan
                    || resolvedMetadata.spatialScanSync != syncMetadata {
                    resolvedMetadata.applyStoredSpatialScan(validatedSpatialScan, syncMetadata: syncMetadata)
                    shouldPersistResolvedMetadata = true
                }
            } else {
                resolvedMetadata.applyStoredSpatialScan(nil, syncMetadata: nil)
                shouldPersistResolvedMetadata = true
            }
        } else if resolvedMetadata.spatialScanSync != nil {
            resolvedMetadata.spatialScanSync = nil
            shouldPersistResolvedMetadata = true
        }

        if shouldPersistResolvedMetadata {
            try? saveAtmosphereMetadata(resolvedMetadata, for: entryID)
        }

        metadataCache[entryID] = resolvedMetadata
        cacheWaveformFingerprint(resolvedMetadata.waveformFingerprint.map { CGFloat($0) }, for: entryID)
        return resolvedMetadata
    }

    static func deleteAtmosphereMetadata(for entryID: UUID) {
        metadataCache[entryID] = nil
        cacheWaveformFingerprint([], for: entryID)
        try? FileManager.default.removeItem(at: metadataURL(for: entryID))
    }

    static func saveSpatialScan(_ payload: SpatialScanCapturePayload, for entryID: UUID) throws -> StoredSpatialScan {
        try ensureDirectories()
        let normalizedManifest = try normalizedManifestForStorage(payload.manifest, sourceBundleURL: payload.bundleURL)
        let destinationFolderName = entryID.uuidString
        let destinationURL = spatialScanBundleURL(for: destinationFolderName)
        let stagingURL = spatialScanBundleURL(for: "\(destinationFolderName)-staging")
        if FileManager.default.fileExists(atPath: stagingURL.path) {
            try FileManager.default.removeItem(at: stagingURL)
        }
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        do {
            try copySpatialScanBundle(
                from: payload.bundleURL,
                originalManifest: payload.manifest,
                normalizedManifest: normalizedManifest,
                to: stagingURL
            )
            let preparedManifest = try SpatialScanReconstructionPipeline.prepare(manifest: normalizedManifest, in: stagingURL)
            try writeSpatialScanManifest(preparedManifest, in: stagingURL)
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
        cleanupTemporarySpatialScanBundleIfNeeded(payload.bundleURL)
        let storedSpatialScan = try validatedStoredSpatialScan(
            bundleFolderName: destinationFolderName,
            manifestFileName: "manifest.json"
        )
        return storedSpatialScan
    }

    static func spatialScanBundleURL(for folderName: String) -> URL {
        folderURL(named: scanFolderName).appendingPathComponent(folderName)
    }

    static func spatialScanManifestURL(for storedSpatialScan: StoredSpatialScan) -> URL {
        spatialScanBundleURL(for: storedSpatialScan.bundleFolderName)
            .appendingPathComponent(storedSpatialScan.manifestFileName)
    }

    static func spatialScanPreviewURL(for storedSpatialScan: StoredSpatialScan) -> URL {
        spatialScanBundleURL(for: storedSpatialScan.bundleFolderName)
            .appendingPathComponent(storedSpatialScan.previewImageFileName)
    }

    static func spatialScanAssetURL(relativePath: String, for storedSpatialScan: StoredSpatialScan) -> URL? {
        let bundleURL = spatialScanBundleURL(for: storedSpatialScan.bundleFolderName)
        return try? spatialScanAssetURL(relativePath: relativePath, in: bundleURL)
    }

    static func spatialScanWorldMapURL(for storedSpatialScan: StoredSpatialScan) -> URL? {
        guard let worldMapFileName = storedSpatialScan.worldMapFileName else { return nil }
        return spatialScanBundleURL(for: storedSpatialScan.bundleFolderName)
            .appendingPathComponent(worldMapFileName)
    }

    static func spatialScanDerivedAssetsURL(for storedSpatialScan: StoredSpatialScan) -> URL {
        spatialScanBundleURL(for: storedSpatialScan.bundleFolderName)
            .appendingPathComponent(spatialScanDerivedFolderName, isDirectory: true)
    }

    static func loadStoredSpatialScan(bundleFolderName: String, manifestFileName: String) -> StoredSpatialScan? {
        try? ensureDirectories()
        try? validatedStoredSpatialScan(
            bundleFolderName: bundleFolderName,
            manifestFileName: manifestFileName
        )
    }

    static func loadSpatialScanManifest(for storedSpatialScan: StoredSpatialScan) -> SpatialScanManifest? {
        try? ensureDirectories()
        return try? validatedSpatialScanManifest(
            bundleFolderName: storedSpatialScan.bundleFolderName,
            manifestFileName: storedSpatialScan.manifestFileName
        )
    }

    static func spatialScanSyncMetadata(for storedSpatialScan: StoredSpatialScan) -> SpatialScanSyncMetadata? {
        guard let manifest = loadSpatialScanManifest(for: storedSpatialScan) else {
            return nil
        }

        var assets: [SpatialScanSyncAsset] = []
        appendSpatialScanSyncAsset(
            to: &assets,
            kind: .manifest,
            relativePath: storedSpatialScan.manifestFileName,
            bundleFolderName: storedSpatialScan.bundleFolderName,
            disposition: .syncable
        )
        appendSpatialScanSyncAsset(
            to: &assets,
            kind: .preview,
            relativePath: storedSpatialScan.previewImageFileName,
            bundleFolderName: storedSpatialScan.bundleFolderName,
            disposition: .syncable
        )

        for frameSample in manifest.frameSamples {
            appendSpatialScanSyncAsset(
                to: &assets,
                kind: .frame,
                relativePath: frameSample.imageFileName,
                bundleFolderName: storedSpatialScan.bundleFolderName,
                disposition: .syncable
            )
        }

        if let worldMapFileName = storedSpatialScan.worldMapFileName {
            appendSpatialScanSyncAsset(
                to: &assets,
                kind: .worldMap,
                relativePath: worldMapFileName,
                bundleFolderName: storedSpatialScan.bundleFolderName,
                disposition: .localOnly
            )
        }

        let derivedAssetsURL = spatialScanDerivedAssetsURL(for: storedSpatialScan)
        if let enumerator = FileManager.default.enumerator(
            at: derivedAssetsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                guard
                    let isRegularFile = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
                    isRegularFile == true
                else {
                    continue
                }

                let derivedRelativePath = fileURL.path.replacingOccurrences(
                    of: derivedAssetsURL.path + "/",
                    with: "",
                    options: [.anchored]
                )
                guard
                    let normalizedDerivedRelativePath = StoredSpatialScan.normalizedRelativeAssetPath(
                        spatialScanDerivedFolderName + "/" + derivedRelativePath
                    )
                else {
                    continue
                }

                appendSpatialScanSyncAsset(
                    to: &assets,
                    kind: .derived,
                    relativePath: normalizedDerivedRelativePath,
                    bundleFolderName: storedSpatialScan.bundleFolderName,
                    disposition: .syncable
                )
            }
        }

        let sortedAssets = assets.sorted { lhs, rhs in
            if lhs.disposition == rhs.disposition {
                return lhs.relativePath < rhs.relativePath
            }
            return lhs.disposition.rawValue < rhs.disposition.rawValue
        }

        return SpatialScanSyncMetadata(
            bundleFolderName: storedSpatialScan.bundleFolderName,
            manifestFileName: storedSpatialScan.manifestFileName,
            derivedAssetsFolderName: spatialScanDerivedFolderName,
            assets: sortedAssets,
            syncDisposition: .syncable
        )
    }

    static func cachedWaveformFingerprint(for entryID: UUID) -> [CGFloat]? {
        waveformCacheLock.lock()
        defer { waveformCacheLock.unlock() }
        return waveformCache[entryID]
    }

    static func cacheWaveformFingerprint(_ samples: [CGFloat], for entryID: UUID) {
        waveformCacheLock.lock()
        defer { waveformCacheLock.unlock() }
        if samples.isEmpty {
            waveformCache[entryID] = nil
        } else {
            waveformCache[entryID] = samples
        }
    }

    private static func ensureDirectories() throws {
        let fileManager = FileManager.default
        try [folderURL(named: photoFolderName), folderURL(named: audioFolderName), folderURL(named: metadataFolderName), folderURL(named: scanFolderName)].forEach {
            if !fileManager.fileExists(atPath: $0.path) {
                try fileManager.createDirectory(at: $0, withIntermediateDirectories: true)
            }
        }
        cleanupTemporarySpatialScanDraftsIfNeeded()
    }

    private static func metadataURL(for entryID: UUID) -> URL {
        folderURL(named: metadataFolderName).appendingPathComponent(entryID.uuidString).appendingPathExtension("json")
    }

    private static func validatedStoredSpatialScan(
        bundleFolderName: String,
        manifestFileName: String
    ) throws -> StoredSpatialScan {
        let manifest = try validatedSpatialScanManifest(
            bundleFolderName: bundleFolderName,
            manifestFileName: manifestFileName,
        )
        return StoredSpatialScan(
            bundleFolderName: bundleFolderName,
            manifestFileName: manifestFileName,
            manifest: manifest
        )
    }

    private static func validatedSpatialScanManifest(
        bundleFolderName: String,
        manifestFileName: String
    ) throws -> SpatialScanManifest {
        let bundleURL = spatialScanBundleURL(for: bundleFolderName)
        let manifestURL = try spatialScanAssetURL(relativePath: manifestFileName, in: bundleURL)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw MediaStoreError.missingSpatialScanManifest
        }

        guard
            let data = try? Data(contentsOf: manifestURL),
            let decodedManifest = try? JSONDecoder().decode(SpatialScanManifest.self, from: data)
        else {
            throw MediaStoreError.invalidSpatialScanManifest
        }

        var resolvedManifest = decodedManifest
        var storedSpatialScan = StoredSpatialScan(
            bundleFolderName: bundleFolderName,
            manifestFileName: manifestFileName,
            manifest: resolvedManifest
        )
        let previewURL = try spatialScanAssetURL(relativePath: storedSpatialScan.previewImageFileName, in: bundleURL)
        guard FileManager.default.fileExists(atPath: previewURL.path) else {
            throw MediaStoreError.missingSpatialScanPreview
        }

        for frameSample in resolvedManifest.frameSamples {
            let frameURL = try spatialScanAssetURL(relativePath: frameSample.imageFileName, in: bundleURL)
            guard FileManager.default.fileExists(atPath: frameURL.path) else {
                throw MediaStoreError.missingSpatialScanFrame(frameSample.imageFileName)
            }
        }

        var shouldRewriteManifest = false
        if let worldMapFileName = storedSpatialScan.worldMapFileName,
           let worldMapURL = try? spatialScanAssetURL(relativePath: worldMapFileName, in: bundleURL),
           !FileManager.default.fileExists(atPath: worldMapURL.path) {
            resolvedManifest.worldMapFileName = nil
            shouldRewriteManifest = true
        }

        let preparedManifest = try SpatialScanReconstructionPipeline.prepare(manifest: resolvedManifest, in: bundleURL)
        if preparedManifest != resolvedManifest {
            resolvedManifest = preparedManifest
            shouldRewriteManifest = true
        }

        if shouldRewriteManifest {
            try writeSpatialScanManifest(resolvedManifest, in: bundleURL)
        }

        return resolvedManifest
    }

    private static func writeSpatialScanManifest(_ manifest: SpatialScanManifest, in bundleURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    private static func normalizedManifestForStorage(
        _ manifest: SpatialScanManifest,
        sourceBundleURL: URL
    ) throws -> SpatialScanManifest {
        let previewURL = try spatialScanAssetURL(relativePath: manifest.previewImageFileName, in: sourceBundleURL)
        guard FileManager.default.fileExists(atPath: previewURL.path) else {
            throw MediaStoreError.missingSpatialScanPreview
        }

        var normalizedManifest = manifest
        normalizedManifest.previewImageFileName = "preview.\(fileExtension(for: manifest.previewImageFileName, fallback: "jpg"))"
        normalizedManifest.captureDuration = manifest.normalizedCaptureDuration
        normalizedManifest.frameSamples = try manifest.frameSamples.enumerated().map { index, frameSample in
            let frameURL = try spatialScanAssetURL(relativePath: frameSample.imageFileName, in: sourceBundleURL)
            guard FileManager.default.fileExists(atPath: frameURL.path) else {
                throw MediaStoreError.missingSpatialScanFrame(frameSample.imageFileName)
            }
            let fileName = String(
                format: "\(spatialScanFramesFolderName)/frame-%03d.%@",
                index + 1,
                fileExtension(for: frameSample.imageFileName, fallback: "jpg")
            )
            return SpatialScanFrameSample(
                id: frameSample.id,
                imageFileName: fileName,
                timeOffset: frameSample.timeOffset,
                cameraTransform: frameSample.cameraTransform,
                cameraIntrinsics: frameSample.cameraIntrinsics,
                imageWidth: frameSample.imageWidth,
                imageHeight: frameSample.imageHeight
            )
        }
        normalizedManifest.frameCount = max(normalizedManifest.frameCount, normalizedManifest.frameSamples.count)

        if let worldMapFileName = manifest.worldMapFileName,
           (try? spatialScanAssetURL(relativePath: worldMapFileName, in: sourceBundleURL)) != nil {
            normalizedManifest.worldMapFileName = [
                spatialScanWorldMapsFolderName,
                sanitizedFileName(for: worldMapFileName, fallbackBaseName: "worldMap", fallbackExtension: "arexperience")
            ].joined(separator: "/")
        } else {
            normalizedManifest.worldMapFileName = nil
        }

        return normalizedManifest
    }

    private static func copySpatialScanBundle(
        from sourceBundleURL: URL,
        originalManifest: SpatialScanManifest,
        normalizedManifest: SpatialScanManifest,
        to destinationURL: URL
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: destinationURL.appendingPathComponent(spatialScanFramesFolderName, isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: destinationURL.appendingPathComponent(spatialScanDerivedFolderName, isDirectory: true),
            withIntermediateDirectories: true
        )

        try copySpatialScanAsset(
            fromRelativePath: originalManifest.previewImageFileName,
            in: sourceBundleURL,
            to: destinationURL.appendingPathComponent(normalizedManifest.previewImageFileName)
        )

        for (originalFrame, normalizedFrame) in zip(originalManifest.frameSamples, normalizedManifest.frameSamples) {
            try copySpatialScanAsset(
                fromRelativePath: originalFrame.imageFileName,
                in: sourceBundleURL,
                to: destinationURL.appendingPathComponent(normalizedFrame.imageFileName)
            )
        }

        if let originalWorldMapFileName = originalManifest.worldMapFileName,
           let normalizedWorldMapFileName = normalizedManifest.worldMapFileName {
            try copySpatialScanAsset(
                fromRelativePath: originalWorldMapFileName,
                in: sourceBundleURL,
                to: destinationURL.appendingPathComponent(normalizedWorldMapFileName)
            )
        }

        try copySpatialScanDerivedAssets(from: sourceBundleURL, to: destinationURL)
    }

    private static func copySpatialScanAsset(fromRelativePath relativePath: String, in bundleURL: URL, to destinationURL: URL) throws {
        let sourceURL = try spatialScanAssetURL(relativePath: relativePath, in: bundleURL)
        let parentURL = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    private static func copySpatialScanDerivedAssets(from sourceBundleURL: URL, to destinationURL: URL) throws {
        let sourceDerivedAssetsURL = sourceBundleURL.appendingPathComponent(spatialScanDerivedFolderName, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceDerivedAssetsURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }

        let destinationDerivedAssetsURL = destinationURL.appendingPathComponent(spatialScanDerivedFolderName, isDirectory: true)
        if FileManager.default.fileExists(atPath: destinationDerivedAssetsURL.path) {
            try FileManager.default.removeItem(at: destinationDerivedAssetsURL)
        }
        try FileManager.default.copyItem(at: sourceDerivedAssetsURL, to: destinationDerivedAssetsURL)
    }

    private static func spatialScanAssetURL(relativePath: String, in bundleURL: URL) throws -> URL {
        guard let normalizedRelativePath = StoredSpatialScan.normalizedRelativeAssetPath(relativePath) else {
            throw MediaStoreError.invalidSpatialScanAssetPath(relativePath)
        }

        let candidateURL = bundleURL.appendingPathComponent(normalizedRelativePath)
        let standardizedBundlePath = bundleURL.standardizedFileURL.path + "/"
        let standardizedCandidatePath = candidateURL.standardizedFileURL.path
        guard standardizedCandidatePath.hasPrefix(standardizedBundlePath) else {
            throw MediaStoreError.invalidSpatialScanAssetPath(relativePath)
        }
        return candidateURL
    }

    private static func appendSpatialScanSyncAsset(
        to assets: inout [SpatialScanSyncAsset],
        kind: SpatialScanAssetKind,
        relativePath: String,
        bundleFolderName: String,
        disposition: SpatialScanSyncDisposition
    ) {
        guard
            let normalizedRelativePath = StoredSpatialScan.normalizedRelativeAssetPath(relativePath),
            !assets.contains(where: { $0.relativePath == normalizedRelativePath })
        else {
            return
        }

        let assetURL = spatialScanBundleURL(for: bundleFolderName).appendingPathComponent(normalizedRelativePath)
        guard FileManager.default.fileExists(atPath: assetURL.path) else {
            return
        }

        let byteCount = (try? assetURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        assets.append(
            SpatialScanSyncAsset(
                kind: kind,
                relativePath: normalizedRelativePath,
                byteCount: byteCount,
                disposition: disposition
            )
        )
    }

    private static func sanitizedFileName(
        for relativePath: String,
        fallbackBaseName: String,
        fallbackExtension: String
    ) -> String {
        guard let normalizedRelativePath = StoredSpatialScan.normalizedRelativeAssetPath(relativePath) else {
            return "\(fallbackBaseName).\(fallbackExtension)"
        }

        let sourceURL = URL(fileURLWithPath: normalizedRelativePath)
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let resolvedBaseName = baseName.isEmpty ? fallbackBaseName : baseName
        let resolvedExtension = fileExtension(for: normalizedRelativePath, fallback: fallbackExtension)
        return "\(resolvedBaseName).\(resolvedExtension)"
    }

    private static func fileExtension(for relativePath: String, fallback: String) -> String {
        let pathExtension = URL(fileURLWithPath: relativePath).pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return pathExtension.isEmpty ? fallback : pathExtension.lowercased()
    }

    private static func cleanupTemporarySpatialScanDraftsIfNeeded() {
        spatialScanCleanupLock.lock()
        if didCleanTemporarySpatialScanDrafts {
            spatialScanCleanupLock.unlock()
            return
        }
        didCleanTemporarySpatialScanDrafts = true
        spatialScanCleanupLock.unlock()

        let draftsRootURL = temporarySpatialScanDraftsRootURL()
        guard let draftFolderURLs = try? FileManager.default.contentsOfDirectory(
            at: draftsRootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let cutoffDate = Date().addingTimeInterval(-staleSpatialScanDraftMaxAge)
        for draftFolderURL in draftFolderURLs {
            let resourceValues = try? draftFolderURL.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let activityDate = resourceValues?.contentModificationDate ?? resourceValues?.creationDate ?? .distantFuture
            guard activityDate < cutoffDate else { continue }
            try? FileManager.default.removeItem(at: draftFolderURL)
        }
    }

    private static func cleanupTemporarySpatialScanBundleIfNeeded(_ bundleURL: URL) {
        let draftsRootURL = temporarySpatialScanDraftsRootURL().standardizedFileURL
        let standardizedBundleURL = bundleURL.standardizedFileURL
        let draftsRootPath = draftsRootURL.path + "/"
        guard standardizedBundleURL.path.hasPrefix(draftsRootPath) else {
            return
        }
        try? FileManager.default.removeItem(at: standardizedBundleURL)
    }

    private static func temporarySpatialScanDraftsRootURL() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(scanDraftRootFolderName, isDirectory: true)
            .appendingPathComponent("SpatialScans", isDirectory: true)
    }

    private static func folderURL(named name: String) -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return baseURL.appendingPathComponent(rootFolderName).appendingPathComponent(name)
    }
}

import Foundation
import simd

enum SpatialScanReconstructionState: String, Codable, Hashable, CaseIterable {
    case captured
    case proxyReady
    case queuedForHighQuality
    case ready
    case failed
}

enum SpatialScanReconstructionExecutionPreference: String, Codable, Hashable, CaseIterable {
    case onDeviceFirst
}

enum SpatialScanReconstructionFallbackPolicy: String, Codable, Hashable, CaseIterable {
    case stayOnDevice
    case allowHybridProcessing
}

enum SpatialScanReconstructionOutputKind: String, Codable, Hashable, CaseIterable {
    case previewProxy
    case finalReconstruction
}

enum SpatialScanReconstructionRequestKind: String, Codable, Hashable, CaseIterable {
    case previewProxy
    case highQuality
}

enum SpatialScanPreparationQualityTier: String, Codable, Hashable, CaseIterable {
    case insufficient
    case previewOnly
    case readyForHighQuality
}

struct SpatialScanFrameSample: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let imageFileName: String
    let timeOffset: TimeInterval
    let cameraTransform: [Float]
    let cameraIntrinsics: [Float]
    let imageWidth: Int
    let imageHeight: Int

    init(
        id: UUID = UUID(),
        imageFileName: String,
        timeOffset: TimeInterval,
        cameraTransform: [Float],
        cameraIntrinsics: [Float],
        imageWidth: Int,
        imageHeight: Int
    ) {
        self.id = id
        self.imageFileName = imageFileName
        self.timeOffset = timeOffset
        self.cameraTransform = cameraTransform
        self.cameraIntrinsics = cameraIntrinsics
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }
}

struct SpatialScanPointSample: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let identifier: UInt64?
    let sourceFrameIndex: Int?
    let x: Float
    let y: Float
    let z: Float

    init(
        id: UUID = UUID(),
        identifier: UInt64? = nil,
        sourceFrameIndex: Int? = nil,
        x: Float,
        y: Float,
        z: Float
    ) {
        self.id = id
        self.identifier = identifier
        self.sourceFrameIndex = sourceFrameIndex
        self.x = x
        self.y = y
        self.z = z
    }
}

extension SpatialScanFrameSample {
    var translationVector: (x: Double, y: Double, z: Double)? {
        guard cameraTransform.count >= 16 else { return nil }
        return (
            x: Double(cameraTransform[12]),
            y: Double(cameraTransform[13]),
            z: Double(cameraTransform[14])
        )
    }

    var headingDegrees: Double? {
        guard cameraTransform.count >= 11 else { return nil }
        let forwardX = -Double(cameraTransform[8])
        let forwardZ = -Double(cameraTransform[10])
        let magnitude = sqrt((forwardX * forwardX) + (forwardZ * forwardZ))
        guard magnitude > 0 else { return nil }
        let degrees = atan2(forwardX / magnitude, -(forwardZ / magnitude)) * 180 / .pi
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        return normalized >= 0 ? normalized : normalized + 360
    }

    var pitchDegrees: Double? {
        guard cameraTransform.count >= 10 else { return nil }
        let forwardY = -Double(cameraTransform[9])
        let clampedForwardY = min(max(forwardY, -1), 1)
        return asin(clampedForwardY) * 180 / .pi
    }
}

struct SpatialScanReconstructionFailure: Codable, Hashable {
    var occurredAt: Date
    var code: String
    var message: String
    var retryable: Bool
}

struct SpatialScanPreparationSummary: Codable, Hashable {
    var selectedProxyFrameCount: Int
    var totalFrameCount: Int
    var coverageScore: Double
    var translationExtentMeters: Double
    var headingSpanDegrees: Double
    var verticalSpanDegrees: Double?
    var qualityTier: SpatialScanPreparationQualityTier

    init(
        selectedProxyFrameCount: Int,
        totalFrameCount: Int,
        coverageScore: Double,
        translationExtentMeters: Double,
        headingSpanDegrees: Double,
        verticalSpanDegrees: Double? = nil,
        qualityTier: SpatialScanPreparationQualityTier
    ) {
        self.selectedProxyFrameCount = max(selectedProxyFrameCount, 0)
        self.totalFrameCount = max(totalFrameCount, 0)
        self.coverageScore = coverageScore.isFinite ? min(max(coverageScore, 0), 1) : 0
        self.translationExtentMeters = translationExtentMeters.isFinite ? max(translationExtentMeters, 0) : 0
        self.headingSpanDegrees = headingSpanDegrees.isFinite ? min(max(headingSpanDegrees, 0), 360) : 0
        self.verticalSpanDegrees = verticalSpanDegrees.map { $0.isFinite ? min(max($0, 0), 180) : 0 }
        self.qualityTier = qualityTier
    }
}

struct SpatialScanReconstructionJob: Codable, Hashable {
    var id: UUID
    var requestedAt: Date
    var updatedAt: Date
    var lastProcessedAt: Date?
    var attemptCount: Int
    var preferredExecution: SpatialScanReconstructionExecutionPreference
    var fallbackPolicy: SpatialScanReconstructionFallbackPolicy
    var requestedOutputs: [SpatialScanReconstructionOutputKind]
    var proxyRequestFileName: String?
    var highQualityRequestFileName: String?
    var proxyPreparedAt: Date?
    var finalReadyAt: Date?
    var lastFailure: SpatialScanReconstructionFailure?
    var lastStatusMessage: String?

    init(
        id: UUID = UUID(),
        requestedAt: Date,
        updatedAt: Date? = nil,
        lastProcessedAt: Date? = nil,
        attemptCount: Int = 0,
        preferredExecution: SpatialScanReconstructionExecutionPreference = .onDeviceFirst,
        fallbackPolicy: SpatialScanReconstructionFallbackPolicy = .allowHybridProcessing,
        requestedOutputs: [SpatialScanReconstructionOutputKind] = SpatialScanReconstructionOutputKind.allCases,
        proxyRequestFileName: String? = nil,
        highQualityRequestFileName: String? = nil,
        proxyPreparedAt: Date? = nil,
        finalReadyAt: Date? = nil,
        lastFailure: SpatialScanReconstructionFailure? = nil,
        lastStatusMessage: String? = nil
    ) {
        self.id = id
        self.requestedAt = requestedAt
        self.updatedAt = updatedAt ?? requestedAt
        self.lastProcessedAt = lastProcessedAt
        self.attemptCount = max(attemptCount, 0)
        self.preferredExecution = preferredExecution
        self.fallbackPolicy = fallbackPolicy
        self.requestedOutputs = requestedOutputs.isEmpty ? SpatialScanReconstructionOutputKind.allCases : requestedOutputs
        self.proxyRequestFileName = proxyRequestFileName
        self.highQualityRequestFileName = highQualityRequestFileName
        self.proxyPreparedAt = proxyPreparedAt
        self.finalReadyAt = finalReadyAt
        self.lastFailure = lastFailure
        self.lastStatusMessage = lastStatusMessage
    }
}

struct SpatialScanReconstructionRequest: Codable, Hashable {
    static let currentSchemaVersion = 3

    var schemaVersion: Int
    var kind: SpatialScanReconstructionRequestKind
    var createdAt: Date
    var preferredExecution: SpatialScanReconstructionExecutionPreference
    var fallbackPolicy: SpatialScanReconstructionFallbackPolicy
    var requestedOutputs: [SpatialScanReconstructionOutputKind]
    var previewImageFileName: String
    var worldMapFileName: String?
    var anchorHeadingDegrees: Double?
    var captureDuration: TimeInterval
    var coverageScore: Double
    var optimizedPointCloudFileName: String?
    var optimizedPointCloudPointCount: Int?
    var pointSamples: [SpatialScanPointSample]
    var frameSamples: [SpatialScanFrameSample]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        kind: SpatialScanReconstructionRequestKind,
        createdAt: Date,
        preferredExecution: SpatialScanReconstructionExecutionPreference,
        fallbackPolicy: SpatialScanReconstructionFallbackPolicy,
        requestedOutputs: [SpatialScanReconstructionOutputKind],
        previewImageFileName: String,
        worldMapFileName: String?,
        anchorHeadingDegrees: Double?,
        captureDuration: TimeInterval,
        coverageScore: Double,
        optimizedPointCloudFileName: String? = nil,
        optimizedPointCloudPointCount: Int? = nil,
        pointSamples: [SpatialScanPointSample] = [],
        frameSamples: [SpatialScanFrameSample]
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.createdAt = createdAt
        self.preferredExecution = preferredExecution
        self.fallbackPolicy = fallbackPolicy
        self.requestedOutputs = requestedOutputs
        self.previewImageFileName = previewImageFileName
        self.worldMapFileName = worldMapFileName
        self.anchorHeadingDegrees = anchorHeadingDegrees
        self.captureDuration = captureDuration.isFinite ? max(captureDuration, 0) : 0
        self.coverageScore = coverageScore.isFinite ? min(max(coverageScore, 0), 1) : 0
        self.optimizedPointCloudFileName = optimizedPointCloudFileName
        self.optimizedPointCloudPointCount = optimizedPointCloudPointCount.map { max($0, 0) }
        self.pointSamples = pointSamples
        self.frameSamples = frameSamples
    }
}

struct SpatialScanManifest: Codable, Hashable {
    static let currentSchemaVersion = 4

    var schemaVersion: Int?
    var capturedAt: Date
    var captureDuration: TimeInterval
    var frameCount: Int
    var fieldOfViewLimited: Bool
    var anchorHeadingDegrees: Double?
    var previewImageFileName: String
    var worldMapFileName: String?
    var reconstructionState: SpatialScanReconstructionState
    var reconstructionJob: SpatialScanReconstructionJob?
    var preparationSummary: SpatialScanPreparationSummary?
    var optimizedPointCloudFileName: String?
    var optimizedPointCloudPointCount: Int?
    var pointSamples: [SpatialScanPointSample]
    var frameSamples: [SpatialScanFrameSample]

    init(
        schemaVersion: Int? = nil,
        capturedAt: Date,
        captureDuration: TimeInterval,
        frameCount: Int,
        fieldOfViewLimited: Bool,
        anchorHeadingDegrees: Double?,
        previewImageFileName: String,
        worldMapFileName: String?,
        reconstructionState: SpatialScanReconstructionState,
        reconstructionJob: SpatialScanReconstructionJob? = nil,
        preparationSummary: SpatialScanPreparationSummary? = nil,
        optimizedPointCloudFileName: String? = nil,
        optimizedPointCloudPointCount: Int? = nil,
        pointSamples: [SpatialScanPointSample] = [],
        frameSamples: [SpatialScanFrameSample]
    ) {
        self.schemaVersion = schemaVersion
        self.capturedAt = capturedAt
        self.captureDuration = captureDuration
        self.frameCount = frameCount
        self.fieldOfViewLimited = fieldOfViewLimited
        self.anchorHeadingDegrees = anchorHeadingDegrees
        self.previewImageFileName = previewImageFileName
        self.worldMapFileName = worldMapFileName
        self.reconstructionState = reconstructionState
        self.reconstructionJob = reconstructionJob
        self.preparationSummary = preparationSummary
        self.optimizedPointCloudFileName = StoredSpatialScan.normalizedRelativeAssetPath(optimizedPointCloudFileName)
        self.optimizedPointCloudPointCount = optimizedPointCloudPointCount.map { max($0, 0) }
        self.pointSamples = pointSamples
        self.frameSamples = frameSamples
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case capturedAt
        case captureDuration
        case frameCount
        case fieldOfViewLimited
        case anchorHeadingDegrees
        case previewImageFileName
        case worldMapFileName
        case reconstructionState
        case reconstructionJob
        case preparationSummary
        case optimizedPointCloudFileName
        case optimizedPointCloudPointCount
        case pointSamples
        case frameSamples
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        self.capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        self.captureDuration = try container.decode(TimeInterval.self, forKey: .captureDuration)
        self.frameCount = try container.decode(Int.self, forKey: .frameCount)
        self.fieldOfViewLimited = try container.decode(Bool.self, forKey: .fieldOfViewLimited)
        self.anchorHeadingDegrees = try container.decodeIfPresent(Double.self, forKey: .anchorHeadingDegrees)
        self.previewImageFileName = try container.decode(String.self, forKey: .previewImageFileName)
        self.worldMapFileName = try container.decodeIfPresent(String.self, forKey: .worldMapFileName)
        self.reconstructionState = try container.decode(SpatialScanReconstructionState.self, forKey: .reconstructionState)
        self.reconstructionJob = try container.decodeIfPresent(SpatialScanReconstructionJob.self, forKey: .reconstructionJob)
        self.preparationSummary = try container.decodeIfPresent(SpatialScanPreparationSummary.self, forKey: .preparationSummary)
        self.optimizedPointCloudFileName = StoredSpatialScan.normalizedRelativeAssetPath(
            try container.decodeIfPresent(String.self, forKey: .optimizedPointCloudFileName)
        )
        self.optimizedPointCloudPointCount = try container.decodeIfPresent(Int.self, forKey: .optimizedPointCloudPointCount)
            .map { max($0, 0) }
        // Legacy manifests embedded thousands of points in JSON. Skipping that payload keeps library/detail
        // navigation responsive; optimized binary point clouds or ARWorldMap provide preview geometry.
        self.pointSamples = []
        self.frameSamples = try container.decode([SpatialScanFrameSample].self, forKey: .frameSamples)
    }
}

extension SpatialScanManifest {
    var normalizedFrameCount: Int {
        max(frameCount, frameSamples.count)
    }

    var normalizedCaptureDuration: TimeInterval {
        captureDuration.isFinite ? max(captureDuration, 0) : 0
    }

    var resolvedSchemaVersion: Int {
        schemaVersion ?? 1
    }
}

struct SpatialScanCapturePayload {
    let bundleURL: URL
    var manifest: SpatialScanManifest
}

enum SpatialScanSyncDisposition: String, Codable, Hashable {
    case syncable
    case localOnly
}

enum SpatialScanAssetKind: String, Codable, Hashable {
    case manifest
    case preview
    case frame
    case worldMap
    case derived
}

struct SpatialScanSyncAsset: Codable, Hashable, Identifiable {
    let kind: SpatialScanAssetKind
    let relativePath: String
    let byteCount: Int64?
    let disposition: SpatialScanSyncDisposition

    var id: String { relativePath }

    init(
        kind: SpatialScanAssetKind,
        relativePath: String,
        byteCount: Int64? = nil,
        disposition: SpatialScanSyncDisposition
    ) {
        self.kind = kind
        self.relativePath = StoredSpatialScan.normalizedRelativeAssetPath(relativePath) ?? relativePath
        self.byteCount = byteCount
        self.disposition = disposition
    }
}

struct StoredSpatialScan: Hashable {
    let bundleFolderName: String
    let manifestFileName: String
    let previewImageFileName: String
    let worldMapFileName: String?
    let frameCount: Int
    let captureDuration: TimeInterval
    let reconstructionState: SpatialScanReconstructionState

    init(
        bundleFolderName: String,
        manifestFileName: String,
        previewImageFileName: String,
        worldMapFileName: String?,
        frameCount: Int,
        captureDuration: TimeInterval,
        reconstructionState: SpatialScanReconstructionState
    ) {
        self.bundleFolderName = Self.normalizedBundleFolderName(bundleFolderName) ?? bundleFolderName
        self.manifestFileName = Self.normalizedRelativeAssetPath(manifestFileName) ?? manifestFileName
        self.previewImageFileName = Self.normalizedRelativeAssetPath(previewImageFileName) ?? previewImageFileName
        self.worldMapFileName = Self.normalizedRelativeAssetPath(worldMapFileName)
        self.frameCount = max(frameCount, 0)
        self.captureDuration = captureDuration.isFinite ? max(captureDuration, 0) : 0
        self.reconstructionState = reconstructionState
    }

    init(bundleFolderName: String, manifestFileName: String = "manifest.json", manifest: SpatialScanManifest) {
        self.init(
            bundleFolderName: bundleFolderName,
            manifestFileName: manifestFileName,
            previewImageFileName: manifest.previewImageFileName,
            worldMapFileName: manifest.worldMapFileName,
            frameCount: manifest.normalizedFrameCount,
            captureDuration: manifest.normalizedCaptureDuration,
            reconstructionState: manifest.reconstructionState
        )
    }

    var isValid: Bool {
        Self.normalizedBundleFolderName(bundleFolderName) != nil
            && Self.normalizedRelativeAssetPath(manifestFileName) != nil
            && Self.normalizedRelativeAssetPath(previewImageFileName) != nil
    }

    static func legacyReference(
        bundleFolderName: String?,
        manifestFileName: String?,
        previewImageFileName: String?,
        worldMapFileName: String?,
        frameCount: Int?,
        captureDuration: TimeInterval?,
        reconstructionStateRaw: String?
    ) -> StoredSpatialScan? {
        guard
            let bundleFolderName = normalizedBundleFolderName(bundleFolderName),
            let manifestFileName = normalizedRelativeAssetPath(manifestFileName),
            let previewImageFileName = normalizedRelativeAssetPath(previewImageFileName)
        else {
            return nil
        }

        return StoredSpatialScan(
            bundleFolderName: bundleFolderName,
            manifestFileName: manifestFileName,
            previewImageFileName: previewImageFileName,
            worldMapFileName: worldMapFileName,
            frameCount: frameCount ?? 0,
            captureDuration: captureDuration ?? 0,
            reconstructionState: SpatialScanReconstructionState(rawValue: reconstructionStateRaw ?? "") ?? .captured
        )
    }

    static func normalizedRelativeAssetPath(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }

        let components = trimmed
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map(String.init)

        guard !components.isEmpty else { return nil }
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }

        return components.joined(separator: "/")
    }

    private static func normalizedBundleFolderName(_ value: String?) -> String? {
        guard let normalized = normalizedRelativeAssetPath(value) else {
            return nil
        }
        guard !normalized.contains("/") else {
            return nil
        }
        return normalized
    }
}

enum SpatialScanReconstructionPipeline {
    private static let reconstructionFolderPath = "derived/reconstruction"
    private static let proxyRequestFileName = "proxy-request.json"
    private static let highQualityRequestFileName = "high-quality-request.json"

    static func prepare(manifest: SpatialScanManifest, in bundleURL: URL, now: Date = .now) throws -> SpatialScanManifest {
        var resolvedManifest = manifest
        let summary = summarizePreparation(for: resolvedManifest)
        let reconstructionFolderURL = bundleURL
            .appendingPathComponent("derived", isDirectory: true)
            .appendingPathComponent("reconstruction", isDirectory: true)
        let proxyRequestPath = "\(reconstructionFolderPath)/\(proxyRequestFileName)"
        let highQualityRequestPath = "\(reconstructionFolderPath)/\(highQualityRequestFileName)"
        let proxyRequestURL = reconstructionFolderURL.appendingPathComponent(proxyRequestFileName)
        let highQualityRequestURL = reconstructionFolderURL.appendingPathComponent(highQualityRequestFileName)

        var job = resolvedManifest.reconstructionJob ?? SpatialScanReconstructionJob(requestedAt: resolvedManifest.capturedAt)
        let shouldRefresh =
            needsPreparationRefresh(for: resolvedManifest, bundleURL: bundleURL)
            || resolvedManifest.resolvedSchemaVersion < SpatialScanManifest.currentSchemaVersion
            || resolvedManifest.preparationSummary != summary
        guard shouldRefresh else {
            return resolvedManifest
        }

        resolvedManifest.schemaVersion = SpatialScanManifest.currentSchemaVersion
        resolvedManifest.preparationSummary = summary
        job.attemptCount = max(job.attemptCount, 0) + 1
        job.updatedAt = now
        job.lastProcessedAt = now
        job.lastFailure = nil

        switch summary.qualityTier {
        case .insufficient:
            removeFileIfPresent(at: proxyRequestURL)
            removeFileIfPresent(at: highQualityRequestURL)
            job.proxyRequestFileName = nil
            job.highQualityRequestFileName = nil
            job.proxyPreparedAt = nil
            job.finalReadyAt = nil
            job.lastFailure = SpatialScanReconstructionFailure(
                occurredAt: now,
                code: "insufficient-coverage",
                message: "360度の方位・上下レンジ・フレーム密度が不足しているため、再構成の準備を完了できませんでした。",
                retryable: true
            )
            job.lastStatusMessage = "追加のスキャンで再試行できます。"
            resolvedManifest.reconstructionState = .failed

        case .previewOnly:
            try FileManager.default.createDirectory(at: reconstructionFolderURL, withIntermediateDirectories: true)
            let proxyRequest = SpatialScanReconstructionRequest(
                kind: .previewProxy,
                createdAt: now,
                preferredExecution: job.preferredExecution,
                fallbackPolicy: .stayOnDevice,
                requestedOutputs: [.previewProxy],
                previewImageFileName: resolvedManifest.previewImageFileName,
                worldMapFileName: resolvedManifest.worldMapFileName,
                anchorHeadingDegrees: resolvedManifest.anchorHeadingDegrees,
                captureDuration: resolvedManifest.normalizedCaptureDuration,
                coverageScore: summary.coverageScore,
                optimizedPointCloudFileName: resolvedManifest.optimizedPointCloudFileName,
                optimizedPointCloudPointCount: resolvedManifest.optimizedPointCloudPointCount,
                pointSamples: resolvedManifest.pointSamples,
                frameSamples: selectProxyFrameSamples(from: resolvedManifest.frameSamples)
            )
            try writeRequest(proxyRequest, to: proxyRequestURL)
            removeFileIfPresent(at: highQualityRequestURL)
            job.proxyRequestFileName = proxyRequestPath
            job.highQualityRequestFileName = nil
            job.proxyPreparedAt = now
            job.finalReadyAt = nil
            job.lastStatusMessage = "オンデバイス用 proxy リクエストを準備しました。"
            resolvedManifest.reconstructionState = .proxyReady

        case .readyForHighQuality:
            try FileManager.default.createDirectory(at: reconstructionFolderURL, withIntermediateDirectories: true)
            let proxyRequest = SpatialScanReconstructionRequest(
                kind: .previewProxy,
                createdAt: now,
                preferredExecution: job.preferredExecution,
                fallbackPolicy: .stayOnDevice,
                requestedOutputs: [.previewProxy],
                previewImageFileName: resolvedManifest.previewImageFileName,
                worldMapFileName: resolvedManifest.worldMapFileName,
                anchorHeadingDegrees: resolvedManifest.anchorHeadingDegrees,
                captureDuration: resolvedManifest.normalizedCaptureDuration,
                coverageScore: summary.coverageScore,
                optimizedPointCloudFileName: resolvedManifest.optimizedPointCloudFileName,
                optimizedPointCloudPointCount: resolvedManifest.optimizedPointCloudPointCount,
                pointSamples: resolvedManifest.pointSamples,
                frameSamples: selectProxyFrameSamples(from: resolvedManifest.frameSamples)
            )
            let highQualityRequest = SpatialScanReconstructionRequest(
                kind: .highQuality,
                createdAt: now,
                preferredExecution: job.preferredExecution,
                fallbackPolicy: job.fallbackPolicy,
                requestedOutputs: job.requestedOutputs,
                previewImageFileName: resolvedManifest.previewImageFileName,
                worldMapFileName: resolvedManifest.worldMapFileName,
                anchorHeadingDegrees: resolvedManifest.anchorHeadingDegrees,
                captureDuration: resolvedManifest.normalizedCaptureDuration,
                coverageScore: summary.coverageScore,
                optimizedPointCloudFileName: resolvedManifest.optimizedPointCloudFileName,
                optimizedPointCloudPointCount: resolvedManifest.optimizedPointCloudPointCount,
                pointSamples: resolvedManifest.pointSamples,
                frameSamples: resolvedManifest.frameSamples
            )
            try writeRequest(proxyRequest, to: proxyRequestURL)
            try writeRequest(highQualityRequest, to: highQualityRequestURL)
            job.proxyRequestFileName = proxyRequestPath
            job.highQualityRequestFileName = highQualityRequestPath
            job.proxyPreparedAt = now
            if optimizedPointCloudExists(for: resolvedManifest, bundleURL: bundleURL) {
                job.finalReadyAt = now
                job.lastStatusMessage = "最適化済み3Dプレビューを生成しました。"
                resolvedManifest.reconstructionState = .ready
            } else {
                job.finalReadyAt = nil
                job.lastStatusMessage = "オンデバイス proxy と高品質 handoff を準備しました。"
                resolvedManifest.reconstructionState = .queuedForHighQuality
            }
        }

        resolvedManifest.reconstructionJob = job
        return resolvedManifest
    }

    private static func needsPreparationRefresh(for manifest: SpatialScanManifest, bundleURL: URL) -> Bool {
        guard let job = manifest.reconstructionJob else { return true }
        if manifest.resolvedSchemaVersion < SpatialScanManifest.currentSchemaVersion {
            return true
        }
        if job.lastProcessedAt == nil {
            return true
        }
        if manifest.reconstructionState == .ready,
           optimizedPointCloudExists(for: manifest, bundleURL: bundleURL) {
            return false
        }
        if let proxyRequestFileName = job.proxyRequestFileName {
            let proxyURL = bundleURL.appendingPathComponent(proxyRequestFileName)
            if !FileManager.default.fileExists(atPath: proxyURL.path) {
                return true
            }
        } else if manifest.reconstructionState != .failed {
            return true
        }
        if manifest.reconstructionState == .queuedForHighQuality,
           let highQualityRequestFileName = job.highQualityRequestFileName {
            let requestURL = bundleURL.appendingPathComponent(highQualityRequestFileName)
            return !FileManager.default.fileExists(atPath: requestURL.path)
        }
        return manifest.reconstructionState == .captured
    }

    private static func summarizePreparation(for manifest: SpatialScanManifest) -> SpatialScanPreparationSummary {
        let frameCount = manifest.normalizedFrameCount
        let proxyFrames = selectProxyFrameSamples(from: manifest.frameSamples)
        let translationExtent = translationExtentMeters(for: manifest.frameSamples)
        let headingSpan = headingSpanDegrees(for: manifest.frameSamples.compactMap(\.headingDegrees))
        let verticalSpan = linearSpanDegrees(for: manifest.frameSamples.compactMap(\.pitchDegrees))
        let pointCount = manifest.optimizedPointCloudPointCount ?? manifest.pointSamples.count

        let frameScore = min(Double(frameCount) / 36, 1)
        let durationScore = min(manifest.normalizedCaptureDuration / 14, 1)
        let headingScore = min(headingSpan / 320, 1)
        let verticalScore = min(verticalSpan / 60, 1)
        let pointScore = min(Double(pointCount) / 9_000, 1)
        let stationaryScore = stationaryScore(forTranslationExtent: translationExtent)
        var coverageScore = (headingScore * 0.28)
            + (frameScore * 0.2)
            + (pointScore * 0.2)
            + (verticalScore * 0.14)
            + (durationScore * 0.1)
            + (stationaryScore * 0.08)
        if manifest.worldMapFileName != nil {
            coverageScore = min(coverageScore + 0.1, 1)
        }

        let qualityTier: SpatialScanPreparationQualityTier
        if frameCount < 8 || headingSpan < 90 || coverageScore < 0.35 {
            qualityTier = .insufficient
        } else if frameCount >= 28
            && headingSpan >= 260
            && verticalSpan >= 42
            && pointCount >= 3_000
            && coverageScore >= 0.72
            && stationaryScore >= 0.45 {
            qualityTier = .readyForHighQuality
        } else {
            qualityTier = .previewOnly
        }

        return SpatialScanPreparationSummary(
            selectedProxyFrameCount: proxyFrames.count,
            totalFrameCount: frameCount,
            coverageScore: coverageScore,
            translationExtentMeters: translationExtent,
            headingSpanDegrees: headingSpan,
            verticalSpanDegrees: verticalSpan,
            qualityTier: qualityTier
        )
    }

    private static func selectProxyFrameSamples(from frameSamples: [SpatialScanFrameSample]) -> [SpatialScanFrameSample] {
        guard frameSamples.count > 12 else { return frameSamples }
        let targetCount = min(max(frameSamples.count / 2, 6), 12)
        let indices = evenlyDistributedIndices(totalCount: frameSamples.count, targetCount: targetCount)
        return indices.compactMap { index in
            guard frameSamples.indices.contains(index) else { return nil }
            return frameSamples[index]
        }
    }

    private static func evenlyDistributedIndices(totalCount: Int, targetCount: Int) -> [Int] {
        guard totalCount > 0 else { return [] }
        guard targetCount > 0 else { return [] }
        guard totalCount > targetCount else { return Array(0..<totalCount) }

        let denominator = max(targetCount - 1, 1)
        return Array(
            Set(
                (0..<targetCount).map { offset in
                    Int(round((Double(offset) / Double(denominator)) * Double(totalCount - 1)))
                }
            )
        )
        .sorted()
    }

    private static func translationExtentMeters(for frameSamples: [SpatialScanFrameSample]) -> Double {
        let translations = frameSamples.compactMap(\.translationVector)
        guard let first = translations.first else { return 0 }

        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        var minZ = first.z
        var maxZ = first.z

        for translation in translations.dropFirst() {
            minX = min(minX, translation.x)
            maxX = max(maxX, translation.x)
            minY = min(minY, translation.y)
            maxY = max(maxY, translation.y)
            minZ = min(minZ, translation.z)
            maxZ = max(maxZ, translation.z)
        }

        let deltaX = maxX - minX
        let deltaY = maxY - minY
        let deltaZ = maxZ - minZ
        return sqrt((deltaX * deltaX) + (deltaY * deltaY) + (deltaZ * deltaZ))
    }

    private static func headingSpanDegrees(for headings: [Double]) -> Double {
        guard headings.count > 1 else { return 0 }
        let normalized = headings
            .map { heading -> Double in
                let wrapped = heading.truncatingRemainder(dividingBy: 360)
                return wrapped >= 0 ? wrapped : wrapped + 360
            }
            .sorted()

        guard let first = normalized.first, let last = normalized.last else { return 0 }
        var largestGap = first + 360 - last
        for pair in zip(normalized, normalized.dropFirst()) {
            largestGap = max(largestGap, pair.1 - pair.0)
        }
        return min(max(360 - largestGap, 0), 360)
    }

    private static func linearSpanDegrees(for values: [Double]) -> Double {
        guard let minimum = values.min(), let maximum = values.max() else { return 0 }
        return min(max(maximum - minimum, 0), 180)
    }

    private static func stationaryScore(forTranslationExtent translationExtent: Double) -> Double {
        if translationExtent <= 0.85 {
            return 1
        }
        if translationExtent >= 1.8 {
            return 0
        }
        return 1 - ((translationExtent - 0.85) / 0.95)
    }

    private static func writeRequest(_ request: SpatialScanReconstructionRequest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(request)
        try data.write(to: url, options: .atomic)
    }

    private static func optimizedPointCloudExists(for manifest: SpatialScanManifest, bundleURL: URL) -> Bool {
        guard let fileName = manifest.optimizedPointCloudFileName else { return false }
        let url = bundleURL.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func removeFileIfPresent(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

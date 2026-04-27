import Foundation

enum SpatialScanReconstructionState: String, Codable, Hashable, CaseIterable {
    case captured
    case proxyReady
    case queuedForHighQuality
    case ready
    case failed
}

struct SpatialScanFrameSample: Codable, Hashable, Identifiable {
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

struct SpatialScanManifest: Codable, Hashable {
    var capturedAt: Date
    var captureDuration: TimeInterval
    var frameCount: Int
    var fieldOfViewLimited: Bool
    var anchorHeadingDegrees: Double?
    var previewImageFileName: String
    var worldMapFileName: String?
    var reconstructionState: SpatialScanReconstructionState
    var frameSamples: [SpatialScanFrameSample]
}

struct SpatialScanCapturePayload {
    let bundleURL: URL
    let manifest: SpatialScanManifest
}

struct StoredSpatialScan {
    let bundleFolderName: String
    let manifestFileName: String
    let previewImageFileName: String
    let worldMapFileName: String?
    let frameCount: Int
    let captureDuration: TimeInterval
    let reconstructionState: SpatialScanReconstructionState
}

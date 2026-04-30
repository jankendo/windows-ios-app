import CoreGraphics
import Foundation
import ImageIO
import simd

struct SpatialScanOptimizedPoint: Hashable, Sendable {
    let x: Float
    let y: Float
    let z: Float
    let r: Float
    let g: Float
    let b: Float
    let normalX: Float
    let normalY: Float
    let normalZ: Float
    let radius: Float

    init(
        x: Float,
        y: Float,
        z: Float,
        r: Float,
        g: Float,
        b: Float,
        normalX: Float = 0,
        normalY: Float = 1,
        normalZ: Float = 0,
        radius: Float = 0.022
    ) {
        self.x = x
        self.y = y
        self.z = z
        self.r = r
        self.g = g
        self.b = b
        self.normalX = normalX
        self.normalY = normalY
        self.normalZ = normalZ
        self.radius = radius
    }
}

struct SpatialScanPointCloudOptimizationResult: Hashable, Sendable {
    let relativePath: String
    let pointCount: Int
}

enum SpatialScanOptimizedPointCloudError: Error {
    case invalidData
    case unsupportedVersion
    case noUsablePoints
}

enum SpatialScanOptimizedPointCloud {
    static let relativePath = "derived/reconstruction/optimized-point-cloud.rspc"

    private static let magic: UInt32 = 0x4350_5352
    private static let version: UInt32 = 2
    private static let headerByteCount = 12
    private static let legacyBytesPerPoint = 24
    private static let bytesPerPoint = 40

    static func write(points: [SpatialScanOptimizedPoint], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var data = Data()
        data.reserveCapacity(headerByteCount + (points.count * bytesPerPoint))
        data.appendLittleEndianUInt32(magic)
        data.appendLittleEndianUInt32(version)
        data.appendLittleEndianUInt32(UInt32(points.count))

        for point in points {
            data.appendLittleEndianFloat(point.x)
            data.appendLittleEndianFloat(point.y)
            data.appendLittleEndianFloat(point.z)
            data.appendLittleEndianFloat(point.r)
            data.appendLittleEndianFloat(point.g)
            data.appendLittleEndianFloat(point.b)
            data.appendLittleEndianFloat(point.normalX)
            data.appendLittleEndianFloat(point.normalY)
            data.appendLittleEndianFloat(point.normalZ)
            data.appendLittleEndianFloat(point.radius)
        }

        try data.write(to: url, options: .atomic)
    }

    static func write(
        pointCount: Int,
        to url: URL,
        appendPoints: (inout StreamingPointWriter) throws -> Void
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let temporaryURL = url
            .deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp")
        try? FileManager.default.removeItem(at: temporaryURL)
        _ = FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)

        let handle = try FileHandle(forWritingTo: temporaryURL)
        var writer = StreamingPointWriter(handle: handle)
        writer.appendHeader(pointCount: pointCount)
        try appendPoints(&writer)
        writer.close()

        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temporaryURL, to: url)
    }

    static func read(from url: URL) throws -> [SpatialScanOptimizedPoint] {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count >= headerByteCount,
              data.littleEndianUInt32(at: 0) == magic else {
            throw SpatialScanOptimizedPointCloudError.invalidData
        }
        guard let fileVersion = data.littleEndianUInt32(at: 4),
              fileVersion == 1 || fileVersion == version else {
            throw SpatialScanOptimizedPointCloudError.unsupportedVersion
        }
        guard let declaredCount = data.littleEndianUInt32(at: 8) else {
            throw SpatialScanOptimizedPointCloudError.invalidData
        }

        let pointCount = Int(declaredCount)
        let pointStride = fileVersion == 1 ? legacyBytesPerPoint : bytesPerPoint
        let expectedByteCount = headerByteCount + (pointCount * pointStride)
        guard data.count >= expectedByteCount else {
            throw SpatialScanOptimizedPointCloudError.invalidData
        }

        var points: [SpatialScanOptimizedPoint] = []
        points.reserveCapacity(pointCount)
        var offset = headerByteCount
        for _ in 0..<pointCount {
            guard
                let x = data.littleEndianFloat(at: offset),
                let y = data.littleEndianFloat(at: offset + 4),
                let z = data.littleEndianFloat(at: offset + 8),
                let r = data.littleEndianFloat(at: offset + 12),
                let g = data.littleEndianFloat(at: offset + 16),
                let b = data.littleEndianFloat(at: offset + 20)
            else {
                throw SpatialScanOptimizedPointCloudError.invalidData
            }
            let normalX: Float
            let normalY: Float
            let normalZ: Float
            let radius: Float
            if fileVersion == 1 {
                normalX = 0
                normalY = 1
                normalZ = 0
                radius = 0.022
            } else {
                guard let decodedNormalX = data.littleEndianFloat(at: offset + 24),
                      let decodedNormalY = data.littleEndianFloat(at: offset + 28),
                      let decodedNormalZ = data.littleEndianFloat(at: offset + 32),
                      let decodedRadius = data.littleEndianFloat(at: offset + 36) else {
                    throw SpatialScanOptimizedPointCloudError.invalidData
                }
                normalX = decodedNormalX
                normalY = decodedNormalY
                normalZ = decodedNormalZ
                radius = decodedRadius
            }
            points.append(
                SpatialScanOptimizedPoint(
                    x: x,
                    y: y,
                    z: z,
                    r: r,
                    g: g,
                    b: b,
                    normalX: normalX,
                    normalY: normalY,
                    normalZ: normalZ,
                    radius: radius
                )
            )
            offset += pointStride
        }
        return points
    }
}

struct StreamingPointWriter {
    private let handle: FileHandle
    private var buffer = Data()
    private let flushByteCount = 384 * 1_024

    init(handle: FileHandle) {
        self.handle = handle
        buffer.reserveCapacity(flushByteCount + 128)
    }

    mutating func appendHeader(pointCount: Int) {
        buffer.appendLittleEndianUInt32(0x4350_5352)
        buffer.appendLittleEndianUInt32(2)
        buffer.appendLittleEndianUInt32(UInt32(pointCount))
        flushIfNeeded()
    }

    mutating func append(_ point: SpatialScanOptimizedPoint) {
        buffer.appendLittleEndianFloat(point.x)
        buffer.appendLittleEndianFloat(point.y)
        buffer.appendLittleEndianFloat(point.z)
        buffer.appendLittleEndianFloat(point.r)
        buffer.appendLittleEndianFloat(point.g)
        buffer.appendLittleEndianFloat(point.b)
        buffer.appendLittleEndianFloat(point.normalX)
        buffer.appendLittleEndianFloat(point.normalY)
        buffer.appendLittleEndianFloat(point.normalZ)
        buffer.appendLittleEndianFloat(point.radius)
        flushIfNeeded()
    }

    mutating func close() {
        flush()
        handle.closeFile()
    }

    private mutating func flushIfNeeded() {
        if buffer.count >= flushByteCount {
            flush()
        }
    }

    private mutating func flush() {
        guard !buffer.isEmpty else { return }
        handle.write(buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}

enum SpatialScanPointCloudOptimizer {
    private static let maximumOptimizedPointCount = 3_600_000
    private static let maximumPhotoSplatPointCount = 6_400_000
    private static let minimumVoxelSize: Float = 0.00042
    private static let outlierTrimRatio = 0.001

    static func optimize(
        pointSamples: [SpatialScanPointSample],
        frameSamples: [SpatialScanFrameSample],
        bundleURL: URL
    ) throws -> SpatialScanPointCloudOptimizationResult {
        let rawPoints = pointSamples.compactMap { sample -> SourcePoint? in
            guard sample.x.isFinite, sample.y.isFinite, sample.z.isFinite else { return nil }
            return SourcePoint(
                position: SIMD3<Float>(sample.x, sample.y, sample.z),
                sourceFrameIndex: sample.sourceFrameIndex,
                color: nil,
                normal: nil,
                radius: nil
            )
        }
        guard !rawPoints.isEmpty else {
            throw SpatialScanOptimizedPointCloudError.noUsablePoints
        }

        let samplers = FrameColorSampler.loadSamplers(frameSamples: frameSamples, bundleURL: bundleURL)
        let trimBounds = expandedTrimBounds(from: rawPoints)
        let targetCount = min(estimatedInputPointCount(rawPointCount: rawPoints.count, samplerCount: samplers.count), maximumOptimizedPointCount)
        var voxelSize = initialVoxelSize(for: trimBounds, targetCount: targetCount)
        var voxels = voxelDownsample(
            rawPoints: rawPoints,
            samplers: samplers,
            trimBounds: trimBounds,
            voxelSize: voxelSize
        )

        while voxels.count > maximumOptimizedPointCount {
            voxelSize *= 1.05
            voxels.removeAll(keepingCapacity: false)
            voxels = voxelDownsample(
                rawPoints: rawPoints,
                samplers: samplers,
                trimBounds: trimBounds,
                voxelSize: voxelSize
            )
        }

        let outputURL = bundleURL.appendingPathComponent(SpatialScanOptimizedPointCloud.relativePath)
        try writeColorizedPoints(
            from: voxels.values,
            pointCount: voxels.count,
            to: outputURL,
            samplers: samplers,
            splatRadius: max(voxelSize * 0.68, 0.0028)
        )
        return SpatialScanPointCloudOptimizationResult(
            relativePath: SpatialScanOptimizedPointCloud.relativePath,
            pointCount: voxels.count
        )
    }

    fileprivate struct SourcePoint {
        let position: SIMD3<Float>
        let sourceFrameIndex: Int?
        let color: SIMD3<Float>?
        let normal: SIMD3<Float>?
        let radius: Float?
    }

    private struct Bounds {
        var min: SIMD3<Float>
        var max: SIMD3<Float>
    }

    private struct VoxelKey: Hashable {
        let x: Int
        let y: Int
        let z: Int
    }

    private struct VoxelAccumulator {
        var sum = SIMD3<Float>(repeating: 0)
        var normalSum = SIMD3<Float>(repeating: 0)
        var colorSum = SIMD3<Float>(repeating: 0)
        var radiusSum: Float = 0
        var count = 0
        var normalCount = 0
        var colorCount = 0
        var radiusCount = 0
        var sourceFrameIndex: Int?

        mutating func add(_ point: SourcePoint) {
            sum += point.position
            count += 1
            if let color = point.color {
                colorSum += color
                colorCount += 1
            }
            if let normal = point.normal {
                normalSum += normal
                normalCount += 1
            }
            if let radius = point.radius {
                radiusSum += radius
                radiusCount += 1
            }
            if sourceFrameIndex == nil || point.color != nil {
                sourceFrameIndex = point.sourceFrameIndex
            }
        }

        var point: SourcePoint {
            guard count > 0 else {
                return SourcePoint(
                    position: sum,
                    sourceFrameIndex: sourceFrameIndex,
                    color: nil,
                    normal: nil,
                    radius: nil
                )
            }
            return SourcePoint(
                position: sum / Float(count),
                sourceFrameIndex: sourceFrameIndex,
                color: colorCount > 0 ? colorSum / Float(colorCount) : nil,
                normal: normalCount > 0 ? normalized(normalSum / Float(normalCount), fallback: SIMD3<Float>(0, 1, 0)) : nil,
                radius: radiusCount > 0 ? radiusSum / Float(radiusCount) : nil
            )
        }
    }

    private static func expandedTrimBounds(from points: [SourcePoint]) -> Bounds {
        let positions = points.map(\.position)
        guard positions.count >= 80 else {
            return padded(bounds: bounds(for: positions), fraction: 0.1, minimumPadding: 0.18)
        }

        let sortedX = positions.map(\.x).sorted()
        let sortedY = positions.map(\.y).sorted()
        let sortedZ = positions.map(\.z).sorted()
        let lowerIndex = max(Int(Double(positions.count - 1) * outlierTrimRatio), 0)
        let upperIndex = min(Int(Double(positions.count - 1) * (1 - outlierTrimRatio)), positions.count - 1)
        let lower = SIMD3<Float>(sortedX[lowerIndex], sortedY[lowerIndex], sortedZ[lowerIndex])
        let upper = SIMD3<Float>(sortedX[upperIndex], sortedY[upperIndex], sortedZ[upperIndex])
        return padded(bounds: Bounds(min: lower, max: upper), fraction: 0.12, minimumPadding: 0.22)
    }

    private static func padded(bounds: Bounds, fraction: Float, minimumPadding: Float) -> Bounds {
        let span = bounds.max - bounds.min
        let padding = SIMD3<Float>(
            max(span.x * fraction, minimumPadding),
            max(span.y * fraction, minimumPadding),
            max(span.z * fraction, minimumPadding)
        )
        return Bounds(min: bounds.min - padding, max: bounds.max + padding)
    }

    private static func contains(_ point: SourcePoint, in bounds: Bounds) -> Bool {
        let position = point.position
        return position.x >= bounds.min.x && position.x <= bounds.max.x
            && position.y >= bounds.min.y && position.y <= bounds.max.y
            && position.z >= bounds.min.z && position.z <= bounds.max.z
    }

    private static func initialVoxelSize(for bounds: Bounds, targetCount: Int) -> Float {
        let rawExtent = bounds.max - bounds.min
        let extent = SIMD3<Float>(
            Swift.max(rawExtent.x, 0.2),
            Swift.max(rawExtent.y, 0.2),
            Swift.max(rawExtent.z, 0.2)
        )
        let volume = max(Double(extent.x * extent.y * extent.z), 0.001)
        let pointVolume = volume / Double(max(targetCount, 1))
        let edge = Float(pow(pointVolume, 1.0 / 3.0))
        return max(edge * 0.17, minimumVoxelSize)
    }

    private static func estimatedInputPointCount(rawPointCount: Int, samplerCount: Int) -> Int {
        rawPointCount + min(maximumPhotoSplatPointCount, samplerCount * photoSplatBudget(samplerCount: samplerCount))
    }

    private static func photoSplatBudget(samplerCount: Int) -> Int {
        max(maximumPhotoSplatPointCount / max(samplerCount, 1), 14_000)
    }

    private static func voxelDownsample(
        rawPoints: [SourcePoint],
        samplers: [FrameColorSampler],
        trimBounds: Bounds,
        voxelSize: Float
    ) -> [VoxelKey: VoxelAccumulator] {
        var voxels: [VoxelKey: VoxelAccumulator] = [:]
        voxels.reserveCapacity(min(estimatedInputPointCount(rawPointCount: rawPoints.count, samplerCount: samplers.count), maximumOptimizedPointCount))

        for point in rawPoints where contains(point, in: trimBounds) {
            add(point, to: &voxels, voxelSize: voxelSize)
        }

        let perFrameBudget = photoSplatBudget(samplerCount: samplers.count)
        var photoPointCount = 0
        for sampler in samplers {
            guard photoPointCount < maximumPhotoSplatPointCount else { break }
            let remainingBudget = maximumPhotoSplatPointCount - photoPointCount
            let frameBudget = min(perFrameBudget, remainingBudget)
            let photoPoints = autoreleasepool {
                sampler.photoSplatPoints(
                    anchorPoints: rawPoints,
                    maximumCount: frameBudget
                )
            }
            for point in photoPoints where contains(point, in: trimBounds) {
                add(point, to: &voxels, voxelSize: voxelSize)
            }
            photoPointCount += photoPoints.count
            sampler.releaseImage()
        }

        return voxels
    }

    private static func add(
        _ point: SourcePoint,
        to voxels: inout [VoxelKey: VoxelAccumulator],
        voxelSize: Float
    ) {
        let position = point.position
        let key = VoxelKey(
            x: Int(floor(position.x / voxelSize)),
            y: Int(floor(position.y / voxelSize)),
            z: Int(floor(position.z / voxelSize))
        )
        var accumulator = voxels[key] ?? VoxelAccumulator()
        accumulator.add(point)
        voxels[key] = accumulator
    }

    private static func writeColorizedPoints(
        from accumulators: Dictionary<VoxelKey, VoxelAccumulator>.Values,
        pointCount: Int,
        to url: URL,
        samplers: [FrameColorSampler],
        splatRadius: Float
    ) throws {
        let pointBounds = bounds(for: accumulators)
        let center = (pointBounds.min + pointBounds.max) / 2
        let heightRange = max(pointBounds.max.y - pointBounds.min.y, 0.01)
        let radius = max(radius(for: accumulators, center: center), 0.01)

        try SpatialScanOptimizedPointCloud.write(pointCount: pointCount, to: url) { writer in
            for accumulator in accumulators {
                writer.append(
                    colorizedPoint(
                        from: accumulator.point,
                        bounds: pointBounds,
                        center: center,
                        heightRange: heightRange,
                        radius: radius,
                        splatRadius: splatRadius
                    )
                )
            }
        }
        samplers.forEach { $0.releaseImage() }
    }

    private static func colorizedPoint(
        from point: SourcePoint,
        bounds: Bounds,
        center: SIMD3<Float>,
        heightRange: Float,
        radius: Float,
        splatRadius: Float
    ) -> SpatialScanOptimizedPoint {
        let position = point.position
        let sampledPhotoColor = point.color
        let height = min(max((position.y - bounds.min.y) / heightRange, 0), 1)
        let radial = min(max(simd_length(position - center) / radius, 0), 1)
        let edgeContrast = 1 - abs(radial - 0.55)
        let fallbackColor = SIMD3<Float>(
            min(0.26 + (height * 0.5) + (edgeContrast * 0.12), 1),
            min(0.42 + ((1 - radial) * 0.28) + (height * 0.16), 1),
            min(0.72 + ((1 - height) * 0.2) + (radial * 0.08), 1)
        )
        let color = sampledPhotoColor ?? fallbackColor
        let normal = point.normal ?? normalized(position - center, fallback: SIMD3<Float>(0, 1, 0))
        return SpatialScanOptimizedPoint(
            x: position.x,
            y: position.y,
            z: position.z,
            r: color.x,
            g: color.y,
            b: color.z,
            normalX: normal.x,
            normalY: normal.y,
            normalZ: normal.z,
            radius: point.radius ?? splatRadius
        )
    }

    private static func bounds(for positions: [SIMD3<Float>]) -> Bounds {
        guard var minimum = positions.first else {
            return Bounds(min: .zero, max: .zero)
        }
        var maximum = minimum

        for position in positions.dropFirst() {
            minimum = SIMD3<Float>(
                Swift.min(minimum.x, position.x),
                Swift.min(minimum.y, position.y),
                Swift.min(minimum.z, position.z)
            )
            maximum = SIMD3<Float>(
                Swift.max(maximum.x, position.x),
                Swift.max(maximum.y, position.y),
                Swift.max(maximum.z, position.z)
            )
        }

        return Bounds(min: minimum, max: maximum)
    }

    private static func bounds(for accumulators: Dictionary<VoxelKey, VoxelAccumulator>.Values) -> Bounds {
        var iterator = accumulators.makeIterator()
        guard let first = iterator.next()?.point.position else {
            return Bounds(min: .zero, max: .zero)
        }

        var minimum = first
        var maximum = first
        while let position = iterator.next()?.point.position {
            minimum = SIMD3<Float>(
                Swift.min(minimum.x, position.x),
                Swift.min(minimum.y, position.y),
                Swift.min(minimum.z, position.z)
            )
            maximum = SIMD3<Float>(
                Swift.max(maximum.x, position.x),
                Swift.max(maximum.y, position.y),
                Swift.max(maximum.z, position.z)
            )
        }
        return Bounds(min: minimum, max: maximum)
    }

    private static func radius(
        for accumulators: Dictionary<VoxelKey, VoxelAccumulator>.Values,
        center: SIMD3<Float>
    ) -> Float {
        var maximumRadius: Float = 0
        for accumulator in accumulators {
            maximumRadius = max(maximumRadius, simd_length(accumulator.point.position - center))
        }
        return maximumRadius
    }

}

private func normalized(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
    let length = simd_length(vector)
    guard length > 0.0001 else { return fallback }
    return vector / length
}

private final class FrameColorSampler {
    private static let maximumLoadedFrameCount = 256
    private static let maximumColorImageDimension = 3_072
    private static let maximumProjectedAnchorCount = 420_000

    let frameIndex: Int
    private let cameraTransform: simd_float4x4
    private let inverseCameraTransform: simd_float4x4
    private let fx: Float
    private let fy: Float
    private let cx: Float
    private let cy: Float
    private let imageURL: URL
    private let originalImageWidth: Int
    private let originalImageHeight: Int
    private var intrinsicScaleX: Float
    private var intrinsicScaleY: Float
    private var width: Int
    private var height: Int
    private var pixels: [UInt8]?

    private init?(
        frameIndex: Int,
        frameSample: SpatialScanFrameSample,
        imageURL: URL
    ) {
        guard
            let cameraTransform = Self.matrix4x4(from: frameSample.cameraTransform),
            let intrinsics = Self.cameraIntrinsics(from: frameSample.cameraIntrinsics),
            FileManager.default.fileExists(atPath: imageURL.path)
        else {
            return nil
        }

        self.frameIndex = frameIndex
        self.cameraTransform = cameraTransform
        inverseCameraTransform = cameraTransform.inverse
        self.imageURL = imageURL
        fx = intrinsics.fx
        fy = intrinsics.fy
        cx = intrinsics.cx
        cy = intrinsics.cy
        originalImageWidth = max(frameSample.imageWidth, 1)
        originalImageHeight = max(frameSample.imageHeight, 1)

        let scale = min(
            1,
            Float(Self.maximumColorImageDimension) / Float(max(originalImageWidth, originalImageHeight, 1))
        )
        width = max(Int((Float(originalImageWidth) * scale).rounded()), 1)
        height = max(Int((Float(originalImageHeight) * scale).rounded()), 1)
        intrinsicScaleX = Float(width) / Float(originalImageWidth)
        intrinsicScaleY = Float(height) / Float(originalImageHeight)
        pixels = nil
    }

    static func loadSamplers(frameSamples: [SpatialScanFrameSample], bundleURL: URL) -> [FrameColorSampler] {
        representativeFrameIndices(totalCount: frameSamples.count, targetCount: maximumLoadedFrameCount).compactMap { index in
            guard frameSamples.indices.contains(index) else { return nil }
            let sample = frameSamples[index]
            guard let imageURL = SpatialScanAssetResolver.assetURL(relativePath: sample.imageFileName, in: bundleURL) else {
                return nil
            }
            return FrameColorSampler(frameIndex: index, frameSample: sample, imageURL: imageURL)
        }
    }

    func photoSplatPoints(
        anchorPoints: [SpatialScanPointCloudOptimizer.SourcePoint],
        maximumCount: Int
    ) -> [SpatialScanPointCloudOptimizer.SourcePoint] {
        guard maximumCount > 0, !anchorPoints.isEmpty else { return [] }
        guard ensureImageLoaded() else { return [] }

        let imageAspect = Float(width) / Float(max(height, 1))
        let targetCellCount = min(max(maximumCount, 7_200), 54_000)
        let gridColumns = min(max(Int(sqrt(Float(targetCellCount) * imageAspect)), 96), 340)
        let gridRows = min(max(Int(Float(gridColumns) / imageAspect), 64), 256)
        let cellWidth = Float(width) / Float(gridColumns)
        let cellHeight = Float(height) / Float(gridRows)
        var cells = [DepthCell](repeating: DepthCell(), count: gridColumns * gridRows)

        let anchorStride = max(anchorPoints.count / Self.maximumProjectedAnchorCount, 1)
        for index in stride(from: 0, to: anchorPoints.count, by: anchorStride) {
            let anchor = anchorPoints[index]
            guard let projection = project(anchor.position),
                  projection.depth >= 0.14,
                  projection.depth <= 14.0 else {
                continue
            }
            let column = min(max(Int(projection.pixel.x / cellWidth), 0), gridColumns - 1)
            let row = min(max(Int(projection.pixel.y / cellHeight), 0), gridRows - 1)
            cells[(row * gridColumns) + column].add(depth: projection.depth)
        }

        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        var splats: [SpatialScanPointCloudOptimizer.SourcePoint] = []
        splats.reserveCapacity(min(maximumCount, cells.count))

        for row in 0..<gridRows {
            for column in 0..<gridColumns {
                guard splats.count < maximumCount,
                      let depthSample = resolvedDepth(
                        forColumn: column,
                        row: row,
                        cells: cells,
                        columns: gridColumns,
                        rows: gridRows
                      ) else {
                    continue
                }

                let pixel = SIMD2<Float>(
                    (Float(column) + 0.5) * cellWidth,
                    (Float(row) + 0.5) * cellHeight
                )
                guard let color = colorAt(pixel: pixel),
                      let worldPosition = unproject(pixel: pixel, depth: depthSample.depth) else {
                    continue
                }

                let worldCellWidth = depthSample.depth * (cellWidth / max(fx * intrinsicScaleX, 1))
                let worldCellHeight = depthSample.depth * (cellHeight / max(fy * intrinsicScaleY, 1))
                let confidence = min(max(depthSample.confidence, 0.38), 1)
                let radiusScale = 0.58 + (confidence * 0.28)
                let radius = min(max(max(worldCellWidth, worldCellHeight) * 0.54 * radiusScale, 0.0025), 0.04)
                let normal = normalized(cameraPosition - worldPosition, fallback: cameraForward)

                splats.append(
                    SpatialScanPointCloudOptimizer.SourcePoint(
                        position: worldPosition,
                        sourceFrameIndex: frameIndex,
                        color: color,
                        normal: normal,
                        radius: radius
                    )
                )
            }
        }

        return splats
    }

    func releaseImage() {
        pixels = nil
    }

    @discardableResult
    private func ensureImageLoaded() -> Bool {
        if pixels != nil {
            return true
        }
        guard let image = Self.loadRGBAImage(at: imageURL) else {
            return false
        }
        width = image.width
        height = image.height
        intrinsicScaleX = Float(image.width) / Float(originalImageWidth)
        intrinsicScaleY = Float(image.height) / Float(originalImageHeight)
        pixels = image.pixels
        return true
    }

    private var cameraForward: SIMD3<Float> {
        normalized(
            SIMD3<Float>(
                -cameraTransform.columns.2.x,
                -cameraTransform.columns.2.y,
                -cameraTransform.columns.2.z
            ),
            fallback: SIMD3<Float>(0, 0, -1)
        )
    }

    private struct Projection {
        let pixel: SIMD2<Float>
        let depth: Float
    }

    private struct DepthSample {
        let depth: Float
        let confidence: Float
    }

    private struct DepthCell {
        var depthSum: Float = 0
        var depthSquaredSum: Float = 0
        var nearestDepth: Float = .greatestFiniteMagnitude
        var count: Int = 0

        mutating func add(depth: Float) {
            depthSum += depth
            depthSquaredSum += depth * depth
            nearestDepth = min(nearestDepth, depth)
            count += 1
        }

        var resolvedSample: DepthSample? {
            guard count > 0 else { return nil }
            let mean = depthSum / Float(count)
            let variance = max((depthSquaredSum / Float(count)) - (mean * mean), 0)
            let standardDeviation = sqrt(variance)
            let stability = max(0.28, 1 - min(standardDeviation / max(mean * 0.08, 0.01), 0.72))
            let density = min(Float(log2(Double(count) + 1) / 4.0), 1)
            let resolvedDepth = (mean * 0.72) + (nearestDepth * 0.28)
            return DepthSample(depth: resolvedDepth, confidence: min(max(stability * density, 0.24), 1))
        }
    }

    private func project(_ worldPosition: SIMD3<Float>) -> Projection? {
        let cameraPoint4 = inverseCameraTransform * SIMD4<Float>(
            worldPosition.x,
            worldPosition.y,
            worldPosition.z,
            1
        )
        let depth = -cameraPoint4.z
        guard depth > 0.05 else { return nil }

        let projectedX = ((fx * (cameraPoint4.x / depth)) + cx) * intrinsicScaleX
        let projectedY = ((fy * (-cameraPoint4.y / depth)) + cy) * intrinsicScaleY
        guard projectedX.isFinite, projectedY.isFinite else { return nil }

        guard projectedX >= 0, projectedX < Float(width),
              projectedY >= 0, projectedY < Float(height) else {
            return nil
        }

        return Projection(pixel: SIMD2<Float>(projectedX, projectedY), depth: depth)
    }

    private func unproject(pixel: SIMD2<Float>, depth: Float) -> SIMD3<Float>? {
        guard depth.isFinite, depth > 0 else { return nil }
        let originalX = pixel.x / max(intrinsicScaleX, 0.0001)
        let originalY = pixel.y / max(intrinsicScaleY, 0.0001)
        let cameraX = ((originalX - cx) / max(fx, 0.0001)) * depth
        let cameraY = -((originalY - cy) / max(fy, 0.0001)) * depth
        let cameraPoint = SIMD4<Float>(cameraX, cameraY, -depth, 1)
        let worldPoint = cameraTransform * cameraPoint
        guard worldPoint.x.isFinite, worldPoint.y.isFinite, worldPoint.z.isFinite else { return nil }
        return SIMD3<Float>(worldPoint.x, worldPoint.y, worldPoint.z)
    }

    private func colorAt(pixel: SIMD2<Float>) -> SIMD3<Float>? {
        guard ensureImageLoaded() else { return nil }
        guard width > 0, height > 0 else { return nil }
        let clampedX = min(max(pixel.x, 0), Float(width - 1))
        let clampedY = min(max(pixel.y, 0), Float(height - 1))
        let x0 = min(max(Int(floor(clampedX)), 0), width - 1)
        let y0 = min(max(Int(floor(clampedY)), 0), height - 1)
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let tx = clampedX - Float(x0)
        let ty = clampedY - Float(y0)

        guard
            let c00 = pixelColor(x: x0, y: y0),
            let c10 = pixelColor(x: x1, y: y0),
            let c01 = pixelColor(x: x0, y: y1),
            let c11 = pixelColor(x: x1, y: y1)
        else {
            return nil
        }

        let top = (c00 * (1 - tx)) + (c10 * tx)
        let bottom = (c01 * (1 - tx)) + (c11 * tx)
        return (top * (1 - ty)) + (bottom * ty)
    }

    private func pixelColor(x: Int, y: Int) -> SIMD3<Float>? {
        guard let pixels else { return nil }
        let offset = ((y * width) + x) * 4
        guard offset + 2 < pixels.count else { return nil }
        return SIMD3<Float>(
            Float(pixels[offset]) / 255,
            Float(pixels[offset + 1]) / 255,
            Float(pixels[offset + 2]) / 255
        )
    }

    private func resolvedDepth(
        forColumn column: Int,
        row: Int,
        cells: [DepthCell],
        columns: Int,
        rows: Int
    ) -> DepthSample? {
        let directIndex = (row * columns) + column
        if cells.indices.contains(directIndex),
           let directSample = cells[directIndex].resolvedSample {
            return directSample
        }

        for radius in 1...2 {
            var weightedDepth: Float = 0
            var weightSum: Float = 0

            for yOffset in -radius...radius {
                for xOffset in -radius...radius {
                    let neighborColumn = column + xOffset
                    let neighborRow = row + yOffset
                    guard neighborColumn >= 0,
                          neighborColumn < columns,
                          neighborRow >= 0,
                          neighborRow < rows else {
                        continue
                    }
                    let neighborIndex = (neighborRow * columns) + neighborColumn
                    guard cells.indices.contains(neighborIndex),
                          let neighborSample = cells[neighborIndex].resolvedSample else {
                        continue
                    }
                    let distance = max(Float(abs(xOffset) + abs(yOffset)), 1)
                    let weight = neighborSample.confidence / distance
                    weightedDepth += neighborSample.depth * weight
                    weightSum += weight
                }
            }

            if weightSum > 0 {
                let confidence = min(max(weightSum / Float((radius * 2 + 1) * (radius * 2 + 1)), 0.24), 1)
                return DepthSample(depth: weightedDepth / weightSum, confidence: radius == 1 ? max(confidence, 0.68) : max(confidence, 0.42))
            }
        }

        return nil
    }

    private struct RGBAImage {
        let width: Int
        let height: Int
        let pixels: [UInt8]
    }

    private static func matrix4x4(from values: [Float]) -> simd_float4x4? {
        guard values.count >= 16 else { return nil }
        return simd_float4x4(
            SIMD4<Float>(values[0], values[1], values[2], values[3]),
            SIMD4<Float>(values[4], values[5], values[6], values[7]),
            SIMD4<Float>(values[8], values[9], values[10], values[11]),
            SIMD4<Float>(values[12], values[13], values[14], values[15])
        )
    }

    private static func cameraIntrinsics(from values: [Float]) -> (fx: Float, fy: Float, cx: Float, cy: Float)? {
        guard values.count >= 9 else { return nil }
        return (fx: values[0], fy: values[4], cx: values[6], cy: values[7])
    }

    private static func loadRGBAImage(at url: URL) -> RGBAImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard
            let imageSource = CGImageSourceCreateWithURL(url as CFURL, options)
        else {
            return nil
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumColorImageDimension
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions)
            ?? CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  ) else {
                return false
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else {
            return nil
        }

        return RGBAImage(width: width, height: height, pixels: pixels)
    }

    private static func representativeFrameIndices(totalCount: Int, targetCount: Int) -> [Int] {
        guard totalCount > 0, targetCount > 0 else { return [] }
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
}

private enum SpatialScanAssetResolver {
    static func assetURL(relativePath: String, in bundleURL: URL) -> URL? {
        guard let normalizedRelativePath = StoredSpatialScan.normalizedRelativeAssetPath(relativePath) else {
            return nil
        }
        let candidateURL = bundleURL.appendingPathComponent(normalizedRelativePath)
        let standardizedBundlePath = bundleURL.standardizedFileURL.path + "/"
        let standardizedCandidatePath = candidateURL.standardizedFileURL.path
        guard standardizedCandidatePath.hasPrefix(standardizedBundlePath) else {
            return nil
        }
        return candidateURL
    }
}

private extension Data {
    mutating func appendLittleEndianUInt32(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }

    mutating func appendLittleEndianFloat(_ value: Float) {
        appendLittleEndianUInt32(value.bitPattern)
    }

    func littleEndianUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        var value: UInt32 = 0
        value |= UInt32(self[offset])
        value |= UInt32(self[offset + 1]) << 8
        value |= UInt32(self[offset + 2]) << 16
        value |= UInt32(self[offset + 3]) << 24
        return value
    }

    func littleEndianFloat(at offset: Int) -> Float? {
        guard let bits = littleEndianUInt32(at: offset) else { return nil }
        return Float(bitPattern: bits)
    }
}

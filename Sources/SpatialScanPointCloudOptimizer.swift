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

enum SpatialScanPointCloudOptimizer {
    private static let maximumOptimizedPointCount = 18_000
    private static let minimumVoxelSize: Float = 0.008
    private static let outlierTrimRatio = 0.02

    static func optimize(
        pointSamples: [SpatialScanPointSample],
        frameSamples: [SpatialScanFrameSample],
        bundleURL: URL
    ) throws -> SpatialScanPointCloudOptimizationResult {
        let rawPoints = pointSamples.compactMap { sample -> SourcePoint? in
            guard sample.x.isFinite, sample.y.isFinite, sample.z.isFinite else { return nil }
            return SourcePoint(
                position: SIMD3<Float>(sample.x, sample.y, sample.z),
                sourceFrameIndex: sample.sourceFrameIndex
            )
        }
        guard !rawPoints.isEmpty else {
            throw SpatialScanOptimizedPointCloudError.noUsablePoints
        }

        let samplers = FrameColorSampler.loadSamplers(frameSamples: frameSamples, bundleURL: bundleURL)
        let samplersByIndex = Dictionary(uniqueKeysWithValues: samplers.map { ($0.frameIndex, $0) })
        let trimmedPoints = trimOutliers(from: rawPoints)
        let targetCount = min(max(trimmedPoints.count, 1), maximumOptimizedPointCount)
        var voxelSize = initialVoxelSize(for: trimmedPoints.map(\.position), targetCount: targetCount)
        var optimizedPoints = voxelDownsample(trimmedPoints, voxelSize: voxelSize)

        while optimizedPoints.count > maximumOptimizedPointCount {
            voxelSize *= 1.16
            optimizedPoints = voxelDownsample(trimmedPoints, voxelSize: voxelSize)
        }

        if optimizedPoints.count > maximumOptimizedPointCount {
            optimizedPoints = representativePoints(
                optimizedPoints,
                targetCount: maximumOptimizedPointCount
            )
        }

        let colorizedPoints = colorizedPoints(
            from: optimizedPoints,
            samplers: samplers,
            samplersByIndex: samplersByIndex,
            splatRadius: max(voxelSize * 1.15, 0.018)
        )
        let outputURL = bundleURL.appendingPathComponent(SpatialScanOptimizedPointCloud.relativePath)
        try SpatialScanOptimizedPointCloud.write(points: colorizedPoints, to: outputURL)
        return SpatialScanPointCloudOptimizationResult(
            relativePath: SpatialScanOptimizedPointCloud.relativePath,
            pointCount: colorizedPoints.count
        )
    }

    private struct SourcePoint {
        let position: SIMD3<Float>
        let sourceFrameIndex: Int?
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
        var count = 0
        var sourceFrameIndex: Int?

        mutating func add(_ point: SourcePoint) {
            sum += point.position
            count += 1
            if sourceFrameIndex == nil {
                sourceFrameIndex = point.sourceFrameIndex
            }
        }

        var point: SourcePoint {
            guard count > 0 else {
                return SourcePoint(position: sum, sourceFrameIndex: sourceFrameIndex)
            }
            return SourcePoint(position: sum / Float(count), sourceFrameIndex: sourceFrameIndex)
        }
    }

    private static func trimOutliers(from points: [SourcePoint]) -> [SourcePoint] {
        guard points.count >= 80 else { return points }
        let positions = points.map(\.position)

        let sortedX = positions.map(\.x).sorted()
        let sortedY = positions.map(\.y).sorted()
        let sortedZ = positions.map(\.z).sorted()
        let lowerIndex = max(Int(Double(positions.count - 1) * outlierTrimRatio), 0)
        let upperIndex = min(Int(Double(positions.count - 1) * (1 - outlierTrimRatio)), positions.count - 1)
        let lower = SIMD3<Float>(sortedX[lowerIndex], sortedY[lowerIndex], sortedZ[lowerIndex])
        let upper = SIMD3<Float>(sortedX[upperIndex], sortedY[upperIndex], sortedZ[upperIndex])

        return points.filter { point in
            let position = point.position
            return position.x >= lower.x && position.x <= upper.x
                && position.y >= lower.y && position.y <= upper.y
                && position.z >= lower.z && position.z <= upper.z
        }
    }

    private static func initialVoxelSize(for positions: [SIMD3<Float>], targetCount: Int) -> Float {
        let bounds = bounds(for: positions)
        let rawExtent = bounds.max - bounds.min
        let extent = SIMD3<Float>(
            Swift.max(rawExtent.x, 0.2),
            Swift.max(rawExtent.y, 0.2),
            Swift.max(rawExtent.z, 0.2)
        )
        let volume = max(Double(extent.x * extent.y * extent.z), 0.001)
        let pointVolume = volume / Double(max(targetCount, 1))
        let edge = Float(pow(pointVolume, 1.0 / 3.0))
        return max(edge * 0.78, minimumVoxelSize)
    }

    private static func voxelDownsample(_ points: [SourcePoint], voxelSize: Float) -> [SourcePoint] {
        guard voxelSize > 0 else { return points }
        var voxels: [VoxelKey: VoxelAccumulator] = [:]
        voxels.reserveCapacity(min(points.count, maximumOptimizedPointCount))

        for point in points {
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

        return voxels.values.map(\.point)
    }

    private static func representativePoints(
        _ points: [SourcePoint],
        targetCount: Int
    ) -> [SourcePoint] {
        guard points.count > targetCount, targetCount > 0 else { return points }
        let denominator = max(targetCount - 1, 1)
        var sampled: [SourcePoint] = []
        sampled.reserveCapacity(targetCount)
        for offset in 0..<targetCount {
            let index = Int(round((Double(offset) / Double(denominator)) * Double(points.count - 1)))
            sampled.append(points[min(max(index, 0), points.count - 1)])
        }
        return sampled
    }

    private static func colorizedPoints(
        from points: [SourcePoint],
        samplers: [FrameColorSampler],
        samplersByIndex: [Int: FrameColorSampler],
        splatRadius: Float
    ) -> [SpatialScanOptimizedPoint] {
        guard !points.isEmpty else { return [] }
        let positions = points.map(\.position)
        let bounds = bounds(for: positions)
        let center = (bounds.min + bounds.max) / 2
        let heightRange = max(bounds.max.y - bounds.min.y, 0.01)
        let radius = max(positions.map { simd_length($0 - center) }.max() ?? 0.01, 0.01)

        var optimizedPoints: [SpatialScanOptimizedPoint] = []
        optimizedPoints.reserveCapacity(points.count)

        for point in points {
            let position = point.position
            let photoColor = sampledColor(
                for: point,
                samplers: samplers,
                samplersByIndex: samplersByIndex
            )
            let height = min(max((position.y - bounds.min.y) / heightRange, 0), 1)
            let radial = min(max(simd_length(position - center) / radius, 0), 1)
            let edgeContrast = 1 - abs(radial - 0.55)
            let fallbackColor = SIMD3<Float>(
                min(0.26 + (height * 0.5) + (edgeContrast * 0.12), 1),
                min(0.42 + ((1 - radial) * 0.28) + (height * 0.16), 1),
                min(0.72 + ((1 - height) * 0.2) + (radial * 0.08), 1)
            )
            let color = photoColor ?? fallbackColor
            let normal = normalized(position - center, fallback: SIMD3<Float>(0, 1, 0))
            optimizedPoints.append(
                SpatialScanOptimizedPoint(
                    x: position.x,
                    y: position.y,
                    z: position.z,
                    r: color.x,
                    g: color.y,
                    b: color.z,
                    normalX: normal.x,
                    normalY: normal.y,
                    normalZ: normal.z,
                    radius: splatRadius
                )
            )
        }

        return optimizedPoints
    }

    private static func sampledColor(
        for point: SourcePoint,
        samplers: [FrameColorSampler],
        samplersByIndex: [Int: FrameColorSampler]
    ) -> SIMD3<Float>? {
        if let sourceFrameIndex = point.sourceFrameIndex,
           let sampler = samplersByIndex[sourceFrameIndex],
           let color = sampler.color(for: point.position) {
            return color
        }

        let candidateSamplers: ArraySlice<FrameColorSampler>
        if let sourceFrameIndex = point.sourceFrameIndex {
            candidateSamplers = samplers
                .sorted { abs($0.frameIndex - sourceFrameIndex) < abs($1.frameIndex - sourceFrameIndex) }
                .prefix(12)
        } else {
            candidateSamplers = samplers.prefix(12)
        }

        for sampler in candidateSamplers {
            if let color = sampler.color(for: point.position) {
                return color
            }
        }
        return nil
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

    private static func normalized(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(vector)
        guard length > 0.0001 else { return fallback }
        return vector / length
    }
}

private final class FrameColorSampler {
    private static let maximumLoadedFrameCount = 48
    private static let maximumColorImageDimension = 1_024

    let frameIndex: Int
    private let inverseCameraTransform: simd_float4x4
    private let fx: Float
    private let fy: Float
    private let cx: Float
    private let cy: Float
    private let intrinsicScaleX: Float
    private let intrinsicScaleY: Float
    private let width: Int
    private let height: Int
    private let pixels: [UInt8]

    private init?(
        frameIndex: Int,
        frameSample: SpatialScanFrameSample,
        imageURL: URL
    ) {
        guard
            let cameraTransform = Self.matrix4x4(from: frameSample.cameraTransform),
            let intrinsics = Self.cameraIntrinsics(from: frameSample.cameraIntrinsics),
            let image = Self.loadRGBAImage(at: imageURL)
        else {
            return nil
        }

        self.frameIndex = frameIndex
        inverseCameraTransform = cameraTransform.inverse
        fx = intrinsics.fx
        fy = intrinsics.fy
        cx = intrinsics.cx
        cy = intrinsics.cy
        width = image.width
        height = image.height
        pixels = image.pixels
        intrinsicScaleX = Float(image.width) / Float(max(frameSample.imageWidth, 1))
        intrinsicScaleY = Float(image.height) / Float(max(frameSample.imageHeight, 1))
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

    func color(for worldPosition: SIMD3<Float>) -> SIMD3<Float>? {
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

        let x = Int(projectedX.rounded())
        let y = Int(projectedY.rounded())
        guard x >= 0, x < width, y >= 0, y < height else { return nil }

        let offset = ((y * width) + x) * 4
        guard offset + 2 < pixels.count else { return nil }
        return SIMD3<Float>(
            Float(pixels[offset]) / 255,
            Float(pixels[offset + 1]) / 255,
            Float(pixels[offset + 2]) / 255
        )
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

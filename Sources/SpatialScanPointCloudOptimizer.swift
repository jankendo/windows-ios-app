import Foundation
import simd

struct SpatialScanOptimizedPoint: Hashable, Sendable {
    let x: Float
    let y: Float
    let z: Float
    let r: Float
    let g: Float
    let b: Float
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
    private static let version: UInt32 = 1
    private static let headerByteCount = 12
    private static let bytesPerPoint = 24

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
        }

        try data.write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> [SpatialScanOptimizedPoint] {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count >= headerByteCount,
              data.littleEndianUInt32(at: 0) == magic else {
            throw SpatialScanOptimizedPointCloudError.invalidData
        }
        guard data.littleEndianUInt32(at: 4) == version else {
            throw SpatialScanOptimizedPointCloudError.unsupportedVersion
        }
        guard let declaredCount = data.littleEndianUInt32(at: 8) else {
            throw SpatialScanOptimizedPointCloudError.invalidData
        }

        let pointCount = Int(declaredCount)
        let expectedByteCount = headerByteCount + (pointCount * bytesPerPoint)
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
            points.append(SpatialScanOptimizedPoint(x: x, y: y, z: z, r: r, g: g, b: b))
            offset += bytesPerPoint
        }
        return points
    }
}

enum SpatialScanPointCloudOptimizer {
    private static let maximumOptimizedPointCount = 8_500
    private static let minimumVoxelSize: Float = 0.012
    private static let outlierTrimRatio = 0.02

    static func optimize(
        pointSamples: [SpatialScanPointSample],
        bundleURL: URL
    ) throws -> SpatialScanPointCloudOptimizationResult {
        let rawPositions = pointSamples.compactMap { sample -> SIMD3<Float>? in
            guard sample.x.isFinite, sample.y.isFinite, sample.z.isFinite else { return nil }
            return SIMD3<Float>(sample.x, sample.y, sample.z)
        }
        guard !rawPositions.isEmpty else {
            throw SpatialScanOptimizedPointCloudError.noUsablePoints
        }

        let trimmedPositions = trimOutliers(from: rawPositions)
        let targetCount = min(max(trimmedPositions.count, 1), maximumOptimizedPointCount)
        var voxelSize = initialVoxelSize(for: trimmedPositions, targetCount: targetCount)
        var optimizedPositions = voxelDownsample(trimmedPositions, voxelSize: voxelSize)

        while optimizedPositions.count > maximumOptimizedPointCount {
            voxelSize *= 1.16
            optimizedPositions = voxelDownsample(trimmedPositions, voxelSize: voxelSize)
        }

        if optimizedPositions.count > maximumOptimizedPointCount {
            optimizedPositions = representativePositions(
                optimizedPositions,
                targetCount: maximumOptimizedPointCount
            )
        }

        let optimizedPoints = colorizedPoints(from: optimizedPositions)
        let outputURL = bundleURL.appendingPathComponent(SpatialScanOptimizedPointCloud.relativePath)
        try SpatialScanOptimizedPointCloud.write(points: optimizedPoints, to: outputURL)
        return SpatialScanPointCloudOptimizationResult(
            relativePath: SpatialScanOptimizedPointCloud.relativePath,
            pointCount: optimizedPoints.count
        )
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

        mutating func add(_ position: SIMD3<Float>) {
            sum += position
            count += 1
        }

        var average: SIMD3<Float> {
            guard count > 0 else { return sum }
            return sum / Float(count)
        }
    }

    private static func trimOutliers(from positions: [SIMD3<Float>]) -> [SIMD3<Float>] {
        guard positions.count >= 80 else { return positions }

        let sortedX = positions.map(\.x).sorted()
        let sortedY = positions.map(\.y).sorted()
        let sortedZ = positions.map(\.z).sorted()
        let lowerIndex = max(Int(Double(positions.count - 1) * outlierTrimRatio), 0)
        let upperIndex = min(Int(Double(positions.count - 1) * (1 - outlierTrimRatio)), positions.count - 1)
        let lower = SIMD3<Float>(sortedX[lowerIndex], sortedY[lowerIndex], sortedZ[lowerIndex])
        let upper = SIMD3<Float>(sortedX[upperIndex], sortedY[upperIndex], sortedZ[upperIndex])

        return positions.filter { position in
            position.x >= lower.x && position.x <= upper.x
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

    private static func voxelDownsample(_ positions: [SIMD3<Float>], voxelSize: Float) -> [SIMD3<Float>] {
        guard voxelSize > 0 else { return positions }
        var voxels: [VoxelKey: VoxelAccumulator] = [:]
        voxels.reserveCapacity(min(positions.count, maximumOptimizedPointCount))

        for position in positions {
            let key = VoxelKey(
                x: Int(floor(position.x / voxelSize)),
                y: Int(floor(position.y / voxelSize)),
                z: Int(floor(position.z / voxelSize))
            )
            var accumulator = voxels[key] ?? VoxelAccumulator()
            accumulator.add(position)
            voxels[key] = accumulator
        }

        return voxels.values.map(\.average)
    }

    private static func representativePositions(
        _ positions: [SIMD3<Float>],
        targetCount: Int
    ) -> [SIMD3<Float>] {
        guard positions.count > targetCount, targetCount > 0 else { return positions }
        let denominator = max(targetCount - 1, 1)
        var sampled: [SIMD3<Float>] = []
        sampled.reserveCapacity(targetCount)
        for offset in 0..<targetCount {
            let index = Int(round((Double(offset) / Double(denominator)) * Double(positions.count - 1)))
            sampled.append(positions[min(max(index, 0), positions.count - 1)])
        }
        return sampled
    }

    private static func colorizedPoints(from positions: [SIMD3<Float>]) -> [SpatialScanOptimizedPoint] {
        guard !positions.isEmpty else { return [] }
        let bounds = bounds(for: positions)
        let center = (bounds.min + bounds.max) / 2
        let heightRange = max(bounds.max.y - bounds.min.y, 0.01)
        let radius = max(positions.map { simd_length($0 - center) }.max() ?? 0.01, 0.01)

        var points: [SpatialScanOptimizedPoint] = []
        points.reserveCapacity(positions.count)

        for position in positions {
            let height = min(max((position.y - bounds.min.y) / heightRange, 0), 1)
            let radial = min(max(simd_length(position - center) / radius, 0), 1)
            let edgeContrast = 1 - abs(radial - 0.55)
            let red = min(0.26 + (height * 0.5) + (edgeContrast * 0.12), 1)
            let green = min(0.42 + ((1 - radial) * 0.28) + (height * 0.16), 1)
            let blue = min(0.72 + ((1 - height) * 0.2) + (radial * 0.08), 1)
            points.append(
                SpatialScanOptimizedPoint(
                    x: position.x,
                    y: position.y,
                    z: position.z,
                    r: red,
                    g: green,
                    b: blue
                )
            )
        }

        return points
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

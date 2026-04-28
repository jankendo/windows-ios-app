import SwiftUI
import UIKit
import ARKit
import ImageIO
import SceneKit
import CoreMotion

struct SpatialScanPlaybackView: View {
    private enum PlaybackImageSizing {
        static let thumbnailMaxDimension: CGFloat = 420
        static let maximumLoadedFrameCount = 16
        static let maximumPointPreviewCount = 60_000
    }

    let entry: MemoryEntry

    @State private var cachedStoredSpatialScan: StoredSpatialScan?
    @State private var cachedManifest: SpatialScanManifest?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var player = AudioPlayerController()
    @State private var waveformSamples: [CGFloat] = Array(repeating: 0.25, count: 40)
    @State private var frameItems: [SpatialScanPlaybackFrame] = []
    @State private var pointItems: [SpatialScanOptimizedPoint] = []
    @State private var selectedFrameIndex = 0
    @State private var isSequencePlaying = false
    @State private var framePlaybackTask: Task<Void, Never>?

    init(entry: MemoryEntry) {
        self.entry = entry
        let storedSpatialScan = entry.atmosphereMetadata?.storedSpatialScan
        _cachedStoredSpatialScan = State(initialValue: storedSpatialScan)
    }

    private var palette: ResonancePalette {
        ResonancePalette.make(for: colorScheme, atmosphere: entry.atmosphereStyle)
    }

    private var storedSpatialScan: StoredSpatialScan? {
        cachedStoredSpatialScan
    }

    private var manifest: SpatialScanManifest? {
        cachedManifest
    }

    private var worldMapURL: URL? {
        guard let storedSpatialScan else { return nil }
        return MediaStore.spatialScanWorldMapURL(for: storedSpatialScan)
    }

    private var playbackURL: URL? {
        entry.analysisAudioURL ?? entry.audioURL
    }

    private var currentFrame: SpatialScanPlaybackFrame? {
        guard frameItems.indices.contains(selectedFrameIndex) else { return nil }
        return frameItems[selectedFrameIndex]
    }

    private var sequencePlaybackInterval: TimeInterval {
        guard frameItems.count > 1 else { return 0.45 }
        let referenceDuration = max(
            spatialScanCaptureDuration ?? manifest?.normalizedCaptureDuration ?? Double(frameItems.count) * 0.35,
            Double(frameItems.count) * 0.12
        )
        return min(max(referenceDuration / Double(frameItems.count), 0.16), 0.65)
    }

    private var audioDuration: TimeInterval {
        max(player.duration, entry.audioDuration)
    }

    private var syncableBytesText: String {
        formattedByteCount(for: spatialScanSyncMetadata?.syncableAssets ?? [])
    }

    private var localOnlyBytesText: String {
        formattedByteCount(for: spatialScanSyncMetadata?.localOnlyAssets ?? [])
    }

    private var spatialScanSyncMetadata: SpatialScanSyncMetadata? {
        entry.atmosphereMetadata?.spatialScanSync
    }

    private var spatialScanFrameCount: Int {
        storedSpatialScan?.frameCount ?? entry.atmosphereMetadata?.storedSpatialScan?.frameCount ?? 0
    }

    private var spatialScanCaptureDuration: TimeInterval? {
        storedSpatialScan?.captureDuration ?? entry.atmosphereMetadata?.storedSpatialScan?.captureDuration
    }

    private var spatialScanReconstructionState: SpatialScanReconstructionState? {
        storedSpatialScan?.reconstructionState ?? entry.atmosphereMetadata?.storedSpatialScan?.reconstructionState
    }

    private var spatialScanDerivedAssets: [SpatialScanSyncAsset] {
        spatialScanSyncMetadata?.assets.filter { $0.kind == .derived } ?? []
    }

    private var spatialScanDisplayLabel: String {
        switch spatialScanReconstructionState {
        case .proxyReady:
            return "Preview対応"
        case .queuedForHighQuality:
            return "HQ準備"
        case .ready:
            return "再生対応"
        case .failed:
            return "再処理待ち"
        case .captured, nil:
            return "3D Scan"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ResonanceGradientBackground(atmosphere: entry.atmosphereStyle)

                ScrollView {
                    VStack(spacing: 18) {
                        spatialModelHero(height: max(geometry.size.height + geometry.safeAreaInsets.top, 560))

                        VStack(alignment: .leading, spacing: 18) {
                            scrubberCard
                            reconstructionCard
                            assetCard
                        }
                        .padding(.horizontal, 20)
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .navigationTitle("3Dスキャン")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadScanResources()
        }
        .onDisappear {
            stopPlayback()
        }
    }

    private func spatialModelHero(height: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            SpatialScanModelPreviewView(
                frames: frameItems,
                pointSamples: pointItems,
                selectedFrameIndex: $selectedFrameIndex,
                motionEnabled: !reduceMotion,
                atmosphere: entry.atmosphereStyle
            )
            .frame(height: height)
            .background(Color.black)

            LinearGradient(
                colors: [Color.black.opacity(0.08), .clear, Color.black.opacity(0.78)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ResonanceBadge(
                            title: spatialScanDisplayLabel,
                            systemImage: "cube",
                            tint: .white,
                            atmosphere: entry.atmosphereStyle
                        )
                        ResonanceBadge(
                            title: reduceMotion ? "固定視点" : "端末で360確認",
                            systemImage: reduceMotion ? "viewfinder" : "gyroscope",
                            tint: .white,
                            atmosphere: entry.atmosphereStyle
                        )
                        if worldMapURL != nil {
                            ResonanceBadge(
                                title: "World Map",
                                systemImage: "globe.asia.australia.fill",
                                tint: .white,
                                atmosphere: entry.atmosphereStyle
                            )
                        }
                        if !pointItems.isEmpty {
                            ResonanceBadge(
                                title: "\(pointItems.count) photo splats",
                                systemImage: "sparkle.magnifyingglass",
                                tint: .white,
                                atmosphere: entry.atmosphereStyle
                            )
                        }
                        if player.isSpatialPlaybackActive {
                            ResonanceBadge(
                                title: "空間音声",
                                systemImage: "dot.radiowaves.left.and.right",
                                tint: .white,
                                atmosphere: entry.atmosphereStyle
                            )
                        }
                    }
                }
                .lineLimit(1)

                Text(entry.displayTitle)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Text(frameOverlaySubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.86))

                heroPlaybackControls
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 22)
        }
    }

    private var heroPlaybackControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    toggleSequencePlayback()
                } label: {
                    Label(
                        isSequencePlaying ? "停止" : "再生",
                        systemImage: isSequencePlaying ? "pause.fill" : "play.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .disabled(frameItems.count < 2)

                if let playbackURL {
                    Button {
                        player.togglePlayback(for: playbackURL)
                    } label: {
                        Label(
                            player.isPlaying ? "音停止" : "音再生",
                            systemImage: player.isPlaying ? "waveform.circle.fill" : "waveform.circle"
                        )
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
            }

            if playbackURL != nil {
                AudioWaveformView(
                    samples: waveformSamples,
                    progress: audioDuration > 0 ? player.currentTime / audioDuration : 0,
                    activeColor: .white,
                    inactiveColor: .white.opacity(0.22),
                    minimumBarHeight: 8
                )
                .frame(height: 24)
            }
        }
    }

    private var scrubberCard: some View {
        ResonanceCard(atmosphere: entry.atmosphereStyle) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("フレームシーケンス")
                        .font(.headline)
                        .foregroundStyle(palette.primaryText)
                    Spacer()
                    Text("\(min(selectedFrameIndex + 1, max(frameItems.count, 1))) / \(max(frameItems.count, 1))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.secondaryText)
                }

                Text("撮影時の方位と上下角から frame を360度に配置し、端末の向きに合わせて見返せます。")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)

                if frameItems.count > 1 {
                    Slider(
                        value: Binding(
                            get: { Double(selectedFrameIndex) },
                            set: { newValue in
                                selectedFrameIndex = min(max(Int(newValue.rounded()), 0), frameItems.count - 1)
                            }
                        ),
                        in: 0...Double(frameItems.count - 1),
                        step: 1
                    )
                    .tint(palette.accent)
                }

                HStack(spacing: 16) {
                    SpatialScanMetricPill(
                        title: "時刻",
                        value: currentFrame.map { String(format: "%.1f 秒", $0.sample.timeOffset) } ?? "0.0 秒",
                        atmosphere: entry.atmosphereStyle
                    )
                    if let heading = currentFrame?.sample.headingDegrees ?? manifest?.anchorHeadingDegrees {
                        SpatialScanMetricPill(
                            title: "方角",
                            value: String(format: "%.0f°", heading),
                            atmosphere: entry.atmosphereStyle
                        )
                    }
                    if let currentFrame {
                        SpatialScanMetricPill(
                            title: "解像度",
                            value: "\(currentFrame.sample.imageWidth)×\(currentFrame.sample.imageHeight)",
                            atmosphere: entry.atmosphereStyle
                        )
                    }
                }

                if frameItems.isEmpty {
                    Text("frame asset を読み込めなかったため、bundle preview のみ表示しています。")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(frameItems) { frame in
                                Button {
                                    selectedFrameIndex = frame.index
                                } label: {
                                    Image(uiImage: frame.thumbnail)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 88, height: 68)
                                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                .strokeBorder(
                                                    frame.index == selectedFrameIndex ? palette.accent : Color.white.opacity(colorScheme == .dark ? 0.08 : 0.2),
                                                    lineWidth: frame.index == selectedFrameIndex ? 2 : 1
                                                )
                                        }
                                        .overlay(alignment: .bottomTrailing) {
                                            Text("\(frame.index + 1)")
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(.white)
                                                .padding(6)
                                                .background(.black.opacity(0.42), in: Capsule())
                                                .padding(8)
                                        }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private var reconstructionCard: some View {
        ResonanceCard(atmosphere: entry.atmosphereStyle) {
            VStack(alignment: .leading, spacing: 12) {
                Text("再構成ステータス")
                    .font(.headline)
                    .foregroundStyle(palette.primaryText)

                SpatialScanMetricRow(title: "状態", value: reconstructionStateLabel)
                SpatialScanMetricRow(title: "フレーム数", value: "\(spatialScanFrameCount) 枚")
                if !pointItems.isEmpty {
                    SpatialScanMetricRow(title: "写真3D", value: "\(pointItems.count) splats")
                }

                if let duration = spatialScanCaptureDuration {
                    SpatialScanMetricRow(title: "収集時間", value: String(format: "%.1f 秒", duration))
                }

                if let summary = manifest?.preparationSummary {
                    SpatialScanMetricRow(title: "Coverage", value: "\(Int((summary.coverageScore * 100).rounded()))%")
                    SpatialScanMetricRow(title: "Proxy keyframes", value: "\(summary.selectedProxyFrameCount) 枚")
                    SpatialScanMetricRow(title: "静止ドリフト", value: String(format: "%.2f m", summary.translationExtentMeters))
                    SpatialScanMetricRow(title: "回頭レンジ", value: String(format: "%.0f°", summary.headingSpanDegrees))
                    if let verticalSpan = summary.verticalSpanDegrees {
                        SpatialScanMetricRow(title: "上下レンジ", value: String(format: "%.0f°", verticalSpan))
                    }
                }

                SpatialScanMetricRow(title: "空間アンカー", value: worldMapURL == nil ? "未保存" : "World Map 保存済み")

                if let processedAt = manifest?.reconstructionJob?.lastProcessedAt {
                    SpatialScanMetricRow(title: "最終処理", value: processedAt.formatted(date: .abbreviated, time: .shortened))
                }

                if let finalReadyAt = manifest?.reconstructionJob?.finalReadyAt {
                    SpatialScanMetricRow(title: "Final ready", value: finalReadyAt.formatted(date: .abbreviated, time: .shortened))
                }

                if let statusMessage = manifest?.reconstructionJob?.lastStatusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                }

                if let failure = manifest?.reconstructionJob?.lastFailure {
                    Text(failure.message)
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.82))
                }
            }
        }
    }

    private var assetCard: some View {
        ResonanceCard(atmosphere: entry.atmosphereStyle) {
            VStack(alignment: .leading, spacing: 12) {
                Text("保存アセット")
                    .font(.headline)
                    .foregroundStyle(palette.primaryText)

                if let syncMetadata = spatialScanSyncMetadata {
                    SpatialScanMetricRow(
                        title: "同期対象",
                        value: "\(syncMetadata.syncableAssets.count) files • \(syncableBytesText)"
                    )
                    SpatialScanMetricRow(
                        title: "端末限定",
                        value: "\(syncMetadata.localOnlyAssets.count) files • \(localOnlyBytesText)"
                    )
                } else {
                    Text("同期メタデータはまだありません。")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                }

                if let proxyRequestFileName = manifest?.reconstructionJob?.proxyRequestFileName {
                    SpatialScanAssetRow(relativePath: proxyRequestFileName, byteCount: assetByteCount(for: proxyRequestFileName))
                }

                if let highQualityRequestFileName = manifest?.reconstructionJob?.highQualityRequestFileName {
                    SpatialScanAssetRow(relativePath: highQualityRequestFileName, byteCount: assetByteCount(for: highQualityRequestFileName))
                }

                if spatialScanDerivedAssets.isEmpty {
                    Text("最適化済み3Dアセットはまだありません。新しいスキャンでは記録終了前に生成されます。")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                } else {
                    ForEach(spatialScanDerivedAssets) { asset in
                        SpatialScanAssetRow(relativePath: asset.relativePath, byteCount: asset.byteCount)
                    }
                }
            }
        }
    }

    private var frameOverlaySubtitle: String {
        let frameLabel = "\(spatialScanFrameCount) 枚"
        let durationLabel: String
        if let duration = spatialScanCaptureDuration {
            durationLabel = String(format: "%.1f 秒", duration)
        } else {
            durationLabel = "時間情報なし"
        }

        if let currentFrame {
            return "\(frameLabel) • \(durationLabel) • frame \(currentFrame.index + 1)"
        }
        return "\(frameLabel) • \(durationLabel)"
    }

    private var reconstructionStateLabel: String {
        switch spatialScanReconstructionState {
        case .captured:
            return "収集完了"
        case .proxyReady:
            return "プレビュー準備完了"
        case .queuedForHighQuality:
            return "高品質化を準備中"
        case .ready:
            return "空間再生対応"
        case .failed:
            return "再処理が必要"
        case nil:
            return "bundle 保存済み"
        }
    }

    private func loadScanResources() {
        stopSequencePlayback()
        waveformSamples = entry.waveformFingerprint
        cachedStoredSpatialScan = entry.atmosphereMetadata?.storedSpatialScan
        if let cachedStoredSpatialScan {
            cachedManifest = MediaStore.loadSpatialScanManifest(for: cachedStoredSpatialScan)
        }
        pointItems = loadPointItems()
        frameItems = loadFrameItems()
        selectedFrameIndex = min(selectedFrameIndex, max(frameItems.count - 1, 0))
        player.setPlaybackEnvelope(waveformSamples)
        if let playbackURL {
            player.load(url: playbackURL, autoPlay: false, loop: false, volume: 0.82)
        }
    }

    private func loadFrameItems() -> [SpatialScanPlaybackFrame] {
        guard let storedSpatialScan, let manifest else {
            return []
        }

        let frameSamples = representativeFrameSamples(from: manifest.frameSamples)
        return frameSamples.enumerated().compactMap { index, frameSample in
            guard
                let frameURL = MediaStore.spatialScanAssetURL(relativePath: frameSample.imageFileName, for: storedSpatialScan),
                let thumbnail = loadImage(at: frameURL, maxDimension: PlaybackImageSizing.thumbnailMaxDimension)
            else {
                return nil
            }

            return SpatialScanPlaybackFrame(
                index: index,
                sample: frameSample,
                fileURL: frameURL,
                thumbnail: thumbnail
            )
        }
    }

    private func loadPointItems() -> [SpatialScanOptimizedPoint] {
        if let storedSpatialScan,
           let optimizedFileName = manifest?.optimizedPointCloudFileName,
           let optimizedURL = MediaStore.spatialScanAssetURL(relativePath: optimizedFileName, for: storedSpatialScan),
           let optimizedPoints = try? SpatialScanOptimizedPointCloud.read(from: optimizedURL),
           !optimizedPoints.isEmpty {
            return representativePointSamples(from: optimizedPoints)
        }

        guard let worldMapURL,
              let worldMapData = try? Data(contentsOf: worldMapURL),
              let worldMap = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: worldMapData) else {
            return []
        }

        return representativePointSamples(from: worldMap.rawFeaturePoints)
    }

    private func representativePointSamples(from samples: [SpatialScanOptimizedPoint]) -> [SpatialScanOptimizedPoint] {
        guard samples.count > PlaybackImageSizing.maximumPointPreviewCount else {
            return samples
        }

        return evenlyDistributedIndices(
            totalCount: samples.count,
            targetCount: PlaybackImageSizing.maximumPointPreviewCount
        ).compactMap { index in
            guard samples.indices.contains(index) else { return nil }
            return samples[index]
        }
    }

    private func representativePointSamples(from pointCloud: ARPointCloud) -> [SpatialScanOptimizedPoint] {
        let points = pointCloud.points
        guard !points.isEmpty else { return [] }

        let indices = evenlyDistributedIndices(
            totalCount: points.count,
            targetCount: min(points.count, PlaybackImageSizing.maximumPointPreviewCount)
        )

        return indices.compactMap { index in
            guard points.indices.contains(index) else { return nil }
            let point = points[index]
            return SpatialScanOptimizedPoint(
                x: point.x,
                y: point.y,
                z: point.z,
                r: 0.44,
                g: 0.68,
                b: 0.98
            )
        }
    }

    private func representativeFrameSamples(from samples: [SpatialScanFrameSample]) -> [SpatialScanFrameSample] {
        guard samples.count > PlaybackImageSizing.maximumLoadedFrameCount else {
            return samples
        }

        return evenlyDistributedIndices(
            totalCount: samples.count,
            targetCount: PlaybackImageSizing.maximumLoadedFrameCount
        ).compactMap { index in
            guard samples.indices.contains(index) else { return nil }
            return samples[index]
        }
    }

    private func evenlyDistributedIndices(totalCount: Int, targetCount: Int) -> [Int] {
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

    private func loadImage(at url: URL, maxDimension: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }

        let maxPixelSize = max(Int(maxDimension), 1)
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private func toggleSequencePlayback() {
        if isSequencePlaying {
            stopSequencePlayback()
        } else {
            startSequencePlayback()
        }
    }

    private func startSequencePlayback() {
        guard frameItems.count > 1 else { return }
        stopSequencePlayback()
        isSequencePlaying = true
        framePlaybackTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(sequencePlaybackInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                selectedFrameIndex = (selectedFrameIndex + 1) % frameItems.count
            }
        }
    }

    private func stopSequencePlayback() {
        isSequencePlaying = false
        framePlaybackTask?.cancel()
        framePlaybackTask = nil
    }

    private func stopPlayback() {
        stopSequencePlayback()
        player.stop()
    }

    private func assetByteCount(for relativePath: String) -> Int64? {
        guard let storedSpatialScan,
              let assetURL = MediaStore.spatialScanAssetURL(relativePath: relativePath, for: storedSpatialScan) else {
            return nil
        }
        return (try? assetURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    private func formattedByteCount(for assets: [SpatialScanSyncAsset]) -> String {
        let total = assets.compactMap(\.byteCount).reduce(0, +)
        guard total > 0 else { return "size 不明" }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}

private struct SpatialScanPlaybackFrame: Identifiable {
    let index: Int
    let sample: SpatialScanFrameSample
    let fileURL: URL
    let thumbnail: UIImage

    var id: String {
        "\(index)-\(fileURL.lastPathComponent)"
    }
}

private struct SpatialScanModelPreviewView: UIViewRepresentable {
    let frames: [SpatialScanPlaybackFrame]
    let pointSamples: [SpatialScanOptimizedPoint]
    @Binding var selectedFrameIndex: Int
    let motionEnabled: Bool
    let atmosphere: AtmosphereStyle

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SCNView {
        context.coordinator.makeView()
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.update(
            view: uiView,
            frames: frames,
            pointSamples: pointSamples,
            selectedFrameIndex: selectedFrameIndex,
            motionEnabled: motionEnabled,
            atmosphere: atmosphere
        )
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        coordinator.stopMotion()
    }

    final class Coordinator {
        private let scene = SCNScene()
        private let modelRoot = SCNNode()
        private let cameraOrbit = SCNNode()
        private let cameraNode = SCNNode()
        private let motionManager = CMMotionManager()
        private weak var previewView: SCNView?
        private var frameNodes: [Int: SCNNode] = [:]
        private var renderedSignature = ""
        private var isMotionEnabled = false
        private var referenceAttitude: CMAttitude?
        private var lastSelectedFrameIndex: Int?
        private var lastMotionUpdateAt = Date.distantPast
        private var lastMotionEuler = SCNVector3Zero

        private struct RenderPoint {
            let position: SCNVector3
            let color: SIMD4<Float>
            let normal: SCNVector3
            let radius: Float
        }

        func makeView() -> SCNView {
            scene.background.contents = UIColor.black
            scene.rootNode.addChildNode(modelRoot)
            scene.rootNode.addChildNode(cameraOrbit)

            let camera = SCNCamera()
            camera.fieldOfView = 48
            camera.zNear = 0.01
            camera.zFar = 120
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(0, 0.5, 3.15)
            cameraNode.eulerAngles.x = -Float.pi / 32
            cameraOrbit.addChildNode(cameraNode)

            let ambientLight = SCNLight()
            ambientLight.type = .ambient
            ambientLight.intensity = 560
            let ambientNode = SCNNode()
            ambientNode.light = ambientLight
            scene.rootNode.addChildNode(ambientNode)

            let keyLight = SCNLight()
            keyLight.type = .omni
            keyLight.intensity = 420
            let keyNode = SCNNode()
            keyNode.light = keyLight
            keyNode.position = SCNVector3(1.6, 2.2, 2.4)
            scene.rootNode.addChildNode(keyNode)

            let view = SCNView()
            view.scene = scene
            view.pointOfView = cameraNode
            view.backgroundColor = .black
            view.isPlaying = false
            view.rendersContinuously = false
            view.preferredFramesPerSecond = 30
            view.antialiasingMode = .none
            view.allowsCameraControl = false
            previewView = view
            return view
        }

        func update(
            view: SCNView,
            frames: [SpatialScanPlaybackFrame],
            pointSamples: [SpatialScanOptimizedPoint],
            selectedFrameIndex: Int,
            motionEnabled: Bool,
            atmosphere: AtmosphereStyle
        ) {
            let firstPoint = pointSamples.first
            let lastPoint = pointSamples.last
            let pointSignature = "\(pointSamples.count):\(firstPoint?.x ?? 0):\(firstPoint?.y ?? 0):\(lastPoint?.z ?? 0)"
            let signature = pointSignature + "|" + frames.map(\.id).joined(separator: "|")
            if signature != renderedSignature {
                renderedSignature = signature
                rebuildModel(frames: frames, pointSamples: pointSamples, atmosphere: atmosphere)
            }
            updateSelection(selectedFrameIndex: selectedFrameIndex, atmosphere: atmosphere)
            setMotionEnabled(motionEnabled)
        }

        func stopMotion() {
            if motionManager.isDeviceMotionActive {
                motionManager.stopDeviceMotionUpdates()
            }
            referenceAttitude = nil
            isMotionEnabled = false
        }

        private func setMotionEnabled(_ enabled: Bool) {
            guard enabled != isMotionEnabled else { return }
            isMotionEnabled = enabled
            if enabled {
                startMotion()
            } else {
                stopMotion()
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.2
                modelRoot.eulerAngles = SCNVector3Zero
                cameraOrbit.eulerAngles = SCNVector3Zero
                SCNTransaction.commit()
                previewView?.setNeedsDisplay()
            }
        }

        private func startMotion() {
            guard motionManager.isDeviceMotionAvailable else { return }
            referenceAttitude = nil
            lastMotionUpdateAt = .distantPast
            motionManager.deviceMotionUpdateInterval = 1.0 / 24.0
            let handler: CMDeviceMotionHandler = { [weak self] motion, _ in
                guard let self, let motion else { return }
                self.apply(attitude: motion.attitude)
            }

            if let referenceFrame = ImmersiveDirectionSpace.preferredMotionReferenceFrame() {
                motionManager.startDeviceMotionUpdates(using: referenceFrame, to: .main, withHandler: handler)
            } else {
                motionManager.startDeviceMotionUpdates(to: .main, withHandler: handler)
            }
        }

        private func apply(attitude: CMAttitude) {
            if referenceAttitude == nil {
                referenceAttitude = attitude.copy() as? CMAttitude
            }
            guard let referenceAttitude,
                  let relativeAttitude = attitude.copy() as? CMAttitude else {
                return
            }
            relativeAttitude.multiply(byInverseOf: referenceAttitude)

            let yaw = Float(relativeAttitude.yaw)
            let pitch = Float(relativeAttitude.pitch)
            let roll = Float(relativeAttitude.roll)
            let clampedPitch = min(max(pitch, -0.95), 0.95)
            let now = Date()
            let nextEuler = SCNVector3(clampedPitch * 0.55, -yaw, roll * 0.04)

            guard now.timeIntervalSince(lastMotionUpdateAt) >= (1.0 / 24.0)
                || abs(nextEuler.x - lastMotionEuler.x) > 0.01
                || abs(nextEuler.y - lastMotionEuler.y) > 0.01
                || abs(nextEuler.z - lastMotionEuler.z) > 0.01 else {
                return
            }
            lastMotionUpdateAt = now
            lastMotionEuler = nextEuler

            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            modelRoot.eulerAngles = SCNVector3(0, 0, nextEuler.z)
            cameraOrbit.eulerAngles = SCNVector3(nextEuler.x, nextEuler.y, 0)
            SCNTransaction.commit()
            previewView?.setNeedsDisplay()
        }

        private func rebuildModel(
            frames: [SpatialScanPlaybackFrame],
            pointSamples: [SpatialScanOptimizedPoint],
            atmosphere: AtmosphereStyle
        ) {
            modelRoot.childNodes.forEach { $0.removeFromParentNode() }
            frameNodes = [:]
            lastSelectedFrameIndex = nil

            let accent = accentColor(for: atmosphere)

            if !pointSamples.isEmpty {
                addSurfelCloud(pointSamples: pointSamples, accent: accent)
                return
            }

            addFloor(accent: accent)

            guard !frames.isEmpty else {
                addEmptyProxy(accent: accent)
                return
            }

            let rawPositions = frames.enumerated().map { index, frame in
                rawPosition(for: frame.sample, index: index, totalCount: frames.count)
            }
            let normalizedPositions = normalizedPositions(from: rawPositions)
            addPath(positions: normalizedPositions, accent: accent)

            for (frame, position) in zip(frames, normalizedPositions) {
                let node = makeFrameNode(frame: frame, position: position, accent: accent)
                modelRoot.addChildNode(node)
                frameNodes[frame.index] = node
            }
        }

        private func addFloor(accent: UIColor) {
            let floor = SCNPlane(width: 5, height: 5)
            let material = SCNMaterial()
            material.diffuse.contents = UIColor(white: 0.04, alpha: 1)
            material.emission.contents = accent.withAlphaComponent(0.05)
            floor.materials = [material]

            let floorNode = SCNNode(geometry: floor)
            floorNode.position.y = -0.55
            floorNode.eulerAngles.x = -Float.pi / 2
            modelRoot.addChildNode(floorNode)
        }

        private func addEmptyProxy(accent: UIColor) {
            let box = SCNBox(width: 0.9, height: 0.42, length: 0.9, chamferRadius: 0.05)
            let material = SCNMaterial()
            material.diffuse.contents = accent.withAlphaComponent(0.24)
            material.emission.contents = accent.withAlphaComponent(0.12)
            box.materials = [material]

            let node = SCNNode(geometry: box)
            node.position = SCNVector3(0, 0, 0)
            modelRoot.addChildNode(node)
        }

        private func addSurfelCloud(pointSamples: [SpatialScanOptimizedPoint], accent: UIColor) {
            let renderPoints = normalizedPointPositions(from: pointSamples)
            guard !renderPoints.isEmpty else { return }

            var vertices: [SCNVector3] = []
            var colors: [SIMD4<Float>] = []
            var indices: [Int32] = []
            vertices.reserveCapacity(renderPoints.count * 4)
            colors.reserveCapacity(renderPoints.count * 4)
            indices.reserveCapacity(renderPoints.count * 6)

            for renderPoint in renderPoints {
                let position = renderPoint.position
                let surfelRadius = min(max(renderPoint.radius, 0.014), 0.065)
                let radialNormal = normalized(position)
                let normal = vectorLength(renderPoint.normal) > 0.001
                    ? renderPoint.normal
                    : (vectorLength(radialNormal) > 0.001 ? radialNormal : SCNVector3(0, 0, 1))
                var tangent = cross(normal, SCNVector3(0, 1, 0))
                if vectorLength(tangent) < 0.001 {
                    tangent = cross(normal, SCNVector3(1, 0, 0))
                }
                tangent = normalized(tangent)
                let bitangent = normalized(cross(normal, tangent))
                let baseIndex = Int32(vertices.count)

                vertices.append(position + (tangent * surfelRadius) + (bitangent * surfelRadius))
                vertices.append(position - (tangent * surfelRadius) + (bitangent * surfelRadius))
                vertices.append(position - (tangent * surfelRadius) - (bitangent * surfelRadius))
                vertices.append(position + (tangent * surfelRadius) - (bitangent * surfelRadius))

                colors.append(renderPoint.color)
                colors.append(renderPoint.color)
                colors.append(renderPoint.color)
                colors.append(renderPoint.color)

                indices.append(baseIndex)
                indices.append(baseIndex + 1)
                indices.append(baseIndex + 2)
                indices.append(baseIndex)
                indices.append(baseIndex + 2)
                indices.append(baseIndex + 3)
            }

            let vertexSource = SCNGeometrySource(vertices: vertices)
            let colorData = colors.withUnsafeBytes { Data($0) }
            let colorSource = SCNGeometrySource(
                data: colorData,
                semantic: .color,
                vectorCount: colors.count,
                usesFloatComponents: true,
                componentsPerVector: 4,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<SIMD4<Float>>.stride
            )

            let indexData = indices.withUnsafeBytes { Data($0) }
            let element = SCNGeometryElement(
                data: indexData,
                primitiveType: .triangles,
                primitiveCount: indices.count / 3,
                bytesPerIndex: MemoryLayout<Int32>.size
            )

            let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = UIColor.white
            material.emission.contents = UIColor.black
            material.shaderModifiers = [
                .surface: """
                #pragma body
                _surface.diffuse = _geometry.color.rgb;
                _surface.emission = _geometry.color.rgb * 0.04;
                _surface.transparent = _geometry.color.a;
                """
            ]
            material.blendMode = .alpha
            material.isDoubleSided = true
            material.writesToDepthBuffer = true
            material.readsFromDepthBuffer = true
            geometry.materials = [material]

            let node = SCNNode(geometry: geometry)
            node.name = "optimized-surfel-cloud"
            modelRoot.addChildNode(node)
        }

        private func makeFrameNode(
            frame: SpatialScanPlaybackFrame,
            position: SCNVector3,
            accent: UIColor
        ) -> SCNNode {
            let aspect = max(CGFloat(frame.sample.imageWidth) / CGFloat(max(frame.sample.imageHeight, 1)), 0.25)
            let height: CGFloat = 0.34
            let plane = SCNPlane(width: height * aspect, height: height)
            let material = SCNMaterial()
            material.diffuse.contents = frame.thumbnail
            material.emission.contents = UIColor.black
            material.lightingModel = .constant
            material.isDoubleSided = true
            plane.materials = [material]

            let node = SCNNode(geometry: plane)
            node.name = "frame-\(frame.index)"
            node.position = position
            node.opacity = 0.74
            node.eulerAngles.y = atan2(position.x, position.z) + Float.pi

            let marker = SCNSphere(radius: 0.026)
            let markerMaterial = SCNMaterial()
            markerMaterial.diffuse.contents = accent
            markerMaterial.emission.contents = accent.withAlphaComponent(0.6)
            marker.materials = [markerMaterial]
            let markerNode = SCNNode(geometry: marker)
            markerNode.position = SCNVector3(0, -0.24, 0)
            node.addChildNode(markerNode)
            return node
        }

        private func addPath(positions: [SCNVector3], accent: UIColor) {
            guard positions.count > 1 else { return }
            var indices: [Int32] = []
            for index in 0..<(positions.count - 1) {
                indices.append(Int32(index))
                indices.append(Int32(index + 1))
            }

            let source = SCNGeometrySource(vertices: positions)
            let data = indices.withUnsafeBytes { Data($0) }
            let element = SCNGeometryElement(
                data: data,
                primitiveType: .line,
                primitiveCount: indices.count / 2,
                bytesPerIndex: MemoryLayout<Int32>.size
            )
            let geometry = SCNGeometry(sources: [source], elements: [element])
            let material = SCNMaterial()
            material.diffuse.contents = accent.withAlphaComponent(0.82)
            material.emission.contents = accent.withAlphaComponent(0.45)
            geometry.materials = [material]

            let node = SCNNode(geometry: geometry)
            modelRoot.addChildNode(node)
        }

        private func updateSelection(selectedFrameIndex: Int, atmosphere: AtmosphereStyle) {
            guard selectedFrameIndex != lastSelectedFrameIndex else { return }
            lastSelectedFrameIndex = selectedFrameIndex

            let accent = accentColor(for: atmosphere)
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.12
            for (index, node) in frameNodes {
                let isSelected = index == selectedFrameIndex
                node.opacity = isSelected ? 1 : 0.62
                node.scale = isSelected ? SCNVector3(1.18, 1.18, 1.18) : SCNVector3(1, 1, 1)
                node.geometry?.firstMaterial?.emission.contents = isSelected ? accent.withAlphaComponent(0.24) : UIColor.black
            }
            SCNTransaction.commit()
            previewView?.setNeedsDisplay()
        }

        private func rawPosition(
            for sample: SpatialScanFrameSample,
            index: Int,
            totalCount: Int
        ) -> SCNVector3 {
            let fallbackHeading = Double(index) / Double(max(totalCount, 1)) * 360
            let heading = sample.headingDegrees ?? fallbackHeading
            let pitch = sample.pitchDegrees ?? 0
            let headingRadians = heading * .pi / 180
            let pitchRadians = min(max(pitch, -75), 75) * .pi / 180
            let radius = 1.15
            let horizontalRadius = radius * cos(pitchRadians)
            let x = sin(headingRadians) * horizontalRadius
            let y = sin(pitchRadians) * 0.95
            let z = cos(headingRadians) * horizontalRadius
            return SCNVector3(Float(x), Float(y), Float(z))
        }

        private func normalizedPositions(from positions: [SCNVector3]) -> [SCNVector3] {
            guard !positions.isEmpty else { return [] }
            let center = positions.reduce(SCNVector3Zero) { partial, position in
                SCNVector3(partial.x + position.x, partial.y + position.y, partial.z + position.z)
            } / Float(positions.count)
            let centered = positions.map { $0 - center }
            let maxExtent = max(
                centered.map { abs($0.x) }.max() ?? 0,
                centered.map { abs($0.y) }.max() ?? 0,
                centered.map { abs($0.z) }.max() ?? 0,
                0.1
            )
            let scale = min(1.0 / maxExtent, 4.0)
            return centered.map { position in
                SCNVector3(position.x * scale, (position.y * scale) + 0.06, position.z * scale)
            }
        }

        private func normalizedPointPositions(from samples: [SpatialScanOptimizedPoint]) -> [RenderPoint] {
            let rawPositions = samples.map { sample in
                SCNVector3(sample.x, sample.y, sample.z)
            }
            guard !rawPositions.isEmpty else { return [] }

            let sortedX = rawPositions.map(\.x).sorted()
            let sortedY = rawPositions.map(\.y).sorted()
            let sortedZ = rawPositions.map(\.z).sorted()
            let lowerIndex = max(Int(Double(rawPositions.count - 1) * 0.01), 0)
            let upperIndex = min(Int(Double(rawPositions.count - 1) * 0.99), rawPositions.count - 1)
            let minPoint = SCNVector3(sortedX[lowerIndex], sortedY[lowerIndex], sortedZ[lowerIndex])
            let maxPoint = SCNVector3(sortedX[upperIndex], sortedY[upperIndex], sortedZ[upperIndex])
            let center = (minPoint + maxPoint) / 2
            let extent = max(maxPoint.x - minPoint.x, maxPoint.y - minPoint.y, maxPoint.z - minPoint.z, 0.3)
            let scale = min(2.9 / extent, 4.2)

            var renderPoints: [RenderPoint] = []
            renderPoints.reserveCapacity(samples.count)

            for sample in samples {
                let position = SCNVector3(sample.x, sample.y, sample.z)
                guard position.x >= minPoint.x,
                      position.x <= maxPoint.x,
                      position.y >= minPoint.y,
                      position.y <= maxPoint.y,
                      position.z >= minPoint.z,
                      position.z <= maxPoint.z else {
                    continue
                }

                let normalizedPosition = position - center
                let renderedPosition = SCNVector3(
                    normalizedPosition.x * scale,
                    (normalizedPosition.y * scale) + 0.08,
                    normalizedPosition.z * scale
                )
                renderPoints.append(
                    RenderPoint(
                        position: renderedPosition,
                        color: SIMD4<Float>(
                            min(max(sample.r, 0), 1),
                            min(max(sample.g, 0), 1),
                            min(max(sample.b, 0), 1),
                            0.98
                        ),
                        normal: normalized(SCNVector3(sample.normalX, sample.normalY, sample.normalZ)),
                        radius: min(max(sample.radius * scale, 0.008), 0.11)
                    )
                )
            }

            return renderPoints
        }

        private func accentColor(for atmosphere: AtmosphereStyle) -> UIColor {
            switch atmosphere {
            case .dawn:
                return UIColor(red: 1.0, green: 0.55, blue: 0.48, alpha: 1)
            case .day:
                return UIColor(red: 0.18, green: 0.45, blue: 0.95, alpha: 1)
            case .dusk:
                return UIColor(red: 0.62, green: 0.34, blue: 0.92, alpha: 1)
            case .night:
                return UIColor(red: 0.34, green: 0.56, blue: 0.96, alpha: 1)
            }
        }
    }
}

private func + (lhs: SCNVector3, rhs: SCNVector3) -> SCNVector3 {
    SCNVector3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
}

private func - (lhs: SCNVector3, rhs: SCNVector3) -> SCNVector3 {
    SCNVector3(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z)
}

private func / (lhs: SCNVector3, rhs: Float) -> SCNVector3 {
    guard rhs != 0 else { return lhs }
    return SCNVector3(lhs.x / rhs, lhs.y / rhs, lhs.z / rhs)
}

private func * (lhs: SCNVector3, rhs: Float) -> SCNVector3 {
    SCNVector3(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs)
}

private func cross(_ lhs: SCNVector3, _ rhs: SCNVector3) -> SCNVector3 {
    SCNVector3(
        (lhs.y * rhs.z) - (lhs.z * rhs.y),
        (lhs.z * rhs.x) - (lhs.x * rhs.z),
        (lhs.x * rhs.y) - (lhs.y * rhs.x)
    )
}

private func vectorLength(_ vector: SCNVector3) -> Float {
    sqrt((vector.x * vector.x) + (vector.y * vector.y) + (vector.z * vector.z))
}

private func normalized(_ vector: SCNVector3) -> SCNVector3 {
    let length = vectorLength(vector)
    guard length > 0 else { return SCNVector3Zero }
    return vector / length
}

private struct SpatialScanMetricRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
        }
        .font(.subheadline)
    }
}

private struct SpatialScanMetricPill: View {
    let title: String
    let value: String
    let atmosphere: AtmosphereStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(ResonancePalette.make(for: .dark, atmosphere: atmosphere).surfaceSecondary.opacity(0.72))
        )
    }
}

private struct SpatialScanAssetRow: View {
    let relativePath: String
    let byteCount: Int64?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(relativePath)
                    .font(.caption.weight(.semibold))
                    .textSelection(.enabled)
                if let byteCount, byteCount > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
    }
}

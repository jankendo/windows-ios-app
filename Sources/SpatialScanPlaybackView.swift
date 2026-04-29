import SwiftUI
import UIKit
import ARKit
import ImageIO
import SceneKit
import simd

struct SpatialScanPlaybackView: View {
    private enum PlaybackImageSizing {
        static let thumbnailMaxDimension: CGFloat = 2_560
        static let maximumLoadedFrameCount = 72
        static let maximumPointPreviewCount = 360_000
    }

    let entry: MemoryEntry

    @State private var cachedStoredSpatialScan: StoredSpatialScan?
    @State private var cachedManifest: SpatialScanManifest?
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var player = AudioPlayerController()
    @State private var waveformSamples: [CGFloat] = Array(repeating: 0.25, count: 40)
    @State private var frameItems: [SpatialScanPlaybackFrame] = []
    @State private var pointItems: [SpatialScanOptimizedPoint] = []
    @State private var selectedFrameIndex = 0
    @State private var isSequencePlaying = false
    @State private var isDetailsPresented = false
    @State private var framePlaybackTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

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
            spatialModelHero(
                size: geometry.size,
                safeAreaInsets: geometry.safeAreaInsets
            )
        }
        .navigationTitle("3Dスキャン")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(true)
        .ignoresSafeArea()
        .sheet(isPresented: $isDetailsPresented) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        scrubberCard
                        reconstructionCard
                        assetCard
                    }
                    .padding(20)
                }
                .background(ResonanceGradientBackground(atmosphere: entry.atmosphereStyle))
                .navigationTitle("3Dスキャン詳細")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onAppear {
            loadScanResources()
        }
        .onDisappear {
            stopPlayback()
        }
    }

    private func spatialModelHero(
        size: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> some View {
        ZStack(alignment: .bottomLeading) {
            SpatialScanModelPreviewView(
                frames: frameItems,
                pointSamples: pointItems,
                selectedFrameIndex: $selectedFrameIndex,
                atmosphere: entry.atmosphereStyle
            )
            .frame(width: size.width, height: size.height)
            .background(Color.black)
            .contentShape(Rectangle())

            LinearGradient(
                colors: [Color.black.opacity(0.08), .clear, Color.black.opacity(0.78)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            VStack {
                HStack(spacing: 12) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.headline.weight(.bold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.42), in: Circle())

                    Spacer()

                    Button {
                        isDetailsPresented = true
                    } label: {
                        Image(systemName: "info.circle.fill")
                            .font(.title3.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.42), in: Circle())
                }
                .padding(.top, max(safeAreaInsets.top, 18) + 6)
                .padding(.horizontal, 18)

                Spacer()
            }

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
                            title: "指で3D操作",
                            systemImage: "hand.point.up.left.fill",
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
                                title: "\(pointItems.count) 写真3D",
                                systemImage: "camera.aperture",
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
            .padding(.bottom, max(safeAreaInsets.bottom, 18) + 10)
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

                Text("実際の写真を点群の奥行きへ投影し、ドラッグとピンチでその場の内側から見返せます。")
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
            atmosphere: atmosphere
        )
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private let scene = SCNScene()
        private let modelRoot = SCNNode()
        private let cameraOrbit = SCNNode()
        private let cameraNode = SCNNode()
        private weak var previewView: SCNView?
        private var frameNodes: [Int: SCNNode] = [:]
        private var renderedSignature = ""
        private var lastSelectedFrameIndex: Int?
        private var manualYaw: Float = 0
        private var manualPitch: Float = 0
        private var manualScale: Float = 1
        private var lastPanTranslation = CGPoint.zero

        private let minimumPreviewScale: Float = 0.55
        private let maximumPreviewScale: Float = 2.6
        private let maximumProjectedTextureFrameCount = 56
        private let maximumProjectedTextureAnchorCount = 140_000

        private struct RenderPoint {
            let position: SCNVector3
            let color: SIMD4<Float>
            let normal: SCNVector3
            let radius: Float
        }

        private struct PointNormalization {
            let minPoint: SCNVector3
            let maxPoint: SCNVector3
            let center: SCNVector3
            let scale: Float

            func contains(_ position: SCNVector3, margin: Float = 0) -> Bool {
                position.x >= minPoint.x - margin
                    && position.x <= maxPoint.x + margin
                    && position.y >= minPoint.y - margin
                    && position.y <= maxPoint.y + margin
                    && position.z >= minPoint.z - margin
                    && position.z <= maxPoint.z + margin
            }

            func renderPosition(for position: SCNVector3) -> SCNVector3 {
                let normalizedPosition = position - center
                return SCNVector3(
                    normalizedPosition.x * scale,
                    (normalizedPosition.y * scale) + 0.08,
                    normalizedPosition.z * scale
                )
            }
        }

        private struct CameraCalibration {
            let cameraTransform: simd_float4x4
            let inverseCameraTransform: simd_float4x4
            let fx: Float
            let fy: Float
            let cx: Float
            let cy: Float
            let imageWidth: Float
            let imageHeight: Float
        }

        private struct ProjectionSample {
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

        func makeView() -> SCNView {
            scene.background.contents = UIColor.black
            scene.rootNode.addChildNode(modelRoot)
            scene.rootNode.addChildNode(cameraOrbit)

            let camera = SCNCamera()
            camera.fieldOfView = 72
            camera.zNear = 0.02
            camera.zFar = 160
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(0, 0.08, 0)
            cameraNode.eulerAngles = SCNVector3Zero
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
            installGestures(on: view)
            previewView = view
            return view
        }

        func update(
            view: SCNView,
            frames: [SpatialScanPlaybackFrame],
            pointSamples: [SpatialScanOptimizedPoint],
            selectedFrameIndex: Int,
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
        }

        func teardown() {
            previewView = nil
        }

        private func installGestures(on view: SCNView) {
            let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            panGesture.maximumNumberOfTouches = 1
            panGesture.delegate = self
            panGesture.cancelsTouchesInView = false
            view.addGestureRecognizer(panGesture)

            let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinchGesture.delegate = self
            pinchGesture.cancelsTouchesInView = false
            view.addGestureRecognizer(pinchGesture)

            let resetGesture = UITapGestureRecognizer(target: self, action: #selector(resetPreviewTransform))
            resetGesture.numberOfTapsRequired = 2
            resetGesture.cancelsTouchesInView = false
            view.addGestureRecognizer(resetGesture)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            if gesture.state == .began {
                lastPanTranslation = translation
                return
            }

            let deltaX = Float(translation.x - lastPanTranslation.x)
            let deltaY = Float(translation.y - lastPanTranslation.y)
            lastPanTranslation = translation

            manualYaw -= deltaX * 0.006
            manualPitch = min(max(manualPitch - (deltaY * 0.005), -1.12), 1.12)
            applyManualCamera(animated: false)

            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                lastPanTranslation = .zero
            }
        }

        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            manualScale = min(max(manualScale * Float(gesture.scale), minimumPreviewScale), maximumPreviewScale)
            gesture.scale = 1
            applyManualCamera(animated: false)
        }

        @objc private func resetPreviewTransform() {
            manualYaw = 0
            manualPitch = 0
            manualScale = 1
            applyManualCamera(animated: true)
        }

        private func applyManualCamera(animated: Bool) {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = animated ? 0.18 : 0
            SCNTransaction.disableActions = !animated
            cameraOrbit.eulerAngles = SCNVector3(manualPitch, manualYaw, 0)
            modelRoot.scale = SCNVector3(manualScale, manualScale, manualScale)
            cameraNode.position = SCNVector3(0, 0.08, 0)
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
                if let normalization = pointNormalization(from: pointSamples) {
                    addProjectedPhotoMeshes(
                        frames: frames,
                        pointSamples: pointSamples,
                        normalization: normalization
                    )
                    addSurfelCloud(
                        pointSamples: pointSamples,
                        accent: accent,
                        normalization: normalization
                    )
                    applyManualCamera(animated: false)
                }
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
            applyManualCamera(animated: false)
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

        private func addSurfelCloud(
            pointSamples: [SpatialScanOptimizedPoint],
            accent: UIColor,
            normalization: PointNormalization
        ) {
            let renderPoints = normalizedPointPositions(from: pointSamples, normalization: normalization)
            guard !renderPoints.isEmpty else { return }

            var vertices: [SCNVector3] = []
            var colors: [SIMD4<Float>] = []
            var indices: [Int32] = []
            vertices.reserveCapacity(renderPoints.count * 4)
            colors.reserveCapacity(renderPoints.count * 4)
            indices.reserveCapacity(renderPoints.count * 6)

            for renderPoint in renderPoints {
                let position = renderPoint.position
                let surfelRadius = min(max(renderPoint.radius, 0.0035), 0.075)
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
            material.blendMode = .replace
            material.isDoubleSided = true
            material.writesToDepthBuffer = true
            material.readsFromDepthBuffer = true
            geometry.materials = [material]

            let node = SCNNode(geometry: geometry)
            node.name = "optimized-surfel-cloud"
            modelRoot.addChildNode(node)
        }

        private func addProjectedPhotoMeshes(
            frames: [SpatialScanPlaybackFrame],
            pointSamples: [SpatialScanOptimizedPoint],
            normalization: PointNormalization
        ) {
            guard !frames.isEmpty, !pointSamples.isEmpty else { return }

            for frame in representativeTextureFrames(from: frames) {
                guard let node = makeProjectedPhotoMesh(
                    frame: frame,
                    pointSamples: pointSamples,
                    normalization: normalization
                ) else {
                    continue
                }
                modelRoot.addChildNode(node)
            }
        }

        private func representativeTextureFrames(from frames: [SpatialScanPlaybackFrame]) -> [SpatialScanPlaybackFrame] {
            guard frames.count > maximumProjectedTextureFrameCount else { return frames }

            let denominator = max(maximumProjectedTextureFrameCount - 1, 1)
            let indices = Set(
                (0..<maximumProjectedTextureFrameCount).map { offset in
                    Int(round((Double(offset) / Double(denominator)) * Double(frames.count - 1)))
                }
            )
            return indices.sorted().compactMap { index in
                guard frames.indices.contains(index) else { return nil }
                return frames[index]
            }
        }

        private func makeProjectedPhotoMesh(
            frame: SpatialScanPlaybackFrame,
            pointSamples: [SpatialScanOptimizedPoint],
            normalization: PointNormalization
        ) -> SCNNode? {
            guard let calibration = cameraCalibration(for: frame.sample) else { return nil }

            let imageAspect = max(calibration.imageWidth / max(calibration.imageHeight, 1), 0.25)
            let targetCellCount: Float = 11_500
            let gridColumns = min(max(Int(sqrt(targetCellCount * imageAspect)), 72), 184)
            let gridRows = min(max(Int(Float(gridColumns) / imageAspect), 48), 136)
            let cellWidth = calibration.imageWidth / Float(gridColumns)
            let cellHeight = calibration.imageHeight / Float(gridRows)
            var cells = [DepthCell](repeating: DepthCell(), count: gridColumns * gridRows)

            let anchorStride = max(pointSamples.count / maximumProjectedTextureAnchorCount, 1)
            for index in stride(from: 0, to: pointSamples.count, by: anchorStride) {
                let sample = pointSamples[index]
                let rawPosition = SCNVector3(sample.x, sample.y, sample.z)
                guard normalization.contains(rawPosition),
                      let projection = project(
                        worldPosition: SIMD3<Float>(sample.x, sample.y, sample.z),
                        calibration: calibration
                      ),
                      projection.depth >= 0.12,
                      projection.depth <= 14.0 else {
                    continue
                }

                let column = min(max(Int(projection.pixel.x / cellWidth), 0), gridColumns - 1)
                let row = min(max(Int(projection.pixel.y / cellHeight), 0), gridRows - 1)
                cells[(row * gridColumns) + column].add(depth: projection.depth)
            }

            var vertices: [SCNVector3] = []
            var textureCoordinates: [CGPoint] = []
            var indices: [Int32] = []
            vertices.reserveCapacity(gridColumns * gridRows * 4)
            textureCoordinates.reserveCapacity(gridColumns * gridRows * 4)
            indices.reserveCapacity(gridColumns * gridRows * 6)

            var confidenceSum: Float = 0
            var texturedCellCount = 0

            for row in 0..<gridRows {
                for column in 0..<gridColumns {
                    guard let depthSample = resolvedDepth(
                        forColumn: column,
                        row: row,
                        cells: cells,
                        columns: gridColumns,
                        rows: gridRows
                    ) else {
                        continue
                    }

                    let minX = Float(column) * cellWidth
                    let maxX = min(Float(column + 1) * cellWidth, calibration.imageWidth - 1)
                    let minY = Float(row) * cellHeight
                    let maxY = min(Float(row + 1) * cellHeight, calibration.imageHeight - 1)
                    let pixels = [
                        SIMD2<Float>(minX, minY),
                        SIMD2<Float>(maxX, minY),
                        SIMD2<Float>(maxX, maxY),
                        SIMD2<Float>(minX, maxY)
                    ]

                    var cellVertices: [SCNVector3] = []
                    cellVertices.reserveCapacity(4)
                    var cellIsUsable = true
                    for pixel in pixels {
                        guard let worldPosition = unproject(
                            pixel: pixel,
                            depth: depthSample.depth,
                            calibration: calibration
                        ) else {
                            cellIsUsable = false
                            break
                        }

                        let rawPosition = SCNVector3(worldPosition.x, worldPosition.y, worldPosition.z)
                        guard normalization.contains(rawPosition, margin: 0.16) else {
                            cellIsUsable = false
                            break
                        }
                        cellVertices.append(normalization.renderPosition(for: rawPosition))
                    }
                    guard cellIsUsable, cellVertices.count == 4 else { continue }

                    let baseIndex = Int32(vertices.count)
                    vertices.append(contentsOf: cellVertices)
                    textureCoordinates.append(
                        contentsOf: pixels.map { pixel in
                            CGPoint(
                                x: CGFloat(min(max(pixel.x / calibration.imageWidth, 0), 1)),
                                y: CGFloat(1 - min(max(pixel.y / calibration.imageHeight, 0), 1))
                            )
                        }
                    )
                    indices.append(baseIndex)
                    indices.append(baseIndex + 1)
                    indices.append(baseIndex + 2)
                    indices.append(baseIndex)
                    indices.append(baseIndex + 2)
                    indices.append(baseIndex + 3)
                    confidenceSum += depthSample.confidence
                    texturedCellCount += 1
                }
            }

            guard texturedCellCount >= 12, indices.count >= 36 else { return nil }

            let vertexSource = SCNGeometrySource(vertices: vertices)
            let textureSource = SCNGeometrySource(textureCoordinates: textureCoordinates)
            let indexData = indices.withUnsafeBytes { Data($0) }
            let element = SCNGeometryElement(
                data: indexData,
                primitiveType: .triangles,
                primitiveCount: indices.count / 3,
                bytesPerIndex: MemoryLayout<Int32>.size
            )
            let geometry = SCNGeometry(sources: [vertexSource, textureSource], elements: [element])

            let averageConfidence = confidenceSum / Float(max(texturedCellCount, 1))
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = frame.thumbnail
            material.emission.contents = UIColor.black
            material.isDoubleSided = true
            material.blendMode = .alpha
            material.transparency = CGFloat(min(max(0.9 + (averageConfidence * 0.1), 0.88), 1.0))
            material.writesToDepthBuffer = true
            material.readsFromDepthBuffer = true
            geometry.materials = [material]

            let node = SCNNode(geometry: geometry)
            node.name = "projected-photo-texture-\(frame.index)"
            return node
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

        private func pointNormalization(from samples: [SpatialScanOptimizedPoint]) -> PointNormalization? {
            let rawPositions = samples.map { sample in
                SCNVector3(sample.x, sample.y, sample.z)
            }
            guard !rawPositions.isEmpty else { return nil }

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
            return PointNormalization(minPoint: minPoint, maxPoint: maxPoint, center: center, scale: scale)
        }

        private func normalizedPointPositions(
            from samples: [SpatialScanOptimizedPoint],
            normalization: PointNormalization
        ) -> [RenderPoint] {
            var renderPoints: [RenderPoint] = []
            renderPoints.reserveCapacity(samples.count)

            for sample in samples {
                let position = SCNVector3(sample.x, sample.y, sample.z)
                guard normalization.contains(position) else {
                    continue
                }

                let renderedPosition = normalization.renderPosition(for: position)
                renderPoints.append(
                    RenderPoint(
                        position: renderedPosition,
                        color: SIMD4<Float>(
                            min(max(sample.r, 0), 1),
                            min(max(sample.g, 0), 1),
                            min(max(sample.b, 0), 1),
                            1
                        ),
                        normal: normalized(SCNVector3(sample.normalX, sample.normalY, sample.normalZ)),
                        radius: min(max(sample.radius * normalization.scale, 0.0035), 0.075)
                    )
                )
            }

            return renderPoints
        }

        private func cameraCalibration(for sample: SpatialScanFrameSample) -> CameraCalibration? {
            guard let cameraTransform = matrix4x4(from: sample.cameraTransform),
                  let intrinsics = cameraIntrinsics(from: sample.cameraIntrinsics) else {
                return nil
            }

            return CameraCalibration(
                cameraTransform: cameraTransform,
                inverseCameraTransform: cameraTransform.inverse,
                fx: intrinsics.fx,
                fy: intrinsics.fy,
                cx: intrinsics.cx,
                cy: intrinsics.cy,
                imageWidth: Float(max(sample.imageWidth, 1)),
                imageHeight: Float(max(sample.imageHeight, 1))
            )
        }

        private func project(
            worldPosition: SIMD3<Float>,
            calibration: CameraCalibration
        ) -> ProjectionSample? {
            let cameraPoint = calibration.inverseCameraTransform * SIMD4<Float>(
                worldPosition.x,
                worldPosition.y,
                worldPosition.z,
                1
            )
            let depth = -cameraPoint.z
            guard depth > 0.05 else { return nil }

            let projectedX = (calibration.fx * (cameraPoint.x / depth)) + calibration.cx
            let projectedY = (calibration.fy * (-cameraPoint.y / depth)) + calibration.cy
            guard projectedX.isFinite, projectedY.isFinite else { return nil }
            guard projectedX >= 0, projectedX < calibration.imageWidth,
                  projectedY >= 0, projectedY < calibration.imageHeight else {
                return nil
            }

            return ProjectionSample(pixel: SIMD2<Float>(projectedX, projectedY), depth: depth)
        }

        private func unproject(
            pixel: SIMD2<Float>,
            depth: Float,
            calibration: CameraCalibration
        ) -> SIMD3<Float>? {
            guard depth.isFinite, depth > 0 else { return nil }
            let cameraX = ((pixel.x - calibration.cx) / max(calibration.fx, 0.0001)) * depth
            let cameraY = -((pixel.y - calibration.cy) / max(calibration.fy, 0.0001)) * depth
            let cameraPoint = SIMD4<Float>(cameraX, cameraY, -depth, 1)
            let worldPoint = calibration.cameraTransform * cameraPoint
            guard worldPoint.x.isFinite, worldPoint.y.isFinite, worldPoint.z.isFinite else {
                return nil
            }
            return SIMD3<Float>(worldPoint.x, worldPoint.y, worldPoint.z)
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

        private func matrix4x4(from values: [Float]) -> simd_float4x4? {
            guard values.count >= 16 else { return nil }
            return simd_float4x4(
                SIMD4<Float>(values[0], values[1], values[2], values[3]),
                SIMD4<Float>(values[4], values[5], values[6], values[7]),
                SIMD4<Float>(values[8], values[9], values[10], values[11]),
                SIMD4<Float>(values[12], values[13], values[14], values[15])
            )
        }

        private func cameraIntrinsics(from values: [Float]) -> (fx: Float, fy: Float, cx: Float, cy: Float)? {
            guard values.count >= 9 else { return nil }
            return (fx: values[0], fy: values[4], cx: values[6], cy: values[7])
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

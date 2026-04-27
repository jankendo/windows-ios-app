import SwiftUI
import UIKit

struct SpatialScanPlaybackView: View {
    let entry: MemoryEntry

    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var player = AudioPlayerController()
    @State private var waveformSamples: [CGFloat] = Array(repeating: 0.25, count: 40)
    @State private var previewImage: UIImage?
    @State private var frameItems: [SpatialScanPlaybackFrame] = []
    @State private var selectedFrameIndex = 0
    @State private var isSequencePlaying = false
    @State private var framePlaybackTask: Task<Void, Never>?

    private var palette: ResonancePalette {
        ResonancePalette.make(for: colorScheme, atmosphere: entry.atmosphereStyle)
    }

    private var storedSpatialScan: StoredSpatialScan? {
        entry.storedSpatialScan
    }

    private var manifest: SpatialScanManifest? {
        entry.spatialScanManifest
    }

    private var playbackURL: URL? {
        entry.analysisAudioURL ?? entry.audioURL
    }

    private var currentFrame: SpatialScanPlaybackFrame? {
        guard frameItems.indices.contains(selectedFrameIndex) else { return nil }
        return frameItems[selectedFrameIndex]
    }

    private var displayedImage: UIImage? {
        currentFrame?.image ?? previewImage
    }

    private var sequencePlaybackInterval: TimeInterval {
        guard frameItems.count > 1 else { return 0.45 }
        let referenceDuration = max(
            entry.spatialScanCaptureDuration ?? manifest?.normalizedCaptureDuration ?? Double(frameItems.count) * 0.35,
            Double(frameItems.count) * 0.12
        )
        return min(max(referenceDuration / Double(frameItems.count), 0.16), 0.65)
    }

    private var audioDuration: TimeInterval {
        max(player.duration, entry.audioDuration)
    }

    private var syncableBytesText: String {
        formattedByteCount(for: entry.spatialScanSyncMetadata?.syncableAssets ?? [])
    }

    private var localOnlyBytesText: String {
        formattedByteCount(for: entry.spatialScanSyncMetadata?.localOnlyAssets ?? [])
    }

    var body: some View {
        ZStack {
            ResonanceGradientBackground(atmosphere: entry.atmosphereStyle)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    previewCard
                    scrubberCard
                    reconstructionCard
                    assetCard
                }
                .padding(20)
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

    private var previewCard: some View {
        ResonanceCard(atmosphere: entry.atmosphereStyle) {
            VStack(alignment: .leading, spacing: 14) {
                ZStack(alignment: .bottomLeading) {
                    Group {
                        if let displayedImage {
                            Image(uiImage: displayedImage)
                                .resizable()
                                .scaledToFill()
                        } else {
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .fill(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.18))
                                .overlay {
                                    VStack(spacing: 10) {
                                        Image(systemName: "cube")
                                            .font(.system(size: 36, weight: .semibold))
                                        Text("プレビューを準備できませんでした")
                                            .font(.subheadline.weight(.semibold))
                                    }
                                    .foregroundStyle(palette.secondaryText)
                                }
                        }
                    }
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay {
                        LinearGradient(
                            colors: [Color.black.opacity(0.06), .clear, Color.black.opacity(0.54)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            ResonanceBadge(
                                title: entry.spatialScanDisplayLabel,
                                systemImage: "cube",
                                tint: .white,
                                atmosphere: entry.atmosphereStyle
                            )
                            if entry.spatialScanWorldMapURL != nil {
                                ResonanceBadge(
                                    title: "World Map",
                                    systemImage: "globe.asia.australia.fill",
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

                        Text(entry.displayTitle)
                            .font(.title3.bold())
                            .foregroundStyle(.white)

                        Text(frameOverlaySubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.86))
                    }
                    .padding(18)
                }

                Text("今は保存済み preview と frame sequence で安全に見返します。derived reconstruction asset が追加されると、この画面へそのまま拡張できます。")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)

                HStack(spacing: 10) {
                    Button {
                        toggleSequencePlayback()
                    } label: {
                        Label(
                            isSequencePlaying ? "フレーム再生を停止" : "フレームを再生",
                            systemImage: isSequencePlaying ? "pause.fill" : "play.fill"
                        )
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
                    .disabled(frameItems.count < 2)

                    if let playbackURL {
                        Button {
                            player.togglePlayback(for: playbackURL)
                        } label: {
                            Label(
                                player.isPlaying ? "録音を停止" : "録音を再生",
                                systemImage: player.isPlaying ? "waveform.circle.fill" : "waveform.circle"
                            )
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                        .tint(palette.accent)
                    }
                }

                if playbackURL != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        AudioWaveformView(
                            samples: waveformSamples,
                            progress: audioDuration > 0 ? player.currentTime / audioDuration : 0,
                            activeColor: palette.accent,
                            inactiveColor: palette.accent.opacity(0.16),
                            minimumBarHeight: 10
                        )
                        .frame(height: 30)

                        Slider(
                            value: Binding(
                                get: { player.currentTime },
                                set: { player.seek(to: $0) }
                            ),
                            in: 0...max(audioDuration, 1)
                        )
                        .tint(palette.accent)

                        HStack {
                            Text(player.currentTime.resonanceClockText)
                            Spacer()
                            Text(audioDuration.resonanceClockText)
                        }
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                    }
                }
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

                Text("時系列に沿って frame を送り、再構成前でもその場を見返せる vertical slice です。")
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
                                    Image(uiImage: frame.image)
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
                SpatialScanMetricRow(title: "フレーム数", value: "\(entry.spatialScanFrameCount) 枚")

                if let duration = entry.spatialScanCaptureDuration {
                    SpatialScanMetricRow(title: "収集時間", value: String(format: "%.1f 秒", duration))
                }

                if let summary = entry.spatialScanPreparationSummary {
                    SpatialScanMetricRow(title: "Coverage", value: "\(Int((summary.coverageScore * 100).rounded()))%")
                    SpatialScanMetricRow(title: "Proxy keyframes", value: "\(summary.selectedProxyFrameCount) 枚")
                    SpatialScanMetricRow(title: "移動量", value: String(format: "%.2f m", summary.translationExtentMeters))
                    SpatialScanMetricRow(title: "回頭レンジ", value: String(format: "%.0f°", summary.headingSpanDegrees))
                }

                SpatialScanMetricRow(
                    title: "空間アンカー",
                    value: entry.spatialScanWorldMapURL == nil ? "未保存" : "World Map 保存済み"
                )

                if let processedAt = entry.spatialScanLastProcessedAt {
                    SpatialScanMetricRow(title: "最終処理", value: processedAt.formatted(date: .abbreviated, time: .shortened))
                }

                if let finalReadyAt = entry.spatialScanFinalReadyAt {
                    SpatialScanMetricRow(title: "Final ready", value: finalReadyAt.formatted(date: .abbreviated, time: .shortened))
                }

                if let statusMessage = entry.spatialScanReconstructionJob?.lastStatusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                }

                if let failure = entry.spatialScanReconstructionJob?.lastFailure {
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

                if let syncMetadata = entry.spatialScanSyncMetadata {
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

                if let proxyRequestFileName = entry.spatialScanProxyRequestFileName {
                    SpatialScanAssetRow(relativePath: proxyRequestFileName, byteCount: assetByteCount(for: proxyRequestFileName))
                }

                if let highQualityRequestFileName = entry.spatialScanHighQualityRequestFileName {
                    SpatialScanAssetRow(relativePath: highQualityRequestFileName, byteCount: assetByteCount(for: highQualityRequestFileName))
                }

                if entry.spatialScanDerivedAssets.isEmpty {
                    Text("derived asset はまだありません。現在は preview / frame sequence / reconstruction request を future renderer への接続面として保持しています。")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                } else {
                    ForEach(entry.spatialScanDerivedAssets) { asset in
                        SpatialScanAssetRow(relativePath: asset.relativePath, byteCount: asset.byteCount)
                    }
                }
            }
        }
    }

    private var frameOverlaySubtitle: String {
        let frameLabel = "\(entry.spatialScanFrameCount) 枚"
        let durationLabel: String
        if let duration = entry.spatialScanCaptureDuration {
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
        switch entry.spatialScanReconstructionState {
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
        previewImage = loadPreviewImage()
        frameItems = loadFrameItems()
        selectedFrameIndex = min(selectedFrameIndex, max(frameItems.count - 1, 0))
        player.setPlaybackEnvelope(waveformSamples)
        if let playbackURL {
            player.load(url: playbackURL, autoPlay: false, loop: false, volume: 0.82)
        }
    }

    private func loadPreviewImage() -> UIImage? {
        if let previewURL = entry.spatialScanPreviewURL,
           let image = UIImage(contentsOfFile: previewURL.path) {
            return image
        }
        return UIImage(contentsOfFile: entry.photoURL.path)
    }

    private func loadFrameItems() -> [SpatialScanPlaybackFrame] {
        guard let storedSpatialScan, let manifest else {
            return []
        }

        return manifest.frameSamples.enumerated().compactMap { index, frameSample in
            guard
                let frameURL = MediaStore.spatialScanAssetURL(relativePath: frameSample.imageFileName, for: storedSpatialScan),
                let image = UIImage(contentsOfFile: frameURL.path)
            else {
                return nil
            }

            return SpatialScanPlaybackFrame(
                index: index,
                sample: frameSample,
                fileURL: frameURL,
                image: image
            )
        }
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
    let image: UIImage

    var id: String {
        "\(index)-\(fileURL.lastPathComponent)"
    }
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
                .fill(ResonancePalette.make(for: .dark, atmosphere: atmosphere).cardFill.opacity(0.72))
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

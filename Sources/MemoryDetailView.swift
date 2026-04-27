import SwiftData
import SwiftUI
import UIKit

struct MemoryDetailView: View {
    @Bindable var entry: MemoryEntry
    @Query(sort: \MemoryEntry.createdAt, order: .reverse) private var allEntries: [MemoryEntry]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var player = AudioPlayerController()
    @State private var waveformSamples: [CGFloat] = Array(repeating: 0.25, count: 40)
    @State private var showingEditor = false
    @State private var showingDeleteConfirmation = false
    @State private var showingShareSheet = false
    @State private var showingAutoTags = false
    @State private var showingImmersivePreview = false
    @State private var resolvedPhotoCaption: String?
    @State private var selectedCaptionStyle: PhotoCaptionStyle = .poetic
    @State private var captionGenerationMessage: String?
    @State private var isRegeneratingCaption = false
    @State private var relatedEntriesSnapshot: [MemoryEntry] = []
    @State private var relatedEntriesRefreshTask: Task<Void, Never>?

    private var palette: ResonancePalette {
        ResonancePalette.make(for: colorScheme, atmosphere: entry.atmosphereStyle)
    }

    private var playbackURL: URL? {
        entry.analysisAudioURL ?? entry.audioURL
    }

    private var shareItems: [Any] {
        var items: [Any] = [entry.shareSummary, entry.photoURL]
        if let audioURL = entry.audioURL {
            items.append(audioURL)
        }
        return items
    }

    var body: some View {
        ZStack {
            ResonanceGradientBackground(atmosphere: entry.atmosphereStyle)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heroScene

                    if !entry.notes.isEmpty {
                        ResonanceCard(atmosphere: entry.atmosphereStyle) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("メモ")
                                    .font(.headline)
                                    .foregroundStyle(palette.primaryText)
                                Text(entry.notes)
                                    .font(.body)
                                    .foregroundStyle(palette.primaryText)
                            }
                        }
                    }

                    captionStyleCard

                    if entry.sensorSnapshot != nil
                        || entry.minimumDecibels != nil
                        || entry.maximumDecibels != nil {
                        ResonanceCard(atmosphere: entry.atmosphereStyle) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("空間センサー")
                                    .font(.headline)
                                    .foregroundStyle(palette.primaryText)

                                SensorDetailRow(title: "場所", value: entry.placeLabel ?? "取得なし")

                                if let sensorSnapshot = entry.sensorSnapshot,
                                   let latitude = sensorSnapshot.latitude,
                                   let longitude = sensorSnapshot.longitude {
                                    SensorDetailRow(title: "座標", value: String(format: "%.6f, %.6f", latitude, longitude))
                                }
                                if let horizontalAccuracy = entry.sensorSnapshot?.horizontalAccuracy {
                                    SensorDetailRow(title: "水平精度", value: String(format: "±%.1f m", horizontalAccuracy))
                                }
                                if let altitude = entry.sensorSnapshot?.altitude {
                                    SensorDetailRow(title: "標高", value: String(format: "%.0f m", altitude))
                                }
                                if let pressure = entry.sensorSnapshot?.pressureKilopascals {
                                    SensorDetailRow(title: "気圧", value: String(format: "%.1f kPa", pressure))
                                }
                                if let minimumDecibels = entry.minimumDecibels, let maximumDecibels = entry.maximumDecibels {
                                    SensorDetailRow(title: "音量", value: String(format: "最小 %.1f dB / 最大 %.1f dB", minimumDecibels, maximumDecibels))
                                }
                                if let heading = entry.sensorSnapshot?.heading {
                                    SensorDetailRow(title: "方角", value: String(format: "%.0f°", heading))
                                }
                                if let orientation = entry.sensorSnapshot?.deviceOrientationLabel {
                                    SensorDetailRow(title: "端末向き", value: orientation)
                                }
                            }
                        }
                    }

                    if !entry.transcript.isEmpty {
                        ResonanceCard(atmosphere: entry.atmosphereStyle) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("文字起こし")
                                    .font(.headline)
                                    .foregroundStyle(palette.primaryText)
                                Text(entry.transcript)
                                    .foregroundStyle(palette.secondaryText)
                            }
                        }
                    }

                    ResonanceCard(atmosphere: entry.atmosphereStyle) {
                        DisclosureGroup(isExpanded: $showingAutoTags) {
                            VStack(alignment: .leading, spacing: 12) {
                                if entry.autoTags.isEmpty {
                                    Text("まだ自動タグはありません。")
                                        .font(.subheadline)
                                        .foregroundStyle(palette.secondaryText)
                                } else {
                                    FlexibleTagCloud(tags: entry.autoTags, atmosphere: entry.atmosphereStyle)
                                }
                            }
                            .padding(.top, 12)
                        } label: {
                            Label("自動タグ", systemImage: "tag")
                                .font(.headline)
                                .foregroundStyle(palette.primaryText)
                        }
                    }

                    if !relatedEntriesSnapshot.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("関連する記録")
                                .font(.headline)
                                .foregroundStyle(palette.primaryText)

                            ForEach(relatedEntriesSnapshot) { related in
                                NavigationLink {
                                    MemoryDetailView(entry: related)
                                } label: {
                                    MemoryCardView(entry: related)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("記録")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showingShareSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }

                Menu {
                    Button("編集") {
                        showingEditor = true
                    }

                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("削除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            MemoryEditView(entry: entry)
        }
        .sheet(isPresented: $showingShareSheet) {
            ShareSheet(items: shareItems)
        }
        .fullScreenCover(isPresented: $showingImmersivePreview) {
            SavedMemoryImmersivePreviewView(entry: entry)
        }
        .alert("この記録を削除しますか？", isPresented: $showingDeleteConfirmation) {
            Button("削除", role: .destructive) {
                deleteEntry()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("写真、音声、メモ情報がこの端末から削除されます。")
        }
        .onAppear {
            waveformSamples = entry.waveformFingerprint
            resolvedPhotoCaption = entry.photoCaption
            selectedCaptionStyle = entry.photoCaptionStyle
            scheduleRelatedEntriesRefresh()
            if let playbackURL {
                player.load(url: playbackURL)
            }
            Task {
                await backfillPhotoCaptionIfNeeded()
            }
        }
        .onChange(of: allEntries.count) { _, _ in
            scheduleRelatedEntriesRefresh()
        }
        .onDisappear {
            relatedEntriesRefreshTask?.cancel()
            player.stop()
        }
    }

    private func scheduleRelatedEntriesRefresh() {
        relatedEntriesRefreshTask?.cancel()
        let candidates = Array(allEntries.prefix(60))
        relatedEntriesRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard !Task.isCancelled else { return }
            relatedEntriesSnapshot = MemorySearchEngine.similarEntries(to: entry, from: candidates, limit: 3)
        }
    }

    private var heroScene: some View {
        ZStack(alignment: .bottomLeading) {
            MemoryHeroImage(entry: entry)
                .overlay {
                    ResonanceHeroScrim(atmosphere: entry.atmosphereStyle)
                        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                }

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.displayTitle)
                            .font(.largeTitle.bold())
                            .foregroundStyle(.white)

                        Text(resolvedPhotoCaption ?? entry.descriptiveCaption)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.84))

                if let source = entry.photoCaptionSource {
                    ResonanceBadge(
                        title: "\(source.localizedLabel) • \(selectedCaptionStyle.localizedLabel)",
                        systemImage: source.systemImage,
                        tint: .white,
                        atmosphere: entry.atmosphereStyle
                    )
                }
                    }

                    Spacer()

                    Button {
                        entry.isFavorite.toggle()
                        try? modelContext.save()
                    } label: {
                        Image(systemName: entry.isFavorite ? "heart.fill" : "heart")
                            .font(.title3)
                            .foregroundStyle(entry.isFavorite ? .pink : .white.opacity(0.88))
                    }
                    .buttonStyle(.plain)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ResonanceBadge(title: entry.localizedMood, systemImage: "sparkles", tint: .white, atmosphere: entry.atmosphereStyle)
                        ResonanceBadge(title: entry.atmosphereStyle.localizedLabel, systemImage: entry.atmosphereStyle.symbolName, tint: .white, atmosphere: entry.atmosphereStyle)
                        if let placeLabel = entry.placeLabel {
                            ResonanceBadge(title: placeLabel, systemImage: "location.fill", tint: .white, atmosphere: entry.atmosphereStyle)
                        }
                        if entry.hasAudio {
                            ResonanceBadge(title: "\(Int(entry.audioDuration.rounded()))秒", systemImage: "waveform", tint: .white, atmosphere: entry.atmosphereStyle)
                        }
                    }
                }

                if let playbackURL {
                    ResonanceCard(atmosphere: entry.atmosphereStyle) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Label("空気の再生", systemImage: "waveform")
                                    .font(.headline)
                                    .foregroundStyle(palette.primaryText)
                                Spacer()
                                Button {
                                    player.togglePlayback(for: playbackURL)
                                } label: {
                                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                        .font(.system(size: 34))
                                        .foregroundStyle(palette.accent)
                                }
                                .buttonStyle(.plain)
                            }

                            AudioWaveformView(
                                samples: waveformSamples,
                                progress: player.duration > 0 ? player.currentTime / player.duration : 0,
                                activeColor: palette.accent,
                                inactiveColor: Color.white.opacity(colorScheme == .dark ? 0.2 : 0.26),
                                minimumBarHeight: 10
                            )

                            Slider(
                                value: Binding(
                                    get: { player.currentTime },
                                    set: { player.seek(to: $0) }
                                ),
                                in: 0...max(max(player.duration, entry.audioDuration), 1)
                            )
                            .tint(palette.accent)

                            HStack {
                                Text(player.currentTime.resonanceClockText)
                                    .font(.caption)
                                    .foregroundStyle(palette.secondaryText)
                                Spacer()
                                Text(entry.createdAt.formatted(date: .complete, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(palette.secondaryText)
                            }

                            AudioDiagnosticsPanel(palette: palette)

                            Button {
                                showingImmersivePreview = true
                            } label: {
                                Label("写真と録音を全画面でプレビュー", systemImage: "arrow.up.left.and.arrow.down.right")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(palette.accent)
                        }
                    }
                }
            }
            .padding(22)
        }
    }

    private func deleteEntry() {
        MediaStore.deleteAssets(for: entry)
        modelContext.delete(entry)
        try? modelContext.save()
        dismiss()
    }

    private var captionStyleCard: some View {
        ResonanceCard(atmosphere: entry.atmosphereStyle) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("キャプション文体")
                            .font(.headline)
                            .foregroundStyle(palette.primaryText)
                        Text(selectedCaptionStyle.localizedDescription)
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                    }

                    Spacer()

                    Menu {
                        ForEach(PhotoCaptionStyle.allCases) { style in
                            Button {
                                selectedCaptionStyle = style
                            } label: {
                                if style == selectedCaptionStyle {
                                    Label(style.localizedLabel, systemImage: "checkmark")
                                } else {
                                    Text(style.localizedLabel)
                                }
                            }
                        }
                    } label: {
                        Label(selectedCaptionStyle.localizedLabel, systemImage: "text.quote")
                            .font(.caption.weight(.semibold))
                    }
                }

                Button {
                    regenerateCaption()
                } label: {
                    Label(isRegeneratingCaption ? "再生成中…" : "この文体で再生成", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .disabled(isRegeneratingCaption)

                if let captionGenerationMessage, !captionGenerationMessage.isEmpty {
                    Text(captionGenerationMessage)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                }
            }
        }
    }

    private func backfillPhotoCaptionIfNeeded() async {
        let needsCaptionRefresh = entry.atmosphereMetadata?.needsPhotoCaptionRefresh ?? true
        guard needsCaptionRefresh || resolvedPhotoCaption == nil else { return }
        guard let imageData = try? Data(contentsOf: entry.photoURL) else { return }
        guard let generation = await MemoryAnalysisService.captionGeneration(
            from: imageData,
            title: entry.title,
            placeLabel: entry.placeLabel
        ) else { return }

        await MainActor.run {
            resolvedPhotoCaption = generation.text
        }

        try? MediaStore.updateAtmosphereMetadata(for: entry.id) { metadata in
            metadata.photoCaption = generation.text
            metadata.photoCaptionSourceRaw = generation.source.rawValue
            metadata.photoCaptionStyleRaw = generation.style.rawValue
            metadata.photoCaptionVersion = MemoryAtmosphereMetadata.currentPhotoCaptionVersion
        }
    }

    private func regenerateCaption() {
        guard let imageData = try? Data(contentsOf: entry.photoURL) else { return }

        isRegeneratingCaption = true
        captionGenerationMessage = nil

        Task {
            let generation = await MemoryAnalysisService.captionGeneration(
                from: imageData,
                title: entry.title,
                placeLabel: entry.placeLabel,
                style: selectedCaptionStyle
            )

            await MainActor.run {
                defer { isRegeneratingCaption = false }
                guard let generation else {
                    captionGenerationMessage = "キャプションを再生成できませんでした。"
                    return
                }

                resolvedPhotoCaption = generation.text
                captionGenerationMessage = "\(generation.style.localizedLabel)で更新しました。"

                try? MediaStore.updateAtmosphereMetadata(for: entry.id) { metadata in
                    metadata.photoCaption = generation.text
                    metadata.photoCaptionSourceRaw = generation.source.rawValue
                    metadata.photoCaptionStyleRaw = generation.style.rawValue
                    metadata.photoCaptionVersion = MemoryAtmosphereMetadata.currentPhotoCaptionVersion
                }
            }
        }
    }

}

private struct SensorDetailRow: View {
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

private struct MemoryHeroImage: View {
    let entry: MemoryEntry

    var body: some View {
        Group {
            if let image = UIImage(contentsOfFile: entry.photoURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 32)
                    .fill(.gray.opacity(0.15))
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 460)
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
    }
}

private struct SavedMemoryImmersivePreviewView: View {
    let entry: MemoryEntry

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var environmentService = CaptureLocationService.shared
    @StateObject private var viewModel = ImmersivePlaybackViewModel()
    @State private var controlsVisible = true
    @State private var dragOffset: CGSize = .zero
    @State private var saliencyFocus = CGPoint(x: 0.5, y: 0.5)
    @State private var kenBurnsExpanded = false

    private var palette: ResonancePalette {
        ResonancePalette.make(for: colorScheme, atmosphere: entry.atmosphereStyle)
    }

    private var playbackURL: URL? {
        entry.analysisAudioURL ?? entry.audioURL
    }

    private var motionHorizontalShift: CGFloat {
        if reduceMotion {
            return dragOffset.width * 0.08
        }
        return dragOffset.width * 0.18 + environmentService.previewHorizontalShift
    }

    private var motionVerticalShift: CGFloat {
        if reduceMotion {
            return dragOffset.height * 0.05
        }
        return dragOffset.height * 0.1 + environmentService.previewVerticalShift
    }

    private var saliencyShift: CGSize {
        guard !reduceMotion else { return .zero }
        return CGSize(
            width: (saliencyFocus.x - 0.5) * -42,
            height: (saliencyFocus.y - 0.5) * -30
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image = UIImage(contentsOfFile: entry.photoURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(reduceMotion ? 1.04 : (kenBurnsExpanded ? 1.12 : 1.04))
                    .offset(
                        x: motionHorizontalShift + saliencyShift.width,
                        y: motionVerticalShift + saliencyShift.height
                    )
                    .rotation3DEffect(.degrees(reduceMotion ? 0 : Double(-environmentService.previewHorizontalShift) * 0.16), axis: (x: 0, y: 1, z: 0))
                    .rotation3DEffect(.degrees(reduceMotion ? 0 : Double(environmentService.previewVerticalShift) * 0.1), axis: (x: 1, y: 0, z: 0))
                    .ignoresSafeArea()
                    .animation(reduceMotion ? .default : .linear(duration: 20).repeatForever(autoreverses: true), value: kenBurnsExpanded)
            }

            LinearGradient(
                colors: [Color.black.opacity(0.08), .clear, Color.black.opacity(0.58)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

                    AtmosphericImmersiveOverlay(
                        atmosphere: entry.atmosphereStyle,
                        snapshot: entry.sensorSnapshot,
                        audioReactiveLevel: viewModel.player.reactiveLevel,
                        hotspots: entry.directionalHotspots,
                        headingDegrees: viewModel.hotspotHeadingDegrees
                    )
                    .ignoresSafeArea()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.38)) {
                controlsVisible.toggle()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    dragOffset = value.translation
                    viewModel.updateDrag(value.translation)
                }
                .onEnded { _ in
                    withAnimation(.interactiveSpring(response: 0.62, dampingFraction: 0.88, blendDuration: 0.16)) {
                        dragOffset = .zero
                    }
                    viewModel.resetDrag()
                }
        )
        .safeAreaInset(edge: .top) {
            if controlsVisible {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay {
                                Circle()
                                    .strokeBorder(.white.opacity(colorScheme == .dark ? 0.16 : 0.22))
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("閉じる")

                    Spacer()

                    ResonanceBadge(
                        title: entry.atmosphereStyle.localizedLabel,
                        systemImage: entry.atmosphereStyle.symbolName,
                        tint: .white,
                        atmosphere: entry.atmosphereStyle
                    )
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if controlsVisible {
                ViewThatFits(in: .vertical) {
                    previewPanel(compact: false)
                    previewPanel(compact: true)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .onAppear {
            viewModel.loadAmbientLoop(
                playbackURL: playbackURL,
                analysisURL: entry.analysisAudioURL,
                waveform: entry.waveformFingerprint,
                loopRange: {
                    guard let start = entry.seamlessLoopStartPoint, let end = entry.seamlessLoopEndPoint else { return nil }
                    return start...end
                }(),
                volume: 0.78
            )
            viewModel.updateBaseSpatialOffset(environmentService.previewParallax)
            viewModel.startMotionTracking()
            kenBurnsExpanded = true
            if let image = UIImage(contentsOfFile: entry.photoURL.path) {
                Task {
                    saliencyFocus = await SaliencyFocusResolver.focusPoint(for: image)
                }
            }
        }
        .onChange(of: environmentService.previewParallax) { _, newValue in
            viewModel.updateBaseSpatialOffset(newValue)
        }
        .onDisappear {
            viewModel.stop()
        }
    }

    @ViewBuilder
    private var previewPlayButton: some View {
        if let playbackURL {
            Button {
                viewModel.togglePlayback()
            } label: {
                Image(systemName: viewModel.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(.white.opacity(colorScheme == .dark ? 0.16 : 0.22))
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.player.isPlaying ? "一時停止" : "再生")
        }
    }

    private func previewTexts(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            if entry.isSpatialCapture {
                Label("空間オーディオ", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
            }

            Text(entry.displayTitle)
                .font(compact ? .headline.weight(.semibold) : .title3.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(compact ? 1 : 2)
                .minimumScaleFactor(0.9)
                .fixedSize(horizontal: false, vertical: true)

            Text(entry.descriptiveCaption)
                .font(compact ? .caption : .subheadline)
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(compact ? 2 : 3)
                .fixedSize(horizontal: false, vertical: true)

            if !compact {
                Text(entry.atmosphereStyle.restorativeLine)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(entry.atmosphereStyle.guidedBreathLine)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func previewPanel(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    previewTexts(compact: compact)
                    previewPlayButton
                }

                VStack(alignment: .leading, spacing: compact ? 12 : 16) {
                    previewTexts(compact: compact)

                    HStack {
                        Spacer()
                        previewPlayButton
                    }
                }
            }

            AudioWaveformView(
                samples: entry.waveformFingerprint,
                progress: viewModel.player.duration > 0 ? viewModel.player.currentTime / viewModel.player.duration : 0,
                activeColor: .white,
                inactiveColor: Color.white.opacity(0.14),
                minimumBarHeight: compact ? 8 : 10
            )
            .frame(height: compact ? 30 : 38)
            .accessibilityHidden(true)

            HStack {
                Text(viewModel.player.currentTime.resonanceClockText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.74))

                Spacer(minLength: 12)

                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
            }
        }
        .padding(compact ? 15 : 18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(.white.opacity(colorScheme == .dark ? 0.16 : 0.22))
        }
        .shadow(color: palette.shadow.opacity(colorScheme == .dark ? 0.55 : 0.18), radius: 28, y: 16)
    }
}

private struct FlexibleTagCloud: View {
    @Environment(\.colorScheme) private var colorScheme
    let tags: [String]
    let atmosphere: AtmosphereStyle

    var body: some View {
        let palette = ResonancePalette.make(for: colorScheme, atmosphere: atmosphere)

        VStack(alignment: .leading, spacing: 8) {
            ForEach(chunkedTags, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { tag in
                        Text(tag)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(palette.accentSoft, in: Capsule())
                            .foregroundStyle(palette.primaryText)
                    }
                }
            }
        }
    }

    private var chunkedTags: [[String]] {
        stride(from: 0, to: tags.count, by: 3).map { start in
            Array(tags[start..<min(start + 3, tags.count)])
        }
    }
}

private struct MemoryEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var entry: MemoryEntry

    var body: some View {
        NavigationStack {
            Form {
                TextField("タイトル", text: $entry.title)
                    .writingToolsBehavior(.complete)
                TextField("メモ", text: $entry.notes, axis: .vertical)
                    .lineLimit(4...8)
                    .writingToolsBehavior(.complete)
            }
            .navigationTitle("記録を編集")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        try? modelContext.save()
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        MemoryDetailView(
            entry: MemoryEntry(
                title: "Evening Walk",
                notes: "Wind, street lights, and a soft jazz leak from the cafe.",
                photoFileName: "",
                audioFileName: nil,
                audioDuration: 0,
                visualTags: ["street", "night"],
                audioTags: ["music", "traffic"],
                transcript: "Nice to meet you",
                mood: MemoryMood.urban.rawValue
            )
        )
    }
    .modelContainer(ResonancePersistence.makeContainer(inMemory: true))
}

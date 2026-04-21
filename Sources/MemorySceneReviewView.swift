import SwiftUI
import UIKit

struct MemorySceneReviewView: View {
    let draft: CapturedMemoryDraft
    @Binding var title: String
    @Binding var notes: String
    let isSaving: Bool
    let isRegeneratingCaption: Bool
    let captionGenerationMessage: String?
    let onRetake: () -> Void
    let onRegenerateCaption: () -> Void
    let onSave: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedField: ReviewField?
    @StateObject private var player = AudioPlayerController()
    @State private var waveformSamples: [CGFloat] = Array(repeating: 0.18, count: 64)
    @State private var showingImmersivePreview = false
    @State private var showingNotesField = false
    @State private var showingDetails = false

    private enum ReviewField {
        case title
        case notes
    }

    private var atmosphere: AtmosphereStyle {
        draft.atmosphereStyle
    }

    private var palette: ResonancePalette {
        ResonancePalette.make(for: colorScheme, atmosphere: atmosphere)
    }

    private var weatherSummaryText: String {
        draft.weatherSnapshot?.compactSummary ?? "取得なし"
    }

    private var previewDisplayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? "深呼吸して、この空気にとどまる" : trimmedTitle
    }

    private var previewDisplayCaption: String {
        let trimmedCaption = draft.photoCaption?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmedCaption?.isEmpty == false) ? trimmedCaption! : atmosphere.poeticLine
    }

    var body: some View {
        GeometryReader { geometry in
            let panelHeight = composerPanelHeight(in: geometry)
            ZStack(alignment: .bottom) {
                Color.black.ignoresSafeArea()

                photoStage(bottomInset: panelHeight + geometry.safeAreaInsets.bottom + 28)

                ResonanceHeroScrim(atmosphere: atmosphere)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                        .padding(.horizontal, 20)
                        .padding(.top, max(geometry.safeAreaInsets.top, 14))
                        .padding(.bottom, 8)

                    Spacer()
                }

                composerPanel(height: panelHeight, bottomInset: geometry.safeAreaInsets.bottom)
            }
        }
        .interactiveDismissDisabled(isSaving)
        .fullScreenCover(isPresented: $showingImmersivePreview) {
            ImmersiveMemoryPlaybackView(
                draft: draft,
                title: title,
                waveformSamples: waveformSamples,
                atmosphere: atmosphere
            )
        }
        .onAppear {
            waveformSamples = WaveformExtractor.samples(from: draft.audioTempURL, sampleCount: 64)
            startLoopingAmbientPlayback()
        }
        .onChange(of: showingImmersivePreview) { _, isPresented in
            if isPresented {
                player.stop()
            } else {
                startLoopingAmbientPlayback()
            }
        }
        .onDisappear {
            player.stop()
        }
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            Button("撮り直す") {
                onRetake()
            }
            .buttonStyle(.bordered)
            .tint(.white)

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                ResonanceBadge(
                    title: atmosphere.localizedLabel,
                    systemImage: atmosphere.symbolName,
                    tint: .white,
                    atmosphere: atmosphere
                )

                Text(draft.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.84))
            }
        }
    }

    private func photoStage(bottomInset: CGFloat) -> some View {
        Button {
            showingImmersivePreview = true
        } label: {
            ZStack(alignment: .bottomLeading) {
                if let image = UIImage(data: draft.photoData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 12)
                        .padding(.top, 76)
                        .padding(.bottom, bottomInset)
                }

                LinearGradient(
                    colors: [Color.black.opacity(0.08), .clear, Color.black.opacity(0.58)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        ResonanceBadge(
                            title: atmosphere.localizedLabel,
                            systemImage: atmosphere.symbolName,
                            tint: .white,
                            atmosphere: atmosphere
                        )
                        if let weatherSummary = draft.weatherSnapshot?.compactSummary, !weatherSummary.isEmpty {
                            ResonanceBadge(
                                title: weatherSummary,
                                systemImage: draft.weatherSnapshot?.symbolName ?? "cloud.sun.fill",
                                tint: .white,
                                atmosphere: atmosphere
                            )
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(previewDisplayTitle)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)

                        Text(previewDisplayCaption)
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.84))
                            .lineLimit(3)

                        Text(atmosphere.restorativeLine)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(2)
                    }

                    AudioWaveformView(
                        samples: waveformSamples,
                        progress: player.duration > 0 ? player.currentTime / player.duration : 0,
                        activeColor: .white,
                        inactiveColor: Color.white.opacity(0.14),
                        minimumBarHeight: 10
                    )
                    .frame(height: 36)

                    HStack {
                        Label("静かに全画面でひらく", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.82))
                        Spacer()
                        Text(player.currentTime.resonanceClockText)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.72))
                    }
                }
                .padding(18)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(.white.opacity(colorScheme == .dark ? 0.16 : 0.22))
                }
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.14), radius: 28, y: 16)
                .padding(.horizontal, 20)
                .padding(.bottom, bottomInset + 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("全画面プレビュー")
        .accessibilityHint("写真を全画面で表示し、環境音をループ再生します。")
    }

    private func composerPanel(height: CGFloat, bottomInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(palette.stroke)
                .frame(width: 44, height: 5)
                .padding(.top, 10)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top) {
                            reviewHeadline
                            Spacer()
                            decibelSummary
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            reviewHeadline
                            decibelSummary
                        }
                    }

                    TextField("", text: $title, prompt: Text("例: 雨上がりの横浜、静かな余韻").foregroundStyle(palette.tertiaryText))
                        .focused($focusedField, equals: .title)
                        .resonanceInputField(atmosphere: atmosphere)
                        .textInputAutocapitalization(.sentences)
                        .writingToolsBehavior(.complete)

                    captionComposerCard

                    if showingNotesField {
                        TextField("", text: $notes, prompt: Text("その場の空気、温度、気持ち、聞こえたもの。").foregroundStyle(palette.tertiaryText), axis: .vertical)
                            .focused($focusedField, equals: .notes)
                            .lineLimit(3...5)
                            .resonanceInputField(atmosphere: atmosphere)
                            .writingToolsBehavior(.complete)
                    } else {
                        Button {
                            showingNotesField = true
                            focusedField = .notes
                        } label: {
                            Label("メモを追加", systemImage: "square.and.pencil")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(palette.accent)
                        }
                        .buttonStyle(.plain)
                    }

                    DisclosureGroup(isExpanded: $showingDetails) {
                        VStack(alignment: .leading, spacing: 10) {
                            detailLine(title: "日時", value: draft.capturedAt.formatted(date: .abbreviated, time: .shortened))
                            if let placeLabel = draft.placeLabel, !placeLabel.isEmpty {
                                detailLine(title: "場所", value: placeLabel)
                            }
                            detailLine(title: "天気", value: weatherSummaryText)
                            if let horizontalAccuracy = draft.sensorSnapshot?.horizontalAccuracy {
                                detailLine(title: "位置精度", value: String(format: "±%.1f m", horizontalAccuracy))
                            }
                        }
                        .padding(.top, 10)
                    } label: {
                        Text("詳細を表示")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.secondaryText)
                    }

                    if focusedField != nil {
                        HStack {
                            Spacer()
                            Button("キーボードを閉じる") {
                                focusedField = nil
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.secondaryText)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 14)
            }

            VStack(spacing: 10) {
                Button {
                    onSave()
                } label: {
                    Label(isSaving ? "保存中…" : "この空気を保存", systemImage: "sparkles.rectangle.stack.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .disabled(isSaving)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, max(bottomInset, 14))
            .background(palette.surfacePrimary.opacity(0.98))
        }
        .frame(maxWidth: .infinity, maxHeight: height + bottomInset, alignment: .top)
        .background(palette.surfacePrimary, in: UnevenRoundedRectangle(topLeadingRadius: 32, topTrailingRadius: 32))
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 32, topTrailingRadius: 32)
                .strokeBorder(palette.stroke.opacity(0.9))
        }
    }

    private var reviewHeadline: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("静かな仕上げ")
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.secondaryText)

            Text("記憶に名前を与える")
                .font(.title3.bold())
                .foregroundStyle(palette.primaryText)
        }
    }

    private var captionComposerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("余韻のことば")
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.secondaryText)

            Text(previewDisplayCaption)
                .font(.subheadline)
                .foregroundStyle(palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if let source = draft.photoCaptionSource {
                    ResonanceBadge(
                        title: source.localizedLabel,
                        systemImage: source.systemImage,
                        atmosphere: atmosphere
                    )
                }

                Spacer(minLength: 0)

                Button {
                    onRegenerateCaption()
                } label: {
                    Label(isRegeneratingCaption ? "AI再作成中..." : "AI内容を再作成", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(palette.accentSoft, in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.accent)
                .disabled(isRegeneratingCaption || isSaving)
            }

            if let captionGenerationMessage, !captionGenerationMessage.isEmpty {
                Text(captionGenerationMessage)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(palette.stroke)
        }
    }

    private var decibelSummary: some View {
        Group {
            if let minimumDecibels = draft.minimumDecibels, let maximumDecibels = draft.maximumDecibels {
                VStack(alignment: .leading, spacing: 4) {
                    Text("音量")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.secondaryText)
                    Text(String(format: "最小 %.1f / 最大 %.1f dB", minimumDecibels, maximumDecibels))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.primaryText)
                }
            }
        }
    }

    private func composerPanelHeight(in geometry: GeometryProxy) -> CGFloat {
        let availableHeight = geometry.size.height - geometry.safeAreaInsets.top
        return min(max(availableHeight * 0.42, 308), 392)
    }

    private func detailLine(title: String, value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top) {
                Text(title)
                    .foregroundStyle(palette.secondaryText)
                Spacer(minLength: 12)
                Text(value)
                    .fontWeight(.semibold)
                    .foregroundStyle(palette.primaryText)
                    .multilineTextAlignment(.trailing)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .foregroundStyle(palette.secondaryText)
                Text(value)
                    .fontWeight(.semibold)
                    .foregroundStyle(palette.primaryText)
                    .multilineTextAlignment(.leading)
            }
        }
        .font(.subheadline)
    }

    private func startLoopingAmbientPlayback() {
        if let audioURL = draft.audioTempURL {
            player.load(url: audioURL, autoPlay: true, loop: true, volume: 0.72)
        }
    }
}

private struct ImmersiveMemoryPlaybackView: View {
    let draft: CapturedMemoryDraft
    let title: String
    let waveformSamples: [CGFloat]
    let atmosphere: AtmosphereStyle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var environmentService = CaptureLocationService.shared
    @StateObject private var player = AudioPlayerController()
    @State private var controlsVisible = true
    @State private var dragOffset: CGSize = .zero

    private var palette: ResonancePalette {
        ResonancePalette.make(for: colorScheme, atmosphere: atmosphere)
    }

    private var immersiveTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? "静かに、この空気へ戻る" : trimmedTitle
    }

    private var immersiveCaption: String {
        let trimmedCaption = draft.photoCaption?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmedCaption?.isEmpty == false) ? trimmedCaption! : atmosphere.poeticLine
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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image = UIImage(data: draft.photoData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(reduceMotion ? 1.04 : 1.14)
                    .offset(
                        x: motionHorizontalShift,
                        y: motionVerticalShift
                    )
                    .rotation3DEffect(.degrees(reduceMotion ? 0 : Double(-environmentService.previewHorizontalShift) * 0.16), axis: (x: 0, y: 1, z: 0))
                    .rotation3DEffect(.degrees(reduceMotion ? 0 : Double(environmentService.previewVerticalShift) * 0.1), axis: (x: 1, y: 0, z: 0))
                    .ignoresSafeArea()
            }

            LinearGradient(
                colors: [Color.black.opacity(0.1), .clear, Color.black.opacity(0.58)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
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
                        title: atmosphere.localizedLabel,
                        systemImage: atmosphere.symbolName,
                        tint: .white,
                        atmosphere: atmosphere
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
                    immersivePanel(compact: false)
                    immersivePanel(compact: true)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.38)) {
                controlsVisible.toggle()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    dragOffset = value.translation
                    player.setPan(Float(value.translation.width / 180))
                }
                .onEnded { _ in
                    withAnimation(.interactiveSpring(response: 0.62, dampingFraction: 0.88, blendDuration: 0.16)) {
                        dragOffset = .zero
                    }
                    player.setPan(0)
                }
        )
        .onAppear {
            if let audioURL = draft.audioTempURL {
                player.load(url: audioURL, autoPlay: true, loop: true, volume: 0.78)
            }
        }
        .onDisappear {
            player.stop()
        }
    }

    @ViewBuilder
    private var immersivePlayButton: some View {
        if let audioURL = draft.audioTempURL {
            Button {
                player.togglePlayback(for: audioURL)
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
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
            .accessibilityLabel(player.isPlaying ? "一時停止" : "再生")
        }
    }

    private func immersiveTexts(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            Text(immersiveTitle)
                .font(compact ? .headline.weight(.semibold) : .title3.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(compact ? 1 : 2)
                .minimumScaleFactor(0.9)
                .fixedSize(horizontal: false, vertical: true)

            Text(immersiveCaption)
                .font(compact ? .caption : .subheadline)
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(compact ? 2 : 3)
                .fixedSize(horizontal: false, vertical: true)

            if !compact {
                Text(atmosphere.restorativeLine)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func immersivePanel(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    immersiveTexts(compact: compact)
                    immersivePlayButton
                }

                VStack(alignment: .leading, spacing: compact ? 12 : 16) {
                    immersiveTexts(compact: compact)
                    HStack {
                        Spacer()
                        immersivePlayButton
                    }
                }
            }

            AudioWaveformView(
                samples: waveformSamples,
                progress: player.duration > 0 ? player.currentTime / player.duration : 0,
                activeColor: .white,
                inactiveColor: Color.white.opacity(0.14),
                minimumBarHeight: compact ? 8 : 10
            )
            .frame(height: compact ? 30 : 38)
            .accessibilityHidden(true)

            HStack(alignment: .firstTextBaseline) {
                Text(player.currentTime.resonanceClockText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.74))

                Spacer(minLength: 12)

                Text(compact ? "そっと揺れます" : "そっと動かすと、気配が静かに揺れます")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(compact ? 1 : 2)
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

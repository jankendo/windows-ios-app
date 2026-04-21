import SwiftUI
import UIKit

struct MemorySceneReviewView: View {
    let draft: CapturedMemoryDraft
    @Binding var title: String
    @Binding var notes: String
    let isSaving: Bool
    let onRetake: () -> Void
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

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ResonanceGradientBackground(atmosphere: atmosphere)
                backgroundImage
                ResonanceHeroScrim(atmosphere: atmosphere)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                        .padding(.horizontal, 20)
                        .padding(.top, max(geometry.safeAreaInsets.top, 14))
                        .padding(.bottom, 12)

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 18) {
                            previewStage(height: previewStageHeight(in: geometry))
                            composerPanel
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, max(geometry.safeAreaInsets.bottom, 18))
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .fullScreenCover(isPresented: $showingImmersivePreview) {
            ImmersiveMemoryPlaybackView(
                draft: draft,
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

    private var backgroundImage: some View {
        Group {
            if let image = UIImage(data: draft.photoData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .saturation(0.84)
                    .blur(radius: 16)
                    .ignoresSafeArea()
                    .overlay {
                        LinearGradient(
                            colors: [Color.black.opacity(0.12), palette.heroScrimBottom.opacity(0.72)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                        .ignoresSafeArea()
                    }
            }
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

    private func previewStage(height: CGFloat) -> some View {
        Button {
            showingImmersivePreview = true
        } label: {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(.black.opacity(0.18))

                if let image = UIImage(data: draft.photoData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: height - 40)
                        .padding(20)
                }

                LinearGradient(
                    colors: [.clear, Color.black.opacity(0.18), Color.black.opacity(0.66)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        ResonanceBadge(
                            title: "全画面で再生",
                            systemImage: "arrow.up.left.and.arrow.down.right",
                            tint: .white,
                            atmosphere: atmosphere
                        )
                        Spacer()
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("この瞬間に入り込む")
                            .font(.title2.bold())
                            .foregroundStyle(.white)

                        Text(atmosphere.poeticLine)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.84))
                    }

                    HStack(spacing: 8) {
                        ResonanceBadge(title: "環境音ループ", systemImage: "waveform", tint: .white, atmosphere: atmosphere)
                        if let weatherSummary = draft.weatherSnapshot?.compactSummary, !weatherSummary.isEmpty {
                            ResonanceBadge(title: weatherSummary, systemImage: draft.weatherSnapshot?.symbolName ?? "cloud.sun.fill", tint: .white, atmosphere: atmosphere)
                        }
                    }

                    AudioWaveformView(
                        samples: waveformSamples,
                        progress: player.duration > 0 ? player.currentTime / player.duration : 0,
                        activeColor: .white,
                        inactiveColor: Color.white.opacity(0.18),
                        minimumBarHeight: 12
                    )
                    .frame(height: 46)
                }
                .padding(22)
            }
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .contentShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .strokeBorder(.white.opacity(0.14))
            }
            .shadow(color: .black.opacity(0.24), radius: 20, y: 14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("全画面プレビュー")
        .accessibilityHint("写真を全画面で表示し、環境音をループ再生します。")
    }

    private var composerPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Memory Scene")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.secondaryText)

                    Text("記憶に名前を与える")
                        .font(.title3.bold())
                        .foregroundStyle(palette.primaryText)
                }

                Spacer()

                if let minimumDecibels = draft.minimumDecibels, let maximumDecibels = draft.maximumDecibels {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("音量")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(palette.secondaryText)
                        Text(String(format: "最小 %.1f / 最大 %.1f dB", minimumDecibels, maximumDecibels))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.primaryText)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }

            TextField("", text: $title, prompt: Text("例: 雨上がりの横浜、静かな余韻").foregroundStyle(palette.tertiaryText))
                .focused($focusedField, equals: .title)
                .resonanceInputField(atmosphere: atmosphere)
                .textInputAutocapitalization(.sentences)

            if showingNotesField {
                TextField("", text: $notes, prompt: Text("その場の空気、温度、気持ち、聞こえたもの。").foregroundStyle(palette.tertiaryText), axis: .vertical)
                    .focused($focusedField, equals: .notes)
                    .lineLimit(3...5)
                    .resonanceInputField(atmosphere: atmosphere)
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
                    if let weatherSummary = draft.weatherSnapshot?.compactSummary, !weatherSummary.isEmpty {
                        detailLine(title: "天気", value: weatherSummary)
                    }
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
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surfacePrimary, in: UnevenRoundedRectangle(topLeadingRadius: 32, topTrailingRadius: 32))
        .overlay(alignment: .top) {
            Capsule()
                .fill(palette.stroke)
                .frame(width: 44, height: 5)
                .padding(.top, 10)
        }
    }

    private func previewStageHeight(in geometry: GeometryProxy) -> CGFloat {
        let availableHeight = geometry.size.height - geometry.safeAreaInsets.top - geometry.safeAreaInsets.bottom
        return min(max(availableHeight * 0.34, 236), 400)
    }

    private func detailLine(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(palette.secondaryText)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(palette.primaryText)
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
    let waveformSamples: [CGFloat]
    let atmosphere: AtmosphereStyle

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var player = AudioPlayerController()
    @State private var controlsVisible = true
    @State private var dragOffset: CGSize = .zero
    @State private var drifting = false

    private var palette: ResonancePalette {
        ResonancePalette.make(for: colorScheme, atmosphere: atmosphere)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image = UIImage(data: draft.photoData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(drifting ? 1.08 : 1.02)
                    .offset(x: dragOffset.width * 0.22, y: dragOffset.height * 0.12)
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 14).repeatForever(autoreverses: true), value: drifting)
            }

            LinearGradient(
                colors: [Color.black.opacity(0.22), .clear, Color.black.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            if controlsVisible {
                VStack(spacing: 0) {
                    HStack {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        ResonanceBadge(
                            title: "ループ再生中",
                            systemImage: "waveform",
                            tint: .white,
                            atmosphere: atmosphere
                        )
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                    Spacer()

                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Immersive Preview")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.72))

                                Text("写真と空気を、全画面で感じる")
                                    .font(.title2.bold())
                                    .foregroundStyle(.white)
                            }
                            Spacer()
                            Button {
                                if let audioURL = draft.audioTempURL {
                                    player.togglePlayback(for: audioURL)
                                }
                            } label: {
                                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 38))
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                        }

                        AudioWaveformView(
                            samples: waveformSamples,
                            progress: player.duration > 0 ? player.currentTime / player.duration : 0,
                            activeColor: .white,
                            inactiveColor: Color.white.opacity(0.18),
                            minimumBarHeight: 12
                        )
                        .frame(height: 46)

                        HStack {
                            Text(player.currentTime.resonanceClockText)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.82))
                            Spacer()
                            Text("ドラッグで視点を少し動かせます")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.74))
                        }
                    }
                    .padding(20)
                    .background(.black.opacity(0.36), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 22)
                }
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.22)) {
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
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        dragOffset = .zero
                    }
                    player.setPan(0)
                }
        )
        .onAppear {
            drifting = true
            if let audioURL = draft.audioTempURL {
                player.load(url: audioURL, autoPlay: true, loop: true, volume: 0.78)
            }
        }
        .onDisappear {
            player.stop()
        }
    }
}

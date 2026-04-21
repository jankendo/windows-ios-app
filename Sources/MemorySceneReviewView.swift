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

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        topBar
                        sceneHeadline
                        explicitPreviewCard(maxHeight: min(max(geometry.size.height * 0.34, 220), 340))
                        waveformSceneCard
                        compositionCard
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 140)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomSaveBar
        }
        .interactiveDismissDisabled(isSaving)
        .onAppear {
            waveformSamples = WaveformExtractor.samples(from: draft.audioTempURL, sampleCount: 64)
            if let audioURL = draft.audioTempURL {
                player.load(url: audioURL, autoPlay: true, loop: true, volume: 0.72)
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
                    .saturation(0.82)
                    .blur(radius: 14)
                    .ignoresSafeArea()
                    .overlay {
                        LinearGradient(
                            colors: [Color.black.opacity(0.08), palette.heroScrimBottom.opacity(0.58)],
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
                    .foregroundStyle(.white.opacity(0.82))
            }
        }
    }

    private var sceneHeadline: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Memory Scene")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.74))

            Text("撮れた瞬間を、見切れずに確かめる")
                .font(.largeTitle.bold())
                .foregroundStyle(.white)

            Text(atmosphere.poeticLine)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.82))

            HStack(spacing: 10) {
                ResonanceBadge(
                    title: "環境音 \(max(Int(draft.audioDuration.rounded()), 0))秒",
                    systemImage: "waveform",
                    tint: .white,
                    atmosphere: atmosphere
                )

                if let placeLabel = draft.placeLabel, !placeLabel.isEmpty {
                    ResonanceBadge(
                        title: placeLabel,
                        systemImage: "location.fill",
                        tint: .white,
                        atmosphere: atmosphere
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }

    private func explicitPreviewCard(maxHeight: CGFloat) -> some View {
        ResonanceCard(atmosphere: atmosphere) {
            VStack(alignment: .leading, spacing: 14) {
                Text("撮影プレビュー")
                    .font(.headline)
                    .foregroundStyle(palette.primaryText)

                if let image = UIImage(data: draft.photoData) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(palette.elevatedSurface.opacity(0.92))

                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .frame(maxHeight: maxHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    }
                }
            }
        }
    }

    private var waveformSceneCard: some View {
        ResonanceCard(atmosphere: atmosphere) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("空気のレイヤー")
                            .font(.headline)
                            .foregroundStyle(palette.primaryText)
                        Text("タップで再生と停止を切り替えながら、その場の空気を確認できます。")
                            .font(.subheadline)
                            .foregroundStyle(palette.secondaryText)
                    }
                    Spacer()
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(palette.accent)
                }

                Button {
                    if let audioURL = draft.audioTempURL {
                        player.togglePlayback(for: audioURL)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        AudioWaveformView(
                            samples: waveformSamples,
                            progress: player.duration > 0 ? player.currentTime / player.duration : 0,
                            activeColor: palette.accent,
                            inactiveColor: palette.secondaryText.opacity(0.28),
                            minimumBarHeight: 12
                        )

                        HStack {
                            Text(player.isPlaying ? "再生中" : "タップで再生")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(palette.primaryText)
                            Spacer()
                            Text("\(player.currentTime.resonanceClockText) / \(max(player.duration, draft.audioDuration).resonanceClockText)")
                                .font(.caption)
                                .foregroundStyle(palette.secondaryText)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var compositionCard: some View {
        ResonanceCard(atmosphere: atmosphere) {
            VStack(alignment: .leading, spacing: 16) {
                Text("記憶に名前を与える")
                    .font(.headline)
                    .foregroundStyle(palette.primaryText)

                Text("ここでタイトルや空気感のメモを入れておくと、あとで検索しやすくなります。")
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryText)

                TextField("", text: $title, prompt: Text("例: 雨上がりの横浜、静かな余韻").foregroundStyle(palette.tertiaryText))
                    .focused($focusedField, equals: .title)
                    .resonanceInputField(atmosphere: atmosphere)
                    .textInputAutocapitalization(.sentences)

                TextField("", text: $notes, prompt: Text("その場の空気、温度、気持ち、聞こえたもの。").foregroundStyle(palette.tertiaryText), axis: .vertical)
                    .focused($focusedField, equals: .notes)
                    .lineLimit(4...7)
                    .resonanceInputField(atmosphere: atmosphere)
            }
        }
    }

    private var bottomSaveBar: some View {
        VStack(spacing: 12) {
            if focusedField != nil {
                HStack {
                    Spacer()
                    Button("キーボードを閉じる") {
                        focusedField = nil
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.84))
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
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.18), .black.opacity(0.38)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

import SwiftData
import SwiftUI
import UIKit

@MainActor
final class CaptureFlowModel: ObservableObject {
    @Published var title = ""
    @Published var notes = ""
    @Published var isSaving = false
    @Published var capturedDraft: CapturedMemoryDraft?
    @Published var lastSavedEntry: MemoryEntry?
    @Published var errorMessage: String?
    @Published var saveMessage: String?

    let camera = CameraCaptureService()
    private let locationService = CaptureLocationService.shared

    func prepare() {
        camera.prepare()
        locationService.prepare()
        Task {
            await MemoryAnalysisService.requestSpeechAuthorizationIfNeeded()
        }
    }

    func capture() {
        guard !isSaving else { return }
        errorMessage = nil
        saveMessage = nil
        lastSavedEntry = nil

        camera.captureMemory { [weak self] result in
            guard let self else { return }

            Task { @MainActor in
                do {
                    var draft = try result.get()
                    draft.placeLabel = await self.locationService.currentPlaceLabel()
                    self.capturedDraft = draft
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func saveDraft(using modelContext: ModelContext) {
        guard let draft = capturedDraft, !isSaving else { return }
        errorMessage = nil
        saveMessage = nil
        isSaving = true

        let currentTitle = title
        let currentNotes = notes

        Task {
            do {
                let storedMedia = try MediaStore.save(photoData: draft.photoData, audioTempURL: draft.audioTempURL)
                let storedAudioURL = storedMedia.audioFileName.map(MediaStore.audioURL(for:))
                let analysis = await MemoryAnalysisService.analyze(photoData: draft.photoData, audioURL: storedAudioURL)

                let entry = MemoryEntry(
                    createdAt: draft.capturedAt,
                    title: currentTitle,
                    notes: currentNotes,
                    photoFileName: storedMedia.photoFileName,
                    audioFileName: storedMedia.audioFileName,
                    audioDuration: storedMedia.audioDuration,
                    visualTags: analysis.visualTags,
                    audioTags: analysis.audioTags,
                    transcript: analysis.transcript,
                    mood: analysis.mood
                )

                let metadata = MemoryAtmosphereMetadata(
                    placeLabel: draft.placeLabel,
                    waveformFingerprint: WaveformExtractor.samples(from: storedAudioURL, sampleCount: 28).map(Double.init),
                    atmosphereStyle: draft.atmosphereStyle
                )

                try MediaStore.saveAtmosphereMetadata(metadata, for: entry.id)
                modelContext.insert(entry)
                try modelContext.save()

                title = ""
                notes = ""
                capturedDraft = nil
                lastSavedEntry = entry
                if let placeLabel = draft.placeLabel, !placeLabel.isEmpty {
                    saveMessage = "\(placeLabel)の空気を保存しました。"
                } else {
                    saveMessage = "記録を保存しました。"
                }
            } catch {
                errorMessage = error.localizedDescription
            }

            isSaving = false
        }
    }

    func discardDraft() {
        if let audioURL = capturedDraft?.audioTempURL {
            try? FileManager.default.removeItem(at: audioURL)
        }
        capturedDraft = nil
    }

    func resetSuccessState() {
        lastSavedEntry = nil
        saveMessage = nil
    }
}

struct CaptureView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \MemoryEntry.createdAt, order: .reverse) private var entries: [MemoryEntry]
    @StateObject private var model = CaptureFlowModel()

    private var atmosphere: AtmosphereStyle {
        model.capturedDraft?.atmosphereStyle ?? AtmosphereStyle(date: .now)
    }

    private var palette: ResonancePalette {
        ResonancePalette.make(for: colorScheme, atmosphere: atmosphere)
    }

    private var favoriteCount: Int {
        entries.filter(\.isFavorite).count
    }

    private var todayCount: Int {
        let calendar = Calendar.current
        return entries.filter { calendar.isDateInToday($0.createdAt) }.count
    }

    private var recentEntries: [MemoryEntry] {
        Array(entries.prefix(3))
    }

    var body: some View {
        ZStack {
            ResonanceGradientBackground(atmosphere: atmosphere)

            ScrollView {
                VStack(spacing: 18) {
                    captureHero
                    statsOverview
                    draftComposer

                    if model.camera.isCapturing {
                        recordingProgressCard
                    }

                    if model.camera.permissionState == .denied {
                        permissionRecoveryCard
                    }

                    primaryCaptureCard

                    if let errorMessage = model.errorMessage {
                        StatusMessageView(symbol: "exclamationmark.triangle.fill", text: errorMessage, tint: .red, atmosphere: atmosphere)
                    }

                    if let saveMessage = model.saveMessage {
                        successCard(message: saveMessage)
                    }

                    if !recentEntries.isEmpty {
                        recentMemoriesSection
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("記録")
        .task {
            model.prepare()
        }
        .fullScreenCover(item: $model.capturedDraft) { draft in
            MemorySceneReviewView(
                draft: draft,
                title: $model.title,
                notes: $model.notes,
                isSaving: model.isSaving,
                onRetake: {
                    model.discardDraft()
                },
                onSave: {
                    model.saveDraft(using: modelContext)
                }
            )
        }
    }

    private var captureHero: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.black.opacity(colorScheme == .dark ? 0.72 : 0.9))
                .frame(height: 400)
                .overlay {
                    Group {
                        if model.camera.permissionState == .ready {
                            CameraPreviewView(session: model.camera.session)
                        } else {
                            permissionPlaceholder
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                }
                .overlay {
                    ResonanceHeroScrim(atmosphere: atmosphere)
                        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ResonanceBadge(
                        title: model.camera.isCapturing ? "録音中" : "準備完了",
                        systemImage: model.camera.isCapturing ? "waveform" : "camera.aperture",
                        tint: .white,
                        atmosphere: atmosphere
                    )

                    ResonanceBadge(
                        title: atmosphere.localizedLabel,
                        systemImage: atmosphere.symbolName,
                        tint: .white,
                        atmosphere: atmosphere
                    )
                }

                Text("光と空気を、同時に残す")
                    .font(.title.bold())
                    .foregroundStyle(.white)

                Text(model.camera.statusText)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.82))

                if let placeHint = recentEntries.first?.placeLabel {
                    Text("最近の場所: \(placeHint)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
            .padding(22)
        }
    }

    private var statsOverview: some View {
        HStack(spacing: 12) {
            ResonanceStatTile(title: "今日の記録", value: "\(todayCount)", symbol: "calendar", atmosphere: atmosphere)
            ResonanceStatTile(title: "お気に入り", value: "\(favoriteCount)", symbol: "heart.fill", atmosphere: atmosphere)
            ResonanceStatTile(title: "ライブラリ", value: "\(entries.count)", symbol: "square.stack.3d.down.right.fill", atmosphere: atmosphere)
        }
    }

    private var draftComposer: some View {
        ResonanceCard(atmosphere: atmosphere) {
            VStack(alignment: .leading, spacing: 14) {
                Text("記憶の下書き")
                    .font(.headline)
                    .foregroundStyle(palette.primaryText)

                Text("先に言葉を置いておくと、その場の空気をあとから探しやすくなります。")
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryText)

                TextField("", text: $model.title, prompt: Text("例: 夜風が気持ちよかった港").foregroundStyle(palette.tertiaryText))
                    .resonanceInputField(atmosphere: atmosphere)

                TextField("", text: $model.notes, prompt: Text("音、温度、匂い、感情の断片を残せます。").foregroundStyle(palette.tertiaryText), axis: .vertical)
                    .lineLimit(3...5)
                    .resonanceInputField(atmosphere: atmosphere)
            }
        }
    }

    private var recordingProgressCard: some View {
        ResonanceCard(atmosphere: atmosphere) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("空気を採集しています…")
                        .font(.headline)
                        .foregroundStyle(palette.primaryText)
                    Spacer()
                    Text("\(model.camera.remainingRecordingSeconds)秒")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.accent)
                }

                ProgressView(value: model.camera.captureProgress)
                    .tint(palette.accent)

                Text("写真は撮影済みです。音の余韻を6秒間だけ丁寧に残しています。")
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryText)
            }
        }
    }

    private var permissionRecoveryCard: some View {
        ResonanceCard(atmosphere: atmosphere) {
            VStack(alignment: .leading, spacing: 14) {
                Text("カメラとマイクへのアクセスが必要です")
                    .font(.headline)
                    .foregroundStyle(palette.primaryText)
                Text("設定から権限を許可すると、写真と環境音を一緒に記録できます。")
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryText)
                OpenSettingsButton()
            }
        }
    }

    private var primaryCaptureCard: some View {
        ResonanceCard(atmosphere: atmosphere) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("記録を開始")
                            .font(.headline)
                            .foregroundStyle(palette.primaryText)

                        Text("シャッターのあとに Memory Scene が開き、その場の写真と音を立体的に確認できます。")
                            .font(.subheadline)
                            .foregroundStyle(palette.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "sparkles")
                        .font(.title2)
                        .foregroundStyle(palette.accent)
                }

                Button {
                    model.capture()
                } label: {
                    HStack {
                        Image(systemName: model.isSaving || model.camera.isCapturing ? "waveform.circle.fill" : "camera.circle.fill")
                            .font(.title2)
                        Text(model.isSaving || model.camera.isCapturing ? "保存中…" : "写真と音を記録")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .disabled(!model.camera.isReadyToCapture || model.isSaving)
            }
        }
    }

    private func successCard(message: String) -> some View {
        let successAtmosphere = model.lastSavedEntry?.atmosphereStyle ?? atmosphere
        let successPalette = ResonancePalette.make(for: colorScheme, atmosphere: successAtmosphere)

        return ResonanceCard(atmosphere: successAtmosphere) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(message)
                        .font(.headline)
                        .foregroundStyle(successPalette.primaryText)
                }

                Text("ライブラリからその場に戻ったり、詳細画面で空気の層をさらに確かめられます。")
                    .font(.subheadline)
                    .foregroundStyle(successPalette.secondaryText)

                HStack(spacing: 12) {
                    if let lastSavedEntry = model.lastSavedEntry {
                        NavigationLink {
                            MemoryDetailView(entry: lastSavedEntry)
                        } label: {
                            Label("記録を見る", systemImage: "arrow.right.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(successPalette.accent)
                    }

                    Button("続けて記録") {
                        model.resetSuccessState()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var recentMemoriesSection: some View {
        ResonanceCard(atmosphere: atmosphere) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("最近の記録")
                        .font(.headline)
                        .foregroundStyle(palette.primaryText)
                    Spacer()
                    Text("すぐ見返す")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(recentEntries) { entry in
                            NavigationLink {
                                MemoryDetailView(entry: entry)
                            } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    MemoryThumbnail(entry: entry, width: 170, height: 128)
                                        .overlay(alignment: .bottomLeading) {
                                            LinearGradient(
                                                colors: [.clear, .black.opacity(0.34)],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            )
                                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                        }

                                    Text(entry.displayTitle)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(palette.primaryText)
                                        .lineLimit(1)

                                    if let placeLabel = entry.placeLabel {
                                        Text(placeLabel)
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(palette.secondaryText)
                                            .lineLimit(1)
                                    }

                                    AudioWaveformView(
                                        samples: entry.waveformFingerprint,
                                        progress: 1,
                                        activeColor: palette.accent,
                                        inactiveColor: palette.accent.opacity(0.16),
                                        minimumBarHeight: 8
                                    )
                                    .frame(height: 28)
                                }
                                .frame(width: 170, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var permissionPlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.9))
            Text("カメラとマイクへのアクセスが必要です")
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text("設定から許可すると、この瞬間の写真と音を一緒に残せます。")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal)
        }
    }
}

struct StatusMessageView: View {
    let symbol: String
    let text: String
    let tint: Color
    var atmosphere: AtmosphereStyle? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = ResonancePalette.make(for: colorScheme, atmosphere: atmosphere)

        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(palette.primaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(tint.opacity(colorScheme == .dark ? 0.18 : 0.1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(tint.opacity(colorScheme == .dark ? 0.32 : 0.2))
        }
    }
}

#Preview {
    NavigationStack {
        CaptureView()
    }
    .modelContainer(for: [MemoryEntry.self], inMemory: true)
}

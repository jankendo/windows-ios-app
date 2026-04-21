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

    func prepare() {
        camera.prepare()
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
                    self.capturedDraft = try result.get()
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
                let analysis = await MemoryAnalysisService.analyze(photoData: draft.photoData, audioURL: storedMedia.audioFileName.map(MediaStore.audioURL(for:)))

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

                modelContext.insert(entry)
                try modelContext.save()

                title = ""
                notes = ""
                capturedDraft = nil
                lastSavedEntry = entry
                saveMessage = "記録を保存しました。"
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
    @Query(sort: \MemoryEntry.createdAt, order: .reverse) private var entries: [MemoryEntry]
    @StateObject private var model = CaptureFlowModel()

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
            ResonanceGradientBackground()

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

                    if let draft = model.capturedDraft {
                        reviewCard(for: draft)
                    } else {
                        primaryCaptureCard
                    }

                    if let errorMessage = model.errorMessage {
                        StatusMessageView(symbol: "exclamationmark.triangle.fill", text: errorMessage, tint: .red)
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
    }

    private var captureHero: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.black.opacity(0.94))
                .frame(height: 380)
                .overlay {
                    if model.camera.permissionState == .ready {
                        CameraPreviewView(session: model.camera.session)
                            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    } else {
                        permissionPlaceholder
                    }
                }

            VStack(alignment: .leading, spacing: 10) {
                ResonanceBadge(
                    title: model.camera.isCapturing ? "録音中" : "準備完了",
                    systemImage: model.camera.isCapturing ? "waveform" : "camera.aperture",
                    tint: model.camera.isCapturing ? .orange : .white
                )

                Text("この瞬間を記録")
                    .font(.title.bold())
                    .foregroundStyle(.white)

                Text(model.camera.statusText)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.82))
            }
            .padding(20)
        }
    }

    private var statsOverview: some View {
        HStack(spacing: 12) {
            ResonanceStatTile(title: "今日の記録", value: "\(todayCount)", symbol: "calendar")
            ResonanceStatTile(title: "お気に入り", value: "\(favoriteCount)", symbol: "heart.fill")
            ResonanceStatTile(title: "ライブラリ", value: "\(entries.count)", symbol: "square.stack.3d.down.right.fill")
        }
    }

    private var draftComposer: some View {
        ResonanceCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("記録メモ")
                    .font(.headline)

                Text("タイトルや感情メモを先に残しておくと、あとで探しやすくなります。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("例: 雨上がりのカフェ", text: $model.title)
                    .textFieldStyle(.roundedBorder)

                TextField("その場の空気や感じたことを書けます。", text: $model.notes, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...5)
            }
        }
    }

    private var recordingProgressCard: some View {
        ResonanceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("環境音を録音中…")
                        .font(.headline)
                    Spacer()
                    Text("\(model.camera.remainingRecordingSeconds)秒")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                }

                ProgressView(value: model.camera.captureProgress)
                    .tint(.orange)

                Text("写真は撮影済みです。6秒間の空気感を集めています。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var permissionRecoveryCard: some View {
        ResonanceCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("カメラとマイクへのアクセスが必要です")
                    .font(.headline)
                Text("設定から権限を許可すると、写真と環境音を一緒に記録できます。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                OpenSettingsButton()
            }
        }
    }

    private var primaryCaptureCard: some View {
        ResonanceCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("写真と6秒の環境音を一緒に残します")
                    .font(.headline)

                Text("シャッターを押すと写真を撮影し、そのまま6秒間の環境音を記録します。録音後に内容を確認してから保存できます。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

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
                .disabled(!model.camera.isReadyToCapture || model.isSaving)
            }
        }
    }

    private func reviewCard(for draft: CapturedMemoryDraft) -> some View {
        ResonanceCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("レビューして保存")
                    .font(.headline)

                if let image = UIImage(data: draft.photoData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 240)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                }

                HStack(spacing: 10) {
                    ResonanceBadge(title: "環境音 6秒", systemImage: "waveform")
                    ResonanceBadge(title: draft.capturedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                }

                Text("内容を確認してから保存できます。撮り直したい場合は破棄してもう一度記録してください。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("撮り直す") {
                        model.discardDraft()
                    }
                    .buttonStyle(.bordered)

                    Button {
                        model.saveDraft(using: modelContext)
                    } label: {
                        Label(model.isSaving ? "保存中…" : "この記録を保存", systemImage: "square.and.arrow.down.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isSaving)
                }
            }
        }
    }

    private func successCard(message: String) -> some View {
        ResonanceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(message)
                        .font(.headline)
                }

                Text("ライブラリから見返したり、すぐに詳細画面で確認できます。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    if let lastSavedEntry = model.lastSavedEntry {
                        NavigationLink {
                            MemoryDetailView(entry: lastSavedEntry)
                        } label: {
                            Label("記録を見る", systemImage: "arrow.right.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
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
        ResonanceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("最近の記録")
                        .font(.headline)
                    Spacer()
                    Text("すぐ見返す")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(recentEntries) { entry in
                            NavigationLink {
                                MemoryDetailView(entry: entry)
                            } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    MemoryThumbnail(entry: entry, width: 150, height: 110)

                                    Text(entry.displayTitle)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 150, alignment: .leading)
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

#Preview {
    NavigationStack {
        CaptureView()
    }
    .modelContainer(for: [MemoryEntry.self], inMemory: true)
}

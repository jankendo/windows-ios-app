import SwiftData
import SwiftUI

@MainActor
final class CaptureFlowModel: ObservableObject {
    @Published var title = ""
    @Published var notes = ""
    @Published var isSaving = false
    @Published var errorMessage: String?
    @Published var saveMessage: String?

    let camera = CameraCaptureService()

    func prepare() {
        camera.prepare()
        Task {
            await MemoryAnalysisService.requestSpeechAuthorizationIfNeeded()
        }
    }

    func capture(using modelContext: ModelContext) {
        guard !isSaving else { return }
        errorMessage = nil
        saveMessage = nil
        isSaving = true

        let currentTitle = title
        let currentNotes = notes

        camera.captureMemory { [weak self] result in
            guard let self else { return }

            Task { @MainActor in
                do {
                    let draft = try result.get()
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

                    self.title = ""
                    self.notes = ""
                    self.saveMessage = "メモリーを保存しました。"
                } catch {
                    self.errorMessage = error.localizedDescription
                }

                self.isSaving = false
            }
        }
    }
}

struct CaptureView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var model = CaptureFlowModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(.black.opacity(0.92))
                        .frame(height: 360)
                        .overlay {
                            if model.camera.permissionState == .ready {
                                CameraPreviewView(session: model.camera.session)
                                    .clipShape(RoundedRectangle(cornerRadius: 24))
                            } else {
                                permissionPlaceholder
                            }
                        }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Resonance Capture")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text(model.camera.statusText)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.78))
                    }
                    .padding(16)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("タイトル")
                        .font(.headline)
                    TextField("例: 雨上がりのカフェ", text: $model.title)
                        .textFieldStyle(.roundedBorder)

                    Text("メモ")
                        .font(.headline)
                    TextField("その場の空気や感情をメモしておけます。", text: $model.notes, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...5)
                }

                captureCard

                if let errorMessage = model.errorMessage {
                    StatusMessageView(symbol: "exclamationmark.triangle.fill", text: errorMessage, tint: .red)
                }

                if let saveMessage = model.saveMessage {
                    StatusMessageView(symbol: "checkmark.circle.fill", text: saveMessage, tint: .green)
                }
            }
            .padding(20)
        }
        .navigationTitle("Capture")
        .task {
            model.prepare()
        }
    }

    private var captureCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("写真 + 6秒の環境音")
                .font(.headline)

            Text("シャッターを押すと、写真と一緒にその場の空気感を残す短い音声クリップを自動保存します。保存後は Vision / SoundAnalysis / Speech を使って検索用のタグを自動生成します。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                model.capture(using: modelContext)
            } label: {
                HStack {
                    Image(systemName: model.isSaving || model.camera.isCapturing ? "waveform.circle.fill" : "circle.fill")
                        .font(.title2)
                    Text(model.isSaving || model.camera.isCapturing ? "保存中…" : "この瞬間を保存")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.camera.permissionState != .ready || model.isSaving || model.camera.isCapturing)
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var permissionPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.9))
            Text("カメラとマイクの権限が必要です")
                .font(.headline)
                .foregroundStyle(.white)
            Text("設定から権限を許可すると、その瞬間の写真と音を一緒に保存できます。")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal)
        }
    }
}

private struct StatusMessageView: View {
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
        .padding(14)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }
}

#Preview {
    NavigationStack {
        CaptureView()
    }
    .modelContainer(for: [MemoryEntry.self], inMemory: true)
}

import SwiftData
import SwiftUI
import UIKit

struct MemoryDetailView: View {
    @Bindable var entry: MemoryEntry
    @Query(sort: \MemoryEntry.createdAt, order: .reverse) private var allEntries: [MemoryEntry]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var player = AudioPlayerController()
    @State private var waveformSamples: [CGFloat] = Array(repeating: 0.25, count: 40)
    @State private var showingEditor = false
    @State private var showingDeleteConfirmation = false
    @State private var showingShareSheet = false
    @State private var showingAutoTags = false

    private var shareItems: [Any] {
        var items: [Any] = [entry.shareSummary, entry.photoURL]
        if let audioURL = entry.audioURL {
            items.append(audioURL)
        }
        return items
    }

    private var relatedEntries: [MemoryEntry] {
        allEntries
            .filter { $0.id != entry.id }
            .map { candidate in
                let sharedTags = Set(candidate.autoTags).intersection(entry.autoTags).count
                let moodScore = candidate.mood == entry.mood ? 2 : 0
                return (candidate, sharedTags + moodScore)
            }
            .filter { $0.1 > 0 }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.createdAt > rhs.0.createdAt
                }
                return lhs.1 > rhs.1
            }
            .map(\.0)
            .prefix(3)
            .map { $0 }
    }

    var body: some View {
        ZStack {
            ResonanceGradientBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    MemoryHeroImage(entry: entry)

                    ResonanceCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(entry.displayTitle)
                                        .font(.largeTitle.bold())

                                    Text(entry.createdAt.formatted(date: .complete, time: .shortened))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button {
                                    entry.isFavorite.toggle()
                                    try? modelContext.save()
                                } label: {
                                    Image(systemName: entry.isFavorite ? "heart.fill" : "heart")
                                        .font(.title3)
                                        .foregroundStyle(entry.isFavorite ? .pink : .secondary)
                                }
                                .buttonStyle(.plain)
                            }

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ResonanceBadge(title: entry.localizedMood, systemImage: "sparkles")
                                    if entry.hasAudio {
                                        ResonanceBadge(title: "\(Int(entry.audioDuration.rounded()))秒", systemImage: "waveform")
                                    }
                                    if entry.isFavorite {
                                        ResonanceBadge(title: "お気に入り", systemImage: "heart.fill", tint: .pink)
                                    }
                                }
                            }
                        }
                    }

                    if !entry.notes.isEmpty {
                        ResonanceCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("メモ")
                                    .font(.headline)
                                Text(entry.notes)
                                    .font(.body)
                            }
                        }
                    }

                    if let audioURL = entry.audioURL {
                        ResonanceCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Label("環境音", systemImage: "waveform")
                                    .font(.headline)

                                AudioWaveformView(
                                    samples: waveformSamples,
                                    progress: player.duration > 0 ? player.currentTime / player.duration : 0
                                )

                                HStack(spacing: 12) {
                                    Button {
                                        player.togglePlayback(for: audioURL)
                                    } label: {
                                        Label(player.isPlaying ? "一時停止" : "再生", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.borderedProminent)

                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("再生位置")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text("\(player.currentTime.resonanceClockText) / \(max(player.duration, entry.audioDuration).resonanceClockText)")
                                            .font(.subheadline.weight(.semibold))
                                    }
                                }

                                Slider(
                                    value: Binding(
                                        get: { player.currentTime },
                                        set: { player.seek(to: $0) }
                                    ),
                                    in: 0...max(max(player.duration, entry.audioDuration), 1)
                                )

                                HStack {
                                    Text(player.currentTime.resonanceClockText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("-\(max(player.duration - player.currentTime, 0).resonanceClockText)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if !entry.transcript.isEmpty {
                        ResonanceCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("文字起こし")
                                    .font(.headline)
                                Text(entry.transcript)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    ResonanceCard {
                        DisclosureGroup(isExpanded: $showingAutoTags) {
                            VStack(alignment: .leading, spacing: 12) {
                                if entry.autoTags.isEmpty {
                                    Text("まだ自動タグはありません。")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                } else {
                                    FlexibleTagCloud(tags: entry.autoTags)
                                }
                            }
                            .padding(.top, 12)
                        } label: {
                            Label("自動タグ", systemImage: "tag")
                                .font(.headline)
                        }
                    }

                    if !relatedEntries.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("関連する記録")
                                .font(.headline)

                            ForEach(relatedEntries) { related in
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
        .alert("この記録を削除しますか？", isPresented: $showingDeleteConfirmation) {
            Button("削除", role: .destructive) {
                deleteEntry()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("写真、音声、メモ情報がこの端末から削除されます。")
        }
        .onAppear {
            waveformSamples = WaveformExtractor.samples(from: entry.audioURL)
            if let audioURL = entry.audioURL {
                player.load(url: audioURL)
            }
        }
        .onDisappear {
            player.stop()
        }
    }

    private func deleteEntry() {
        MediaStore.deleteAssets(for: entry)
        modelContext.delete(entry)
        try? modelContext.save()
        dismiss()
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
                RoundedRectangle(cornerRadius: 28)
                    .fill(.gray.opacity(0.15))
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 320)
        .clipShape(RoundedRectangle(cornerRadius: 28))
    }
}

private struct FlexibleTagCloud: View {
    let tags: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(chunkedTags, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { tag in
                        Text(tag)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.indigo.opacity(0.12), in: Capsule())
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
                TextField("メモ", text: $entry.notes, axis: .vertical)
                    .lineLimit(4...8)
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
    .modelContainer(for: [MemoryEntry.self], inMemory: true)
}

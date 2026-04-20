import SwiftData
import SwiftUI
import UIKit

struct MemoryDetailView: View {
    @Bindable var entry: MemoryEntry
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var player = AudioPlayerController()
    @State private var waveformSamples: [CGFloat] = Array(repeating: 0.25, count: 40)
    @State private var showingEditor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MemoryHeroImage(entry: entry)

                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.displayTitle)
                        .font(.largeTitle.bold())

                    Text(entry.createdAt.formatted(date: .complete, time: .shortened))
                        .foregroundStyle(.secondary)

                    if !entry.notes.isEmpty {
                        Text(entry.notes)
                            .font(.body)
                    }
                }

                if let audioURL = entry.audioURL {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Soundscape", systemImage: "waveform")
                            .font(.headline)

                        AudioWaveformView(
                            samples: waveformSamples,
                            progress: player.duration > 0 ? player.currentTime / player.duration : 0
                        )

                        HStack(spacing: 12) {
                            Button {
                                player.togglePlayback(for: audioURL)
                            } label: {
                                Label(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                            }
                            .buttonStyle(.borderedProminent)

                            VStack(alignment: .leading) {
                                Text("Duration: \(Int(entry.audioDuration.rounded())) sec")
                                Text("Mood: \(entry.mood)")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        Slider(
                            value: Binding(
                                get: { player.currentTime },
                                set: { player.seek(to: $0) }
                            ),
                            in: 0...max(max(player.duration, entry.audioDuration), 1)
                        )
                    }
                    .padding(18)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
                }

                metadataSection(title: "Visual tags", tags: entry.visualTags)
                metadataSection(title: "Audio tags", tags: entry.audioTags)

                if !entry.transcript.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Transcript")
                            .font(.headline)
                        Text(entry.transcript)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Edit") {
                    showingEditor = true
                }

                Button(role: .destructive) {
                    deleteEntry()
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            MemoryEditView(entry: entry)
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

    @ViewBuilder
    private func metadataSection(title: String, tags: [String]) -> some View {
        if !tags.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)

                FlexibleTagCloud(tags: tags)
            }
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
            .navigationTitle("Edit Memory")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
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

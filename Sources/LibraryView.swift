import SwiftData
import SwiftUI
import UIKit

struct LibraryView: View {
    @Query(sort: \MemoryEntry.createdAt, order: .reverse) private var entries: [MemoryEntry]
    @State private var selectedMood: String?

    private var filteredEntries: [MemoryEntry] {
        MemorySearchEngine.filter(entries, query: "", mood: selectedMood)
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                emptyState
            } else {
                List {
                    moodFilterSection

                    ForEach(filteredEntries, id: \.id) { entry in
                        NavigationLink {
                            MemoryDetailView(entry: entry)
                        } label: {
                            MemoryRowView(entry: entry)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Library")
    }

    private var moodFilterSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(
                        title: "All",
                        isSelected: selectedMood == nil
                    ) {
                        selectedMood = nil
                    }

                    ForEach(MemoryMood.allCases) { mood in
                        FilterChip(
                            title: mood.rawValue,
                            isSelected: selectedMood == mood.rawValue
                        ) {
                            selectedMood = selectedMood == mood.rawValue ? nil : mood.rawValue
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("まだメモリーがありません", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Capture タブから写真と環境音を保存すると、ここに時系列で並びます。")
        }
    }
}

struct MemoryRowView: View {
    let entry: MemoryEntry

    var body: some View {
        HStack(spacing: 14) {
            MemoryThumbnail(entry: entry)

            VStack(alignment: .leading, spacing: 6) {
                Text(entry.displayTitle)
                    .font(.headline)
                    .lineLimit(1)

                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(entry.combinedTags.prefix(3).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Label(entry.mood, systemImage: "sparkles")
                    if entry.hasAudio {
                        Label("\(Int(entry.audioDuration.rounded()))s", systemImage: "waveform")
                    }
                }
                .font(.caption)
                .foregroundStyle(.indigo)
            }
        }
        .padding(.vertical, 6)
    }
}

struct MemoryThumbnail: View {
    let entry: MemoryEntry

    var body: some View {
        Group {
            if let image = UIImage(contentsOfFile: entry.photoURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.gray.opacity(0.15))
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: 76, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? Color.indigo : Color.gray.opacity(0.12), in: Capsule())
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        LibraryView()
    }
    .modelContainer(for: [MemoryEntry.self], inMemory: true)
}

import SwiftData
import SwiftUI
import UIKit

private enum LibrarySortOption: String, CaseIterable, Identifiable {
    case newest
    case oldest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newest:
            return "新しい順"
        case .oldest:
            return "古い順"
        }
    }
}

struct LibraryView: View {
    @Query(sort: \MemoryEntry.createdAt, order: .reverse) private var entries: [MemoryEntry]
    @State private var selectedMood: String?
    @State private var favoritesOnly = false
    @State private var sortOption: LibrarySortOption = .newest

    private var filteredEntries: [MemoryEntry] {
        let filtered = MemorySearchEngine.filter(entries, query: "", mood: selectedMood)
            .filter { !favoritesOnly || $0.isFavorite }

        switch sortOption {
        case .newest:
            return filtered.sorted { $0.createdAt > $1.createdAt }
        case .oldest:
            return filtered.sorted { $0.createdAt < $1.createdAt }
        }
    }

    private var groupedEntries: [(title: String, entries: [MemoryEntry])] {
        let calendar = Calendar.current
        let today = filteredEntries.filter { calendar.isDateInToday($0.createdAt) }
        let thisWeek = filteredEntries.filter {
            !calendar.isDateInToday($0.createdAt) && calendar.isDate($0.createdAt, equalTo: .now, toGranularity: .weekOfYear)
        }
        let earlier = filteredEntries.filter {
            !calendar.isDateInToday($0.createdAt) && !calendar.isDate($0.createdAt, equalTo: .now, toGranularity: .weekOfYear)
        }

        return [
            ("今日", today),
            ("今週", thisWeek),
            ("それ以前", earlier)
        ]
        .filter { !$0.entries.isEmpty }
    }

    var body: some View {
        ZStack {
            ResonanceGradientBackground()

            ScrollView {
                VStack(spacing: 18) {
                    summaryCard
                    filterBar

                    if entries.isEmpty {
                        emptyState
                    } else if groupedEntries.isEmpty {
                        ResonanceEmptyState(
                            title: "条件に合う記録がありません",
                            message: "フィルターを変えると、別の思い出が見つかるかもしれません。",
                            symbol: "line.3.horizontal.decrease.circle"
                        )
                    } else {
                        ForEach(groupedEntries, id: \.title) { section in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(section.title)
                                    .font(.title3.bold())

                                ForEach(section.entries) { entry in
                                    NavigationLink {
                                        MemoryDetailView(entry: entry)
                                    } label: {
                                        MemoryCardView(entry: entry)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("ライブラリ")
    }

    private var summaryCard: some View {
        ResonanceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("記録のライブラリ")
                            .font(.headline)
                        Text("集めた写真と音を、気分ごとに見返せます。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Menu {
                        ForEach(LibrarySortOption.allCases) { option in
                            Button(option.label) {
                                sortOption = option
                            }
                        }
                    } label: {
                        Label(sortOption.label, systemImage: "arrow.up.arrow.down.circle")
                            .font(.subheadline.weight(.semibold))
                    }
                }

                HStack(spacing: 12) {
                    ResonanceStatTile(title: "合計", value: "\(entries.count)", symbol: "square.stack.3d.down.right.fill")
                    ResonanceStatTile(title: "お気に入り", value: "\(entries.filter(\.isFavorite).count)", symbol: "heart.fill")
                }
            }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "すべて", isSelected: !favoritesOnly && selectedMood == nil) {
                    favoritesOnly = false
                    selectedMood = nil
                }

                FilterChip(title: "お気に入り", isSelected: favoritesOnly) {
                    favoritesOnly.toggle()
                }

                ForEach(MemoryMood.allCases) { mood in
                    FilterChip(title: mood.localizedLabel, isSelected: selectedMood == mood.rawValue) {
                        selectedMood = selectedMood == mood.rawValue ? nil : mood.rawValue
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var emptyState: some View {
        ResonanceEmptyState(
            title: "まだ記録はありません",
            message: "最初の1件を残すと、ここに写真と環境音が並びます。",
            symbol: "photo.on.rectangle.angled"
        )
    }
}

struct MemoryCardView: View {
    let entry: MemoryEntry
    var matchReasons: [String] = []

    var body: some View {
        ResonanceCard {
            HStack(alignment: .top, spacing: 14) {
                MemoryThumbnail(entry: entry, width: 96, height: 96)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.displayTitle)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if entry.isFavorite {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(.pink)
                        }
                    }

                    Text(entry.notePreview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ResonanceBadge(title: entry.localizedMood, systemImage: "sparkles")
                            if entry.hasAudio {
                                ResonanceBadge(title: "\(Int(entry.audioDuration.rounded()))秒", systemImage: "waveform")
                            }
                            ForEach(entry.autoTags.prefix(2), id: \.self) { tag in
                                ResonanceBadge(title: tag, systemImage: "tag")
                            }
                            ForEach(matchReasons, id: \.self) { reason in
                                ResonanceBadge(title: reason, systemImage: "magnifyingglass", tint: .orange)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct MemoryThumbnail: View {
    let entry: MemoryEntry
    var width: CGFloat = 76
    var height: CGFloat = 76

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
        .frame(width: width, height: height)
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

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
    @Environment(\.colorScheme) private var colorScheme
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

    private var palette: ResonancePalette {
        ResonancePalette.make(for: colorScheme)
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
                                    .foregroundStyle(palette.primaryText)

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
                            .foregroundStyle(palette.primaryText)
                        Text("集めた写真と音を、気分ごとに見返せます。")
                            .font(.subheadline)
                            .foregroundStyle(palette.secondaryText)
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
    @Environment(\.colorScheme) private var colorScheme
    let entry: MemoryEntry
    var matchReasons: [String] = []

    var body: some View {
        let palette = ResonancePalette.make(for: colorScheme, atmosphere: entry.atmosphereStyle)

        ResonanceCard(atmosphere: entry.atmosphereStyle) {
            HStack(alignment: .top, spacing: 14) {
                MemoryThumbnail(entry: entry, width: 96, height: 96)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.displayTitle)
                                .font(.headline)
                                .foregroundStyle(palette.primaryText)
                                .lineLimit(1)

                            Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(palette.secondaryText)
                        }

                        if let placeLabel = entry.placeLabel {
                            Text(placeLabel)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(palette.secondaryText)
                                .lineLimit(1)
                        }

                        Spacer()

                        if entry.isFavorite {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(.pink)
                        }
                    }

                    Text(entry.notePreview)
                        .font(.subheadline)
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(2)

                    AudioWaveformView(
                        samples: entry.waveformFingerprint,
                        progress: 1,
                        activeColor: palette.accent,
                        inactiveColor: palette.accent.opacity(0.18),
                        minimumBarHeight: 8
                    )
                    .frame(height: 24)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ResonanceBadge(title: entry.localizedMood, systemImage: "sparkles", atmosphere: entry.atmosphereStyle)
                            ResonanceBadge(title: entry.atmosphereStyle.localizedLabel, systemImage: entry.atmosphereStyle.symbolName, atmosphere: entry.atmosphereStyle)
                            if entry.hasAudio {
                                ResonanceBadge(title: "\(Int(entry.audioDuration.rounded()))秒", systemImage: "waveform", atmosphere: entry.atmosphereStyle)
                            }
                            ForEach(entry.autoTags.prefix(2), id: \.self) { tag in
                                ResonanceBadge(title: tag, systemImage: "tag", atmosphere: entry.atmosphereStyle)
                            }
                            ForEach(matchReasons, id: \.self) { reason in
                                ResonanceBadge(title: reason, systemImage: "magnifyingglass", tint: .orange, atmosphere: entry.atmosphereStyle)
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
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let palette = ResonancePalette.make(for: colorScheme)

        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? palette.accent : palette.surfaceSecondary, in: Capsule())
                .foregroundStyle(isSelected ? Color.white : palette.primaryText)
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

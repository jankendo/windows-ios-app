import SwiftData
import SwiftUI

private struct MemorySearchSuggestion: Identifiable {
    let term: String
    let count: Int
    let systemImage: String

    var id: String { term }
}

struct SearchView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \MemoryEntry.createdAt, order: .reverse) private var entries: [MemoryEntry]
    @State private var searchText = ""
    @State private var selectedMood: String?
    @State private var favoritesOnly = false

    private var filteredEntries: [MemoryEntry] {
        MemorySearchEngine.filter(entries, query: searchText, mood: selectedMood)
            .filter { !favoritesOnly || $0.isFavorite }
    }

    private var suggestedTerms: [MemorySearchSuggestion] {
        guard !entries.isEmpty else {
            return [
                MemorySearchSuggestion(term: "海辺", count: 0, systemImage: "water.waves"),
                MemorySearchSuggestion(term: "夕暮れ", count: 0, systemImage: "sunset.fill"),
                MemorySearchSuggestion(term: "静けさ", count: 0, systemImage: "sparkles"),
                MemorySearchSuggestion(term: "カフェ", count: 0, systemImage: "cup.and.saucer.fill")
            ]
        }

        var suggestions: [String: MemorySearchSuggestion] = [:]

        func merge(_ term: String?, systemImage: String) {
            guard let term = term?.trimmingCharacters(in: .whitespacesAndNewlines), !term.isEmpty else { return }

            if let existing = suggestions[term] {
                suggestions[term] = MemorySearchSuggestion(term: existing.term, count: existing.count + 1, systemImage: existing.systemImage)
            } else {
                suggestions[term] = MemorySearchSuggestion(term: term, count: 1, systemImage: systemImage)
            }
        }

        for entry in entries {
            merge(entry.placeLabel, systemImage: "location.fill")
            merge(entry.localizedMood, systemImage: "sparkles")
            merge(entry.atmosphereStyle.localizedLabel, systemImage: entry.atmosphereStyle.symbolName)
            merge(entry.weatherSnapshot?.conditionLabel, systemImage: entry.weatherSnapshot?.symbolName ?? "cloud.sun.fill")
            for tag in entry.autoTags.prefix(4) {
                merge(tag, systemImage: "tag.fill")
            }
        }

        return suggestions.values
            .sorted { lhs, rhs in
                if lhs.count == rhs.count {
                    return lhs.term < rhs.term
                }
                return lhs.count > rhs.count
            }
            .prefix(12)
            .map { $0 }
    }

    private var palette: ResonancePalette {
        ResonancePalette.make(for: colorScheme)
    }

    var body: some View {
        ZStack {
            ResonanceGradientBackground()

            ScrollView {
                VStack(spacing: 18) {
                    searchHeader
                    suggestionSection
                    moodFilterSection

                    if filteredEntries.isEmpty {
                        ResonanceEmptyState(
                            title: "一致する記録が見つかりませんでした",
                            message: "気分や音のキーワードを変えて探してみてください。",
                            symbol: "magnifyingglass.circle"
                        )
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("\(filteredEntries.count)件の記録")
                                .font(.headline)
                                .foregroundStyle(palette.primaryText)

                            ForEach(filteredEntries) { entry in
                                NavigationLink {
                                    MemoryDetailView(entry: entry)
                                } label: {
                                    VStack(alignment: .leading, spacing: 10) {
                                        MemoryCardView(
                                            entry: entry,
                                            matchReasons: MemorySearchEngine.matchReasons(for: entry, query: searchText)
                                        )

                                        if !entry.transcript.isEmpty, !searchText.isEmpty {
                                            Text("文字起こし: \(entry.transcript)")
                                                .font(.caption)
                                                .foregroundStyle(palette.secondaryText)
                                                .lineLimit(2)
                                                .padding(.horizontal, 6)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("検索")
        .searchable(text: $searchText, prompt: "音、気分、メモで検索")
        .searchSuggestions {
            ForEach(suggestedTerms) { suggestion in
                Text(suggestion.term).searchCompletion(suggestion.term)
            }
        }
    }

    private var searchHeader: some View {
        ResonanceCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("記録を探す")
                    .font(.headline)
                    .foregroundStyle(palette.primaryText)
                Text("タイトル、メモ、文字起こし、自動タグ、ムードから横断して探せます。")
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryText)
            }
        }
    }

    private var suggestionSection: some View {
        ResonanceCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(searchText.isEmpty ? "記録から探す" : "検索ヒント")
                    .font(.headline)
                    .foregroundStyle(palette.primaryText)

                if searchText.isEmpty {
                    Text(entries.isEmpty ? "まだ記録が少ないので、探し方の例を表示しています。" : "あなたの記録に実際に存在する言葉だけを並べています。場所、ムード、音、空気感からそのまま辿れます。")
                        .font(.subheadline)
                        .foregroundStyle(palette.secondaryText)
                } else {
                    Text("一致理由も表示されるので、どこに反応したか確認できます。")
                        .font(.subheadline)
                        .foregroundStyle(palette.secondaryText)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], spacing: 10) {
                    ForEach(suggestedTerms) { suggestion in
                        Button {
                            searchText = suggestion.term
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: suggestion.systemImage)
                                    .foregroundStyle(palette.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.term)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(palette.primaryText)
                                        .lineLimit(1)
                                    if suggestion.count > 0 {
                                        Text("\(suggestion.count)件")
                                            .font(.caption)
                                            .foregroundStyle(palette.secondaryText)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                            .padding(.horizontal, 12)
                            .background(palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var moodFilterSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "すべて", isSelected: selectedMood == nil && !favoritesOnly) {
                    selectedMood = nil
                    favoritesOnly = false
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
            .padding(.horizontal, 4)
        }
    }
}

#Preview {
    NavigationStack {
        SearchView()
    }
    .modelContainer(for: [MemoryEntry.self], inMemory: true)
}

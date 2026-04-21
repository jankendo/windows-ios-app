import SwiftData
import SwiftUI

struct SearchView: View {
    @Query(sort: \MemoryEntry.createdAt, order: .reverse) private var entries: [MemoryEntry]
    @State private var searchText = ""
    @State private var selectedMood: String?
    @State private var favoritesOnly = false

    private var filteredEntries: [MemoryEntry] {
        MemorySearchEngine.filter(entries, query: searchText, mood: selectedMood)
            .filter { !favoritesOnly || $0.isFavorite }
    }

    private var suggestedTerms: [String] {
        let tags = entries
            .flatMap(\.autoTags)
            .reduce(into: [String: Int]()) { partialResult, tag in
                partialResult[tag, default: 0] += 1
            }
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .map(\.key)

        return Array((MemoryMood.allCases.map(\.localizedLabel) + tags).prefix(8))
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
                                                .foregroundStyle(.secondary)
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
            ForEach(suggestedTerms, id: \.self) { term in
                Text(term).searchCompletion(term)
            }
        }
    }

    private var searchHeader: some View {
        ResonanceCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("記録を探す")
                    .font(.headline)
                Text("タイトル、メモ、文字起こし、自動タグ、ムードから横断して探せます。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var suggestionSection: some View {
        ResonanceCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(searchText.isEmpty ? "おすすめの探し方" : "検索ヒント")
                    .font(.headline)

                if searchText.isEmpty {
                    Text("まずは気分や音のキーワードから試すと見つけやすいです。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("一致理由も表示されるので、どこに反応したか確認できます。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggestedTerms, id: \.self) { term in
                            Button(term) {
                                searchText = term
                            }
                            .buttonStyle(.bordered)
                        }
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

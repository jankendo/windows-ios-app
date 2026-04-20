import SwiftData
import SwiftUI

struct SearchView: View {
    @Query(sort: \MemoryEntry.createdAt, order: .reverse) private var entries: [MemoryEntry]
    @State private var searchText = ""
    @State private var selectedMood: String?

    private var filteredEntries: [MemoryEntry] {
        MemorySearchEngine.filter(entries, query: searchText, mood: selectedMood)
    }

    var body: some View {
        List {
            Section("検索") {
                TextField("例: 波の音がする落ち着いた場所", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(
                            title: "Any mood",
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

            Section("結果") {
                if filteredEntries.isEmpty {
                    Text("タイトル・メモ・タグ・文字起こし・ムードに一致するメモリーがありません。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredEntries, id: \.id) { entry in
                        NavigationLink {
                            MemoryDetailView(entry: entry)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                MemoryRowView(entry: entry)

                                if !entry.transcript.isEmpty {
                                    Text("Transcript: \(entry.transcript)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Search")
    }
}

#Preview {
    NavigationStack {
        SearchView()
    }
    .modelContainer(for: [MemoryEntry.self], inMemory: true)
}

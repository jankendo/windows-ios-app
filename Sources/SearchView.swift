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
    @Query(sort: \MemoryCollection.updatedAt, order: .reverse) private var collections: [MemoryCollection]
    @Query(sort: \MemoryScene.startedAt, order: .reverse) private var scenes: [MemoryScene]
    @State private var searchText = ""
    @State private var favoritesOnly = false
    @State private var liveCompassPoint = MoodCompassPoint.zero
    @State private var effectiveCompassPoint = MoodCompassPoint.zero
    @State private var similaritySeedID: UUID?
    @State private var filteredEntriesSnapshot: [MemoryEntry] = []
    @State private var activeSearchPoolSnapshot: [MemoryEntry] = []
    @State private var similarEntriesSnapshot: [MemoryEntry] = []
    @State private var suggestedTermsSnapshot: [MemorySearchSuggestion] = []
    @State private var compassRefreshTask: Task<Void, Never>?

    private var palette: ResonancePalette {
        ResonancePalette.make(for: colorScheme)
    }

    private var filteredEntries: [MemoryEntry] {
        filteredEntriesSnapshot
    }

    private var activeSearchPool: [MemoryEntry] {
        activeSearchPoolSnapshot
    }

    private var activeSimilaritySeed: MemoryEntry? {
        if let similaritySeedID, let matched = entries.first(where: { $0.id == similaritySeedID }) {
            return matched
        }
        return nil
    }

    private var similaritySeed: MemoryEntry? {
        activeSimilaritySeed ?? activeSearchPool.first ?? entries.first
    }

    private var similarEntries: [MemoryEntry] {
        similarEntriesSnapshot
    }

    private var filteredCollections: [MemoryCollection] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let query = searchText.lowercased()
        return collections.filter {
            $0.title.lowercased().contains(query)
                || $0.collectionDescription.lowercased().contains(query)
        }
    }

    private var filteredScenes: [MemoryScene] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let query = searchText.lowercased()
        return scenes.filter { $0.title.lowercased().contains(query) }
    }

    private var hasAnyResults: Bool {
        !filteredEntries.isEmpty || !filteredCollections.isEmpty || !filteredScenes.isEmpty
    }

    private var suggestedTerms: [MemorySearchSuggestion] {
        suggestedTermsSnapshot
    }

    var body: some View {
        ZStack {
            ResonanceGradientBackground()

            VStack(spacing: 16) {
                compassSection
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                ScrollView {
                    LazyVStack(spacing: 18) {
                        suggestionSection
                        similarSpaceSection

                        if !filteredCollections.isEmpty {
                            collectionSection
                        }

                        if !filteredScenes.isEmpty {
                            sceneSection
                        }

                        if !hasAnyResults {
                            ResonanceEmptyState(
                                title: "一致する記録が見つかりませんでした",
                                message: "コンパスの方向や検索語を少し変えて、その場の空気感を辿ってみてください。",
                                symbol: "magnifyingglass.circle"
                            )
                        } else if !filteredEntries.isEmpty {
                            resultSection
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
        }
        .navigationTitle("検索")
        .searchable(text: $searchText, prompt: "音、場所、空気感で検索")
        .searchSuggestions {
            ForEach(suggestedTerms) { suggestion in
                Text(suggestion.term).searchCompletion(suggestion.term)
            }
        }
        .onAppear {
            liveCompassPoint = effectiveCompassPoint
            suggestedTermsSnapshot = buildSuggestedTerms()
            refreshSearchSnapshots()
        }
        .onChange(of: searchText) { _, _ in
            refreshSearchSnapshots()
        }
        .onChange(of: favoritesOnly) { _, _ in
            refreshSearchSnapshots()
        }
        .onChange(of: similaritySeedID) { _, _ in
            refreshSearchSnapshots()
        }
        .onChange(of: effectiveCompassPoint) { _, _ in
            refreshSearchSnapshots()
        }
        .onChange(of: entries.count) { _, _ in
            suggestedTermsSnapshot = buildSuggestedTerms()
            refreshSearchSnapshots()
        }
        .onChange(of: liveCompassPoint) { _, newValue in
            scheduleCompassRefresh(for: newValue)
        }
        .onDisappear {
            compassRefreshTask?.cancel()
        }
    }

    private func refreshSearchSnapshots() {
        let filtered = MemorySearchEngine.filter(
            entries,
            query: searchText,
            mood: nil,
            compass: effectiveCompassPoint,
            similaritySeed: activeSimilaritySeed
        )
        .filter { !favoritesOnly || $0.isFavorite }

        filteredEntriesSnapshot = filtered

        let pool = filtered.isEmpty ? entries : filtered
        let updatedPool = favoritesOnly ? pool.filter { $0.isFavorite } : pool
        activeSearchPoolSnapshot = updatedPool

        if let seed = activeSimilaritySeed ?? updatedPool.first ?? entries.first {
            let similarityPool = Array((updatedPool.count > 1 ? updatedPool : entries).prefix(36))
            similarEntriesSnapshot = MemorySearchEngine.similarEntries(to: seed, from: similarityPool)
        } else {
            similarEntriesSnapshot = []
        }
    }

    private func scheduleCompassRefresh(for point: MoodCompassPoint) {
        compassRefreshTask?.cancel()
        compassRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 55_000_000)
            guard !Task.isCancelled else { return }
            effectiveCompassPoint = point
        }
    }

    private func buildSuggestedTerms() -> [MemorySearchSuggestion] {
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
            merge(entry.atmosphereStyle.localizedLabel, systemImage: entry.atmosphereStyle.symbolName)
            merge(entry.photoCaptionStyle.localizedLabel, systemImage: "text.quote")
            merge(MemorySearchEngine.compassPoint(for: entry).localizedLabel, systemImage: "scope")
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
            .prefix(10)
            .map { $0 }
    }

    private var compassSection: some View {
        ResonanceCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("場の空気感で探す")
                            .font(.headline)
                            .foregroundStyle(palette.primaryText)
                        Text(liveCompassPoint.localizedLabel)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.accent)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        Button {
                            favoritesOnly.toggle()
                        } label: {
                            Label("お気に入り", systemImage: favoritesOnly ? "heart.fill" : "heart")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(favoritesOnly ? .pink : palette.secondaryText.opacity(0.75))

                        Button("リセット") {
                            compassRefreshTask?.cancel()
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                liveCompassPoint = .zero
                                effectiveCompassPoint = .zero
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                    }
                }

                MoodCompassControl(point: $liveCompassPoint, palette: palette)

                Text(searchText.isEmpty ? "ここを静かになぞるだけで、今の気分に近い記録へ寄せていきます。" : "検索語とコンパスを重ねると、言葉と空気感の両方から辿れます。")
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)
            }
        }
    }

    private var suggestionSection: some View {
        ResonanceCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(searchText.isEmpty ? "記録の言葉から探す" : "検索ヒント")
                    .font(.headline)
                    .foregroundStyle(palette.primaryText)

                Text(searchText.isEmpty ? "場所、時間帯、空気感の言葉をそのまま辿れます。" : "一致理由も結果カードに表示されます。")
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryText)

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

    private var similarSpaceSection: some View {
        Group {
            if let similaritySeed, !similarEntries.isEmpty {
                ResonanceCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("類似空間スキャン")
                                    .font(.headline)
                                    .foregroundStyle(palette.primaryText)
                                Text("「\(similaritySeed.displayTitle)」に近い空気感")
                                    .font(.subheadline)
                                    .foregroundStyle(palette.secondaryText)
                            }
                            Spacer()
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(Array(activeSearchPool.prefix(8))) { candidate in
                                    Button {
                                        similaritySeedID = candidate.id
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: candidate.id == similaritySeedID || (similaritySeedID == nil && candidate.id == similaritySeed.id) ? "scope" : "circle")
                                            Text(candidate.displayTitle)
                                                .lineLimit(1)
                                        }
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                        .background(
                                            (candidate.id == similaritySeedID || (similaritySeedID == nil && candidate.id == similaritySeed.id))
                                            ? palette.accent
                                            : palette.surfaceSecondary,
                                            in: Capsule()
                                        )
                                        .foregroundStyle(
                                            (candidate.id == similaritySeedID || (similaritySeedID == nil && candidate.id == similaritySeed.id))
                                            ? Color.white
                                            : palette.primaryText
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        ForEach(similarEntries) { entry in
                            NavigationLink {
                                MemoryDetailView(entry: entry)
                            } label: {
                                MemoryCardView(
                                    entry: entry,
                                    matchReasons: ["類似空間"]
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var collectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("コレクション")
                .font(.headline)
                .foregroundStyle(palette.primaryText)

            ForEach(filteredCollections) { collection in
                NavigationLink {
                    MemoryCollectionDetailView(collection: collection)
                } label: {
                    MemoryCollectionCardView(collection: collection, entries: collection.resolvedEntries(from: entries))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var sceneSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("シーン")
                .font(.headline)
                .foregroundStyle(palette.primaryText)

            ForEach(filteredScenes) { scene in
                NavigationLink {
                    MemorySceneDetailView(scene: scene)
                } label: {
                    MemorySceneCardView(scene: scene, entries: scene.resolvedEntries(from: entries))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var resultSection: some View {
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
                            matchReasons: MemorySearchEngine.matchReasons(for: entry, query: searchText).isEmpty
                                ? [MemorySearchEngine.compassPoint(for: entry).localizedLabel]
                                : MemorySearchEngine.matchReasons(for: entry, query: searchText)
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

private struct MoodCompassControl: View {
    @Binding var point: MoodCompassPoint
    let palette: ResonancePalette

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, 252)
            let center = CGPoint(x: size / 2, y: size / 2)
            let radius = size / 2
            let knobPoint = knobPosition(in: size)

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                palette.surfaceSecondary,
                                palette.surfacePrimary
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .strokeBorder(palette.stroke, lineWidth: 1)

                Path { path in
                    path.move(to: CGPoint(x: center.x, y: 10))
                    path.addLine(to: CGPoint(x: center.x, y: size - 10))
                    path.move(to: CGPoint(x: 10, y: center.y))
                    path.addLine(to: CGPoint(x: size - 10, y: center.y))
                }
                .stroke(palette.stroke.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [4, 6]))

                Circle()
                    .fill(palette.accentSoft)
                    .frame(width: 16, height: 16)

                Circle()
                    .fill(palette.accent)
                    .frame(width: 34, height: 34)
                    .overlay {
                        Circle()
                            .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                    }
                    .shadow(color: palette.accent.opacity(0.28), radius: 12, y: 4)
                    .position(knobPoint)
                    .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.82), value: point)

                VStack {
                    Text("静か")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.secondaryText)
                    Spacer()
                    Text("賑やか")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.secondaryText)
                }
                .padding(.vertical, 8)

                HStack {
                    Text("自然")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.secondaryText)
                    Spacer()
                    Text("都市")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.secondaryText)
                }
                .padding(.horizontal, 8)
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        point = normalizedPoint(from: value.location, center: center, radius: radius)
                    }
                    .onEnded { value in
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            point = snappedPoint(from: normalizedPoint(from: value.location, center: center, radius: radius))
                        }
                    }
            )
        }
        .frame(height: 252)
    }

    private func normalizedPoint(from location: CGPoint, center: CGPoint, radius: CGFloat) -> MoodCompassPoint {
        var dx = location.x - center.x
        var dy = location.y - center.y
        let distance = sqrt((dx * dx) + (dy * dy))
        let clampedDistance = min(distance, radius - 10)
        if distance > 0 {
            dx = dx / distance * clampedDistance
            dy = dy / distance * clampedDistance
        }

        return MoodCompassPoint(
            naturalUrban: Double(dx / (radius - 10)),
            quietLively: Double(dy / (radius - 10))
        )
    }

    private func snappedPoint(from rawPoint: MoodCompassPoint) -> MoodCompassPoint {
        let candidates: [MoodCompassPoint] = [
            .zero,
            MoodCompassPoint(naturalUrban: -0.7, quietLively: -0.7),
            MoodCompassPoint(naturalUrban: 0.7, quietLively: -0.7),
            MoodCompassPoint(naturalUrban: -0.7, quietLively: 0.7),
            MoodCompassPoint(naturalUrban: 0.7, quietLively: 0.7),
            MoodCompassPoint(naturalUrban: -0.88, quietLively: 0),
            MoodCompassPoint(naturalUrban: 0.88, quietLively: 0),
            MoodCompassPoint(naturalUrban: 0, quietLively: -0.88),
            MoodCompassPoint(naturalUrban: 0, quietLively: 0.88)
        ]

        guard let closest = candidates.min(by: { lhs, rhs in
            hypot(lhs.naturalUrban - rawPoint.naturalUrban, lhs.quietLively - rawPoint.quietLively)
                < hypot(rhs.naturalUrban - rawPoint.naturalUrban, rhs.quietLively - rawPoint.quietLively)
        }) else {
            return rawPoint
        }

        let rawDistance = hypot(closest.naturalUrban - rawPoint.naturalUrban, closest.quietLively - rawPoint.quietLively)
        return rawDistance < 0.18 ? closest : rawPoint
    }

    private func knobPosition(in size: CGFloat) -> CGPoint {
        let radius = (size / 2) - 10
        return CGPoint(
            x: (size / 2) + CGFloat(point.naturalUrban) * radius,
            y: (size / 2) + CGFloat(point.quietLively) * radius
        )
    }
}

#Preview {
    NavigationStack {
        SearchView()
    }
    .modelContainer(ResonancePersistence.makeContainer(inMemory: true))
}

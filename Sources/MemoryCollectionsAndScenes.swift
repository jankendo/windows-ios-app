import CoreLocation
import SwiftData
import SwiftUI

struct MemoryCollectionCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    let collection: MemoryCollection
    let entries: [MemoryEntry]

    private var palette: ResonancePalette {
        ResonancePalette.make(for: colorScheme, atmosphere: collection.atmosphereStyle)
    }

    var body: some View {
        let coverEntry = collection.coverMemoryId.flatMap { id in entries.first(where: { $0.id == id }) } ?? entries.first

        ResonanceCard(atmosphere: collection.atmosphereStyle) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    if let coverEntry {
                        MemoryThumbnail(entry: coverEntry, width: nil, height: 148)
                    } else {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(palette.surfaceSecondary)
                            .frame(maxWidth: .infinity, minHeight: 148)
                            .overlay {
                                Image(systemName: collection.isSmartCollection ? "wand.and.stars" : "photo.stack")
                                    .font(.system(size: 28, weight: .semibold))
                                    .foregroundStyle(palette.accent)
                            }
                    }

                    if collection.isSmartCollection {
                        ResonanceBadge(title: "Smart", systemImage: "wand.and.stars", atmosphere: collection.atmosphereStyle)
                            .padding(10)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(collection.title)
                        .font(.headline)
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(2)

                    if !collection.collectionDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(collection.collectionDescription)
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(2)
                    }

                    HStack {
                        Label("\(entries.count)件", systemImage: "square.stack.3d.down.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.secondaryText)
                        Spacer()
                        Text(collection.updatedAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(palette.tertiaryText)
                    }
                }
            }
        }
    }
}

struct MemorySceneCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    let scene: MemoryScene
    let entries: [MemoryEntry]

    private var palette: ResonancePalette {
        ResonancePalette.make(for: colorScheme, atmosphere: entries.first?.atmosphereStyle ?? .day)
    }

    var body: some View {
        ResonanceCard(atmosphere: entries.first?.atmosphereStyle) {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(entries.prefix(5)) { entry in
                            MemoryThumbnail(entry: entry, width: 84, height: 84)
                        }
                    }
                }

                Text(scene.title)
                    .font(.headline)
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(2)

                HStack(spacing: 10) {
                    ResonanceBadge(title: "\(scene.actualCount)/\(scene.plannedCount)枚", systemImage: "camera.aperture", atmosphere: entries.first?.atmosphereStyle)
                    ResonanceBadge(title: "\(scene.intervalSeconds)s間隔", systemImage: "timer", atmosphere: entries.first?.atmosphereStyle)
                    ResonanceBadge(title: "\(Int(scene.clipDurationSeconds.rounded()))s録音", systemImage: "waveform", atmosphere: entries.first?.atmosphereStyle)
                }

                Text(scene.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
            }
        }
    }
}

struct CollectionPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let collections: [MemoryCollection]
    let onSelect: (MemoryCollection) -> Void
    let onCreateNew: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        dismiss()
                        onCreateNew()
                    } label: {
                        Label("新しいコレクションを作成", systemImage: "plus.circle.fill")
                    }
                }

                Section("保存先") {
                    ForEach(collections.filter { !$0.isSmartCollection }) { collection in
                        Button {
                            dismiss()
                            onSelect(collection)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(collection.title)
                                Text("\(collection.entryIDs.count)件")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("コレクションに追加")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct MemoryCollectionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var locationService = CaptureLocationService.shared

    let collection: MemoryCollection?
    let initialEntryIDs: [UUID]

    @State private var title = ""
    @State private var collectionDescription = ""
    @State private var selectedAtmosphere: AtmosphereStyle = .day
    @State private var isSmartCollection = false
    @State private var dateRange: LibraryDateRangeRule = .all
    @State private var selectedMood: MemoryMood?
    @State private var favoritesOnly = false
    @State private var requiredTagsRaw = ""
    @State private var useCurrentLocationRule = false
    @State private var locationRadiusMeters = NearbyMemoriesRadius.meters500.rawValue
    @State private var referenceCoordinate: CLLocationCoordinate2D?

    var body: some View {
        NavigationStack {
            Form {
                Section("基本情報") {
                    TextField("タイトル", text: $title)
                    TextField("説明", text: $collectionDescription, axis: .vertical)
                        .lineLimit(2...4)

                    Picker("テーマ", selection: $selectedAtmosphere) {
                        ForEach(AtmosphereStyle.allCases) { style in
                            Text(style.localizedLabel).tag(style)
                        }
                    }

                    Toggle("スマートコレクション", isOn: $isSmartCollection)
                }

                if isSmartCollection {
                    Section("抽出条件") {
                        Picker("期間", selection: $dateRange) {
                            ForEach(LibraryDateRangeRule.allCases) { value in
                                Text(dateRangeLabel(for: value)).tag(value)
                            }
                        }

                        Picker("ムード", selection: Binding(
                            get: { selectedMood },
                            set: { selectedMood = $0 }
                        )) {
                            Text("指定なし").tag(nil as MemoryMood?)
                            ForEach(MemoryMood.allCases) { mood in
                                Text(mood.localizedLabel).tag(Optional(mood))
                            }
                        }

                        Toggle("お気に入りのみ", isOn: $favoritesOnly)

                        TextField("必須タグ (空白区切り)", text: $requiredTagsRaw)

                        Toggle("現在地を条件に含める", isOn: $useCurrentLocationRule)

                        if useCurrentLocationRule {
                            Picker("半径", selection: $locationRadiusMeters) {
                                ForEach(NearbyMemoriesRadius.allCases) { radius in
                                    Text(radius.localizedLabel).tag(radius.rawValue)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(collection == nil ? "コレクション作成" : "コレクション編集")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveCollection()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task {
                await prepareState()
            }
        }
    }

    private func prepareState() async {
        if let collection {
            title = collection.title
            collectionDescription = collection.collectionDescription
            selectedAtmosphere = collection.atmosphereStyle
            isSmartCollection = collection.isSmartCollection
            if let rule = collection.smartRule {
                dateRange = rule.dateRange ?? .all
                selectedMood = rule.moodRaw.flatMap(MemoryMood.init(rawValue:))
                favoritesOnly = rule.favoritesOnly
                requiredTagsRaw = rule.requiredTags.joined(separator: " ")
                useCurrentLocationRule = rule.referenceLatitude != nil && rule.referenceLongitude != nil
                locationRadiusMeters = rule.radiusMeters ?? NearbyMemoriesRadius.meters500.rawValue
                if let latitude = rule.referenceLatitude, let longitude = rule.referenceLongitude {
                    referenceCoordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                }
            }
            return
        }

        if useCurrentLocationRule, referenceCoordinate == nil {
            referenceCoordinate = await locationService.currentLocation(forceRefresh: true)?.coordinate
        }
    }

    private func saveCollection() {
        if useCurrentLocationRule && referenceCoordinate == nil {
            Task {
                referenceCoordinate = await locationService.currentLocation(forceRefresh: true)?.coordinate
                await MainActor.run {
                    persistCollection()
                }
            }
            return
        }

        persistCollection()
    }

    private func persistCollection() {
        let requiredTags = requiredTagsRaw
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }

        let smartRule = MemoryCollectionSmartRule(
            dateRange: isSmartCollection ? dateRange : nil,
            moodRaw: isSmartCollection ? selectedMood?.rawValue : nil,
            favoritesOnly: isSmartCollection && favoritesOnly,
            requiredTags: isSmartCollection ? requiredTags : [],
            referenceLatitude: isSmartCollection && useCurrentLocationRule ? referenceCoordinate?.latitude : nil,
            referenceLongitude: isSmartCollection && useCurrentLocationRule ? referenceCoordinate?.longitude : nil,
            radiusMeters: isSmartCollection && useCurrentLocationRule ? locationRadiusMeters : nil
        )
        let smartRuleData = try? JSONEncoder().encode(smartRule)
        let smartRuleJSON = smartRuleData.flatMap { String(data: $0, encoding: .utf8) }

        let target = collection ?? MemoryCollection(title: title)
        target.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        target.collectionDescription = collectionDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        target.colorTintRaw = selectedAtmosphere.rawValue
        target.isSmartCollection = isSmartCollection
        target.smartRuleJSON = isSmartCollection ? smartRuleJSON : nil
        if !isSmartCollection {
            target.addEntries(initialEntryIDs)
        }
        target.updatedAt = .now

        if collection == nil {
            modelContext.insert(target)
        }

        try? modelContext.save()
        dismiss()
    }

    private func dateRangeLabel(for value: LibraryDateRangeRule) -> String {
        switch value {
        case .all:
            return "すべて"
        case .today:
            return "今日"
        case .week:
            return "今週"
        case .month:
            return "今月"
        case .year:
            return "今年"
        }
    }
}

struct MemoryCollectionDetailView: View {
    let collection: MemoryCollection

    @Query(sort: \MemoryEntry.createdAt, order: .reverse) private var allEntries: [MemoryEntry]
    @State private var showingSlideshow = false

    private var resolvedEntries: [MemoryEntry] {
        collection.resolvedEntries(from: allEntries)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MemoryCollectionCardView(collection: collection, entries: resolvedEntries)

                Button {
                    showingSlideshow = true
                } label: {
                    Label("スライドショー再生", systemImage: "play.rectangle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .disabled(resolvedEntries.isEmpty)

                ForEach(resolvedEntries) { entry in
                    NavigationLink {
                        MemoryDetailView(entry: entry)
                    } label: {
                        MemoryCardView(entry: entry)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .navigationTitle(collection.title)
        .navigationBarTitleDisplayMode(.inline)
        .background(ResonanceGradientBackground(atmosphere: collection.atmosphereStyle))
        .fullScreenCover(isPresented: $showingSlideshow) {
            AtmosphericMemorySlideshowView(title: collection.title, entries: resolvedEntries)
        }
    }
}

struct MemorySceneDetailView: View {
    let scene: MemoryScene

    @Query(sort: \MemoryEntry.createdAt, order: .reverse) private var allEntries: [MemoryEntry]
    @State private var showingSlideshow = false

    private var resolvedEntries: [MemoryEntry] {
        scene.resolvedEntries(from: allEntries)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MemorySceneCardView(scene: scene, entries: resolvedEntries)

                Button {
                    showingSlideshow = true
                } label: {
                    Label("シーンを再生", systemImage: "play.rectangle.on.rectangle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .disabled(resolvedEntries.isEmpty)

                ForEach(resolvedEntries) { entry in
                    NavigationLink {
                        MemoryDetailView(entry: entry)
                    } label: {
                        MemoryCardView(entry: entry)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .navigationTitle(scene.title)
        .navigationBarTitleDisplayMode(.inline)
        .background(ResonanceGradientBackground(atmosphere: resolvedEntries.first?.atmosphereStyle))
        .fullScreenCover(isPresented: $showingSlideshow) {
            AtmosphericMemorySlideshowView(title: scene.title, entries: resolvedEntries)
        }
    }
}

struct AtmosphericMemorySlideshowView: View {
    let title: String
    let entries: [MemoryEntry]

    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = AudioPlayerController()
    @State private var index = 0
    @State private var slideshowTask: Task<Void, Never>?

    private var currentEntry: MemoryEntry? {
        guard entries.indices.contains(index) else { return nil }
        return entries[index]
    }

    var body: some View {
        ZStack {
            if let currentEntry {
                SavedMemoryImmersivePreviewContainer(entry: currentEntry, player: player)
            } else {
                Color.black.ignoresSafeArea()
            }

            VStack {
                HStack {
                    Button("閉じる") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)

                    Spacer()

                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Spacer()

                if !entries.isEmpty {
                    Text("\(index + 1) / \(entries.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.82))
                        .padding(.bottom, 20)
                }
            }
        }
        .onAppear {
            player.setPlaybackEnvelope(currentEntry?.waveformFingerprint ?? [])
            playCurrentEntry()
            startSlideshowTicker()
        }
        .onChange(of: index) { _, _ in
            player.setPlaybackEnvelope(currentEntry?.waveformFingerprint ?? [])
            playCurrentEntry()
        }
        .onDisappear {
            slideshowTask?.cancel()
            player.stop()
        }
    }

    private func playCurrentEntry() {
        guard let audioURL = currentEntry?.audioURL else { return }
        player.load(url: audioURL, autoPlay: true, loop: false, volume: 0.78)
    }

    private func startSlideshowTicker() {
        slideshowTask?.cancel()
        slideshowTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !entries.isEmpty else { return }
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 1.2)) {
                        index = (index + 1) % entries.count
                    }
                }
            }
        }
    }
}

private struct SavedMemoryImmersivePreviewContainer: View {
    let entry: MemoryEntry
    @ObservedObject var player: AudioPlayerController

    var body: some View {
        ZStack {
            if let image = UIImage(contentsOfFile: entry.photoURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            LinearGradient(
                colors: [Color.black.opacity(0.08), .clear, Color.black.opacity(0.58)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            AtmosphericImmersiveOverlay(
                atmosphere: entry.atmosphereStyle,
                snapshot: entry.sensorSnapshot,
                audioReactiveLevel: player.reactiveLevel
            )
            .ignoresSafeArea()
        }
    }
}

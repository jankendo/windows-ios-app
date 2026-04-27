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
            VStack(alignment: .leading, spacing: 14) {
                scenePreviewStrip

                Text(scene.title)
                    .font(.headline)
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(2)

                sceneStats

                Text(scene.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
            }
        }
    }

    @ViewBuilder
    private var scenePreviewStrip: some View {
        let previewEntries = Array(entries.prefix(3))

        if let heroEntry = previewEntries.first {
            HStack(spacing: 10) {
                MemoryThumbnail(entry: heroEntry, width: nil, height: 148)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                if previewEntries.count > 1 {
                    VStack(spacing: 10) {
                        ForEach(previewEntries.dropFirst()) { entry in
                            MemoryThumbnail(entry: entry, width: 86, height: 69)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }

                        if scene.actualCount > previewEntries.count {
                            Label("+\(scene.actualCount - previewEntries.count)", systemImage: "square.stack.3d.up.fill")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 34)
                                .foregroundStyle(palette.primaryText)
                                .background(palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                    .frame(width: 86)
                }
            }
        } else {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(palette.surfaceSecondary)
                .frame(maxWidth: .infinity, minHeight: 148)
                .overlay {
                    Label("まだ保存されていません", systemImage: "sparkles.rectangle.stack")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.secondaryText)
                }
        }
    }

    private var sceneStats: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                sceneStatBadges
            }

            VStack(alignment: .leading, spacing: 8) {
                sceneStatBadges
            }
        }
    }

    private var sceneStatBadges: some View {
        Group {
            ResonanceBadge(title: "\(scene.actualCount)/\(scene.plannedCount)枚", systemImage: "camera.aperture", atmosphere: entries.first?.atmosphereStyle)
            ResonanceBadge(title: "\(scene.intervalSeconds)s間隔", systemImage: "timer", atmosphere: entries.first?.atmosphereStyle)
            ResonanceBadge(title: "\(Int(scene.clipDurationSeconds.rounded()))s録音", systemImage: "waveform", atmosphere: entries.first?.atmosphereStyle)
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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let scene: MemoryScene
    var showsCompletionCTA = false
    var completionButtonTitle = "このシーンを保存"
    var onComplete: (() -> Void)? = nil

    @Query(sort: \MemoryEntry.createdAt, order: .reverse) private var allEntries: [MemoryEntry]
    @Query(sort: \MemoryCollection.updatedAt, order: .reverse) private var allCollections: [MemoryCollection]
    @Query(sort: \MemoryScene.startedAt, order: .reverse) private var allScenes: [MemoryScene]
    @State private var showingSlideshow = false
    @State private var showingDeleteConfirmation = false

    private var resolvedEntries: [MemoryEntry] {
        scene.resolvedEntries(from: allEntries)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MemorySceneCardView(scene: scene, entries: resolvedEntries)

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
            .padding(.bottom, 110)
        }
        .navigationTitle(scene.title)
        .navigationBarTitleDisplayMode(.inline)
        .background(ResonanceGradientBackground(atmosphere: resolvedEntries.first?.atmosphereStyle))
        .safeAreaInset(edge: .bottom) {
            sceneActionBar
        }
        .toolbar {
            if showsCompletionCTA {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") {
                        dismissCompletedReview()
                    }
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(resolvedEntries.isEmpty)
            }
        }
        .alert("この連続シーンを削除しますか？", isPresented: $showingDeleteConfirmation) {
            Button("削除", role: .destructive) {
                deleteScene()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("このシーンに含まれる \(resolvedEntries.count) 件の記録と関連メディアを端末から削除します。")
        }
        .fullScreenCover(isPresented: $showingSlideshow) {
            AtmosphericMemorySlideshowView(title: scene.title, entries: resolvedEntries)
        }
    }

    private var sceneActionBar: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(scene.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(resolvedEntries.count) 枚 / \(scene.intervalSeconds) 秒間隔")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
            }

            if showsCompletionCTA {
                Button {
                    dismissCompletedReview()
                } label: {
                    Label(completionButtonTitle, systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
            }

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
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }

    private func deleteScene() {
        let relatedScenes = allScenes.filter { $0.id != scene.id }
        for entry in resolvedEntries {
            ResonancePersistence.prune(entryID: entry.id, collections: allCollections, scenes: relatedScenes)
            MediaStore.deleteAssets(for: entry)
            modelContext.delete(entry)
        }
        modelContext.delete(scene)
        try? modelContext.save()
        dismiss()
    }

    private func dismissCompletedReview() {
        onComplete?()
        dismiss()
    }
}

struct AtmosphericMemorySlideshowView: View {
    let title: String
    let entries: [MemoryEntry]

    @Environment(\.dismiss) private var dismiss
    @AppStorage(ResonancePreferenceKey.immersiveParticlesEnabled) private var immersiveParticlesEnabled = true
    @AppStorage(ResonancePreferenceKey.immersiveAudioReactiveLightEnabled) private var immersiveAudioReactiveLightEnabled = true
    @AppStorage(ResonancePreferenceKey.immersiveSlideshowAutoAdvanceEnabled) private var autoAdvanceEnabled = true
    @AppStorage(ResonancePreferenceKey.immersiveSlideshowIntervalSeconds) private var slideIntervalSeconds = 8.0
    @AppStorage(ResonancePreferenceKey.immersivePreviewVolume) private var previewVolume = 0.78
    @StateObject private var player = AudioPlayerController()
    @State private var index = 0
    @State private var slideshowTask: Task<Void, Never>?
    @State private var showingSettings = false

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
        }
        .safeAreaInset(edge: .top) {
            slideshowTopBar
        }
        .safeAreaInset(edge: .bottom) {
            if !entries.isEmpty {
                slideshowBottomBar
            }
        }
        .onAppear {
            player.setPlaybackEnvelope(currentEntry?.waveformFingerprint ?? [])
            player.setVolume(Float(previewVolume))
            playCurrentEntry()
            startSlideshowTicker()
        }
        .onChange(of: index) { _, _ in
            player.setPlaybackEnvelope(currentEntry?.waveformFingerprint ?? [])
            playCurrentEntry()
        }
        .onChange(of: autoAdvanceEnabled) { _, _ in
            startSlideshowTicker()
        }
        .onChange(of: slideIntervalSeconds) { _, _ in
            startSlideshowTicker()
        }
        .onChange(of: previewVolume) { _, newValue in
            player.setVolume(Float(newValue))
        }
        .onDisappear {
            slideshowTask?.cancel()
            player.stop()
        }
        .sheet(isPresented: $showingSettings) {
            slideshowSettingsSheet
        }
    }

    private func playCurrentEntry() {
        guard let audioURL = currentEntry?.analysisAudioURL ?? currentEntry?.audioURL else {
            player.stop()
            return
        }
        player.load(url: audioURL, autoPlay: true, loop: false, volume: Float(previewVolume))
    }

    private func startSlideshowTicker() {
        slideshowTask?.cancel()
        guard autoAdvanceEnabled else { return }
        slideshowTask = Task {
            while !Task.isCancelled {
                let interval = UInt64(max(slideIntervalSeconds, 1) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: interval)
                guard !entries.isEmpty else { return }
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 1.2)) {
                        index = (index + 1) % entries.count
                    }
                }
            }
        }
    }

    private var slideshowTopBar: some View {
        HStack(spacing: 12) {
            Button("閉じる") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(index + 1) / \(entries.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
            }

            Spacer()

            Button {
                showingSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            .tint(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.black.opacity(0.24))
    }

    private var slideshowBottomBar: some View {
        VStack(spacing: 12) {
            HStack {
                Text(autoAdvanceEnabled ? "自動で切替" : "手動で閲覧")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
                Spacer()
                Text("\(Int(slideIntervalSeconds.rounded()))秒")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
            }

            HStack(spacing: 14) {
                Button {
                    guard !entries.isEmpty else { return }
                    withAnimation(.easeInOut(duration: 0.4)) {
                        index = (index - 1 + entries.count) % entries.count
                    }
                } label: {
                    Image(systemName: "backward.fill")
                }
                .buttonStyle(.bordered)
                .tint(.white)

                Button {
                    player.togglePlayback(for: currentEntry?.audioURL)
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.headline.weight(.bold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    guard !entries.isEmpty else { return }
                    withAnimation(.easeInOut(duration: 0.4)) {
                        index = (index + 1) % entries.count
                    }
                } label: {
                    Image(systemName: "forward.fill")
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .background(.black.opacity(0.34))
    }

    private var slideshowSettingsSheet: some View {
        NavigationStack {
            Form {
                Section("再生") {
                    Toggle("自動で次の記録へ進む", isOn: $autoAdvanceEnabled)

                    HStack {
                        Text("切替間隔")
                        Spacer()
                        Text("\(Int(slideIntervalSeconds.rounded()))秒")
                            .foregroundStyle(.secondary)
                    }

                    Slider(value: $slideIntervalSeconds, in: 4...20, step: 1)

                    HStack {
                        Text("音量")
                        Spacer()
                        Text("\(Int((previewVolume * 100).rounded()))%")
                            .foregroundStyle(.secondary)
                    }

                    Slider(value: $previewVolume, in: 0...1, step: 0.05)
                }

                Section("没入演出") {
                    Toggle("環境粒子", isOn: $immersiveParticlesEnabled)
                    Toggle("音量連動の光", isOn: $immersiveAudioReactiveLightEnabled)
                }
            }
            .navigationTitle("シーン再生設定")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
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
                audioReactiveLevel: player.reactiveLevel,
                hotspots: entry.directionalHotspots
            )
            .ignoresSafeArea()
        }
    }
}

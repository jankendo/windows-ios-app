import MapKit
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

private enum LibraryMode: String, CaseIterable, Identifiable {
    case timeline
    case map

    var id: String { rawValue }

    var label: String {
        switch self {
        case .timeline:
            return "一覧"
        case .map:
            return "地図"
        }
    }
}

private enum MemoryDateFilter: String, CaseIterable, Identifiable {
    case all
    case today
    case week
    case month
    case year

    var id: String { rawValue }

    var label: String {
        switch self {
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

private struct MapPinGroup: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let entries: [MemoryEntry]

    var count: Int { entries.count }
    var representativeEntry: MemoryEntry? { entries.first }
}

struct LibraryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MemoryEntry.createdAt, order: .reverse) private var entries: [MemoryEntry]
    @Query(sort: \MemoryCollection.updatedAt, order: .reverse) private var collections: [MemoryCollection]
    @Query(sort: \MemoryScene.startedAt, order: .reverse) private var scenes: [MemoryScene]
    @ObservedObject private var locationService = CaptureLocationService.shared
    @AppStorage(ResonancePreferenceKey.timeCapsuleEnabled) private var timeCapsuleEnabled = true
    @AppStorage(ResonancePreferenceKey.nearbyMemoriesEnabled) private var nearbyMemoriesEnabled = true
    @AppStorage(ResonancePreferenceKey.nearbyMemoriesRadius) private var nearbyMemoriesRadius = NearbyMemoriesRadius.meters500.rawValue

    @State private var selectedMode: LibraryMode = .timeline
    @State private var selectedMood: String?
    @State private var selectedAtmosphere: AtmosphereStyle?
    @State private var favoritesOnly = false
    @State private var hasAudioOnly = false
    @State private var sortOption: LibrarySortOption = .newest
    @State private var selectedDateFilter: MemoryDateFilter = .all
    @State private var showingFilterSheet = false
    @State private var selectedMapEntry: MemoryEntry?
    @State private var mapRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 35.681236, longitude: 139.767125),
        span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
    )
    @State private var captionRefreshToken = 0
    @State private var isSelectionModeEnabled = false
    @State private var selectedEntryIDs: Set<UUID> = []
    @State private var showingBulkDeleteConfirmation = false
    @State private var filteredEntryIDsCache: [UUID] = []
    @State private var currentLocation: CLLocation?
    @State private var showingCollectionPicker = false
    @State private var showingCollectionEditor = false
    @State private var collectionDraftEntryIDs: [UUID] = []
    @State private var editingCollection: MemoryCollection?

    private var palette: ResonancePalette {
        ResonancePalette.make(for: colorScheme)
    }

    private var manualCollections: [MemoryCollection] {
        collections.filter { !$0.isSmartCollection }
    }

    private var nearbyRadius: NearbyMemoriesRadius {
        NearbyMemoriesRadius(rawValue: nearbyMemoriesRadius) ?? .meters500
    }

    private var filteredEntryIDs: [UUID] {
        filteredEntries.map(\.id)
    }

    private var selectedEntries: [MemoryEntry] {
        entries.filter { selectedEntryIDs.contains($0.id) }
    }

    private var cardGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 168, maximum: 240), spacing: 14, alignment: .top)]
    }

    private var filteredEntries: [MemoryEntry] {
        let entryLookup = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        return filteredEntryIDsCache.compactMap { entryLookup[$0] }
    }

    private var mapEntries: [MemoryEntry] {
        filteredEntries.filter {
            guard let coordinate = $0.coordinate else { return false }
            return CLLocationCoordinate2DIsValid(coordinate)
                && coordinate.latitude.isFinite
                && coordinate.longitude.isFinite
        }
    }

    private var visibleMapEntries: [MemoryEntry] {
        mapEntries.filter { entry in
            guard let coordinate = entry.coordinate else { return false }

            let latitudeHalfSpan = mapRegion.span.latitudeDelta / 2
            let longitudeHalfSpan = mapRegion.span.longitudeDelta / 2
            let latitudePadding = max(latitudeHalfSpan * 0.08, 0.002)
            let longitudePadding = max(longitudeHalfSpan * 0.08, 0.002)
            let latitudeRange = (mapRegion.center.latitude - latitudeHalfSpan - latitudePadding)...(mapRegion.center.latitude + latitudeHalfSpan + latitudePadding)
            let longitudeRange = (mapRegion.center.longitude - longitudeHalfSpan - longitudePadding)...(mapRegion.center.longitude + longitudeHalfSpan + longitudePadding)

            return latitudeRange.contains(coordinate.latitude) && longitudeRange.contains(coordinate.longitude)
        }
    }

    private var mapPinGroups: [MapPinGroup] {
        guard !mapEntries.isEmpty else { return [] }

        let latitudeBucket = max(mapRegion.span.latitudeDelta / 10, 0.003)
        let longitudeBucket = max(mapRegion.span.longitudeDelta / 10, 0.003)
        var grouped: [String: [MemoryEntry]] = [:]

        for entry in mapEntries {
            guard let coordinate = entry.coordinate else { continue }
            let latitudeIndex = Int(floor(coordinate.latitude / latitudeBucket))
            let longitudeIndex = Int(floor(coordinate.longitude / longitudeBucket))
            let key = "\(latitudeIndex):\(longitudeIndex)"
            grouped[key, default: []].append(entry)
        }

        return grouped.map { key, entries in
            let sortedEntries = entries.sorted { $0.createdAt > $1.createdAt }
            let coordinates = sortedEntries.compactMap(\.coordinate)
            let representativeCoordinate = coordinates.first ?? mapRegion.center
            let latitude = coordinates.isEmpty
                ? representativeCoordinate.latitude
                : coordinates.map(\.latitude).reduce(0, +) / Double(coordinates.count)
            let longitude = coordinates.isEmpty
                ? representativeCoordinate.longitude
                : coordinates.map(\.longitude).reduce(0, +) / Double(coordinates.count)

            return MapPinGroup(
                id: key,
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                entries: sortedEntries
            )
        }
        .sorted { lhs, rhs in
            if lhs.count == rhs.count {
                return (lhs.representativeEntry?.createdAt ?? .distantPast) > (rhs.representativeEntry?.createdAt ?? .distantPast)
            }
            return lhs.count > rhs.count
        }
    }

    private var selectedVisibleMapEntryID: Binding<UUID?> {
        Binding(
            get: { selectedMapEntry?.id },
            set: { newValue in
                selectedMapEntry = visibleMapEntries.first { $0.id == newValue }
            }
        )
    }

    private var selectedVisibleMapIndex: Int? {
        guard let selectedMapEntry else { return nil }
        return visibleMapEntries.firstIndex { $0.id == selectedMapEntry.id }
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

    private var timeCapsuleEntries: [MemoryEntry] {
        guard timeCapsuleEnabled else { return [] }
        let calendar = Calendar.current
        let todayComponents = calendar.dateComponents([.month, .day], from: .now)

        return filteredEntries
            .filter {
                let components = calendar.dateComponents([.month, .day, .year], from: $0.createdAt)
                return components.month == todayComponents.month
                    && components.day == todayComponents.day
                    && (components.year ?? 0) < calendar.component(.year, from: .now)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var nearbyEntries: [MemoryEntry] {
        guard nearbyMemoriesEnabled, let currentLocation else { return [] }

        return filteredEntries
            .filter { entry in
                guard let coordinate = entry.coordinate else { return false }
                let distance = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                    .distance(from: currentLocation)
                return distance <= nearbyRadius.rawValue
            }
            .sorted { lhs, rhs in
                distance(to: lhs) < distance(to: rhs)
            }
    }

    var body: some View {
        let _ = captionRefreshToken
        return libraryScaffold
    }

    private var libraryScaffold: some View {
        libraryAlertView
    }

    private var libraryAlertView: some View {
        libraryObservedView
            .alert("選択した記録を削除しますか？", isPresented: $showingBulkDeleteConfirmation) {
                Button("削除", role: .destructive) {
                    deleteSelectedEntries()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("\(selectedEntries.count)件の写真、音声、メモ情報がこの端末から削除されます。")
            }
    }

    private var libraryObservedView: some View {
        libraryMapTrackingView
    }

    private var libraryMapTrackingView: some View {
        libraryModeTrackingView
            .onChange(of: mapRegion.center.latitude) { _, _ in syncVisibleMapSelection() }
            .onChange(of: mapRegion.center.longitude) { _, _ in syncVisibleMapSelection() }
            .onChange(of: mapRegion.span.latitudeDelta) { _, _ in syncVisibleMapSelection() }
            .onChange(of: mapRegion.span.longitudeDelta) { _, _ in syncVisibleMapSelection() }
    }

    private var libraryModeTrackingView: some View {
        libraryRefreshTrackingView
            .onChange(of: selectedMode) { _, newMode in
                if newMode != .timeline {
                    endSelectionMode()
                }
            }
    }

    private var libraryRefreshTrackingView: some View {
        libraryLifecycleView
            .onChange(of: entries.count) { _, _ in refreshLibraryState() }
            .onChange(of: collections.count) { _, _ in refreshLibraryState() }
            .onChange(of: scenes.count) { _, _ in refreshLibraryState() }
            .onChange(of: selectedDateFilter) { _, _ in refreshLibraryState() }
            .onChange(of: selectedMood) { _, _ in refreshLibraryState() }
            .onChange(of: selectedAtmosphere) { _, _ in refreshLibraryState() }
            .onChange(of: favoritesOnly) { _, _ in refreshLibraryState() }
            .onChange(of: hasAudioOnly) { _, _ in refreshLibraryState() }
            .onChange(of: sortOption) { _, _ in refreshLibraryState() }
            .onChange(of: nearbyMemoriesEnabled) { _, _ in refreshLibraryState() }
            .onChange(of: nearbyMemoriesRadius) { _, _ in refreshLibraryState() }
            .onChange(of: filteredEntryIDs) { _, _ in pruneSelectionToVisibleEntries() }
    }

    private var libraryLifecycleView: some View {
        librarySheetsView
            .onAppear {
                refreshLibraryState()
                Task { await refreshCurrentLocation() }
            }
    }

    private var librarySheetsView: some View {
        libraryCollectionEditorSheet
    }

    private var libraryCollectionEditorSheet: some View {
        libraryCollectionPickerSheet
            .sheet(isPresented: $showingCollectionEditor) {
                MemoryCollectionEditorView(
                    collection: editingCollection,
                    initialEntryIDs: collectionDraftEntryIDs
                )
            }
    }

    private var libraryCollectionPickerSheet: some View {
        libraryFilterSheet
            .sheet(isPresented: $showingCollectionPicker) {
                CollectionPickerSheet(
                    collections: manualCollections,
                    onSelect: { collection in
                        addEntries(collectionDraftEntryIDs, to: collection)
                    },
                    onCreateNew: {
                        editingCollection = nil
                        showingCollectionEditor = true
                    }
                )
            }
    }

    private var libraryFilterSheet: some View {
        libraryChrome
            .sheet(isPresented: $showingFilterSheet) {
                AdvancedLibraryFilterSheet(
                    selectedMood: $selectedMood,
                    selectedAtmosphere: $selectedAtmosphere,
                    favoritesOnly: $favoritesOnly,
                    hasAudioOnly: $hasAudioOnly
                )
                .presentationDetents([.medium])
            }
    }

    private var libraryChrome: some View {
        ZStack {
            ResonanceGradientBackground()

            if selectedMode == .map {
                mapExperience
            } else {
                timelineExperience
            }
        }
        .navigationTitle("ライブラリ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            timelineToolbar
        }
    }

    @ToolbarContentBuilder
    private var timelineToolbar: some ToolbarContent {
        if selectedMode == .timeline, (!filteredEntries.isEmpty || isSelectionModeEnabled) {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(isSelectionModeEnabled ? "完了" : "選択") {
                    toggleSelectionMode()
                }

                if isSelectionModeEnabled {
                    Button {
                        collectionDraftEntryIDs = selectedEntries.map(\.id)
                        showingCollectionPicker = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .disabled(selectedEntries.isEmpty)

                    Button(role: .destructive) {
                        showingBulkDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(selectedEntries.isEmpty)
                }
            }
        }
    }

    private var timelineExperience: some View {
        ScrollView {
            VStack(spacing: 18) {
                summaryCard
                modePicker
                filterBar
                reunionSection
                collectionsSection
                scenesSection

                if entries.isEmpty {
                    emptyState
                } else if filteredEntries.isEmpty {
                    ResonanceEmptyState(
                        title: "条件に合う記録がありません",
                        message: "時期や空気感の条件を少し変えると、別の記録に出会えるかもしれません。",
                        symbol: "line.3.horizontal.decrease.circle"
                    )
                } else {
                    timelineSection
                }
            }
            .padding(20)
        }
    }

    private var mapExperience: some View {
        ZStack {
            if mapEntries.isEmpty {
                VStack(spacing: 18) {
                    mapTopChrome
                    Spacer()
                    ResonanceEmptyState(
                        title: "地図に表示できる記録がありません",
                        message: "位置情報が付いた記録を保存すると、ここから場所ごとに思い出を選べます。",
                        symbol: "map"
                    )
                    .padding(.horizontal, 20)
                    Spacer()
                }
            } else {
                Map(coordinateRegion: $mapRegion, annotationItems: mapPinGroups) { group in
                    MapAnnotation(coordinate: group.coordinate) {
                        Button {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                                handleMapPinSelection(group)
                            }
                        } label: {
                            ClusteredMapPinView(
                                group: group,
                                isSelected: group.entries.contains(where: { $0.id == selectedMapEntry?.id }),
                                palette: palette
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    mapTopChrome
                }
                .overlay(alignment: .bottom) {
                    mapBottomChrome
                }
            }
        }
    }

    private var summaryCard: some View {
        ResonanceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Spatial Library")
                            .font(.headline)
                            .foregroundStyle(palette.primaryText)
                        Text("撮影した記録を、時期・空気・場所からたどれます。")
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
                    ResonanceStatTile(title: "地図対応", value: "\(entries.filter { $0.hasMapLocation }.count)", symbol: "map.fill")
                    if nearbyMemoriesEnabled {
                        ResonanceStatTile(title: "近く", value: "\(nearbyEntries.count)", symbol: "location.fill")
                    }
                }
            }
        }
    }

    private var modePicker: some View {
        Picker("表示モード", selection: $selectedMode) {
            ForEach(LibraryMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(MemoryDateFilter.allCases) { filter in
                        Button(filter.label) {
                            selectedDateFilter = filter
                        }
                    }
                } label: {
                    menuFilterLabel(title: selectedDateFilter.label, isSelected: selectedDateFilter != .all)
                }

                Menu {
                    Button("すべて") { selectedAtmosphere = nil }
                    ForEach(AtmosphereStyle.allCases) { style in
                        Button(style.localizedLabel) {
                            selectedAtmosphere = style
                        }
                    }
                } label: {
                    menuFilterLabel(title: selectedAtmosphere?.localizedLabel ?? "時間帯", isSelected: selectedAtmosphere != nil)
                }

                FilterChip(title: "お気に入り", isSelected: favoritesOnly) {
                    favoritesOnly.toggle()
                }

                Button {
                    showingFilterSheet = true
                } label: {
                    FilterChip(title: "詳細", isSelected: hasAudioOnly || selectedMood != nil) {}
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
        }
    }

    private var timelineSection: some View {
        VStack(spacing: 16) {
            if isSelectionModeEnabled {
                selectionBar
            }

            ForEach(groupedEntries, id: \.title) { section in
                VStack(alignment: .leading, spacing: 12) {
                    Text(section.title)
                        .font(.title3.bold())
                        .foregroundStyle(palette.primaryText)

                    VStack(spacing: 12) {
                        ForEach(section.entries) { entry in
                            timelineListEntry(for: entry)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Label(
                selectedEntries.isEmpty ? "削除したい記録を選択" : "\(selectedEntries.count)件を選択中",
                systemImage: "checkmark.circle"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(palette.primaryText)

            Spacer()

            if !selectedEntries.isEmpty {
                Button(role: .destructive) {
                    showingBulkDeleteConfirmation = true
                } label: {
                    Label("削除", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(palette.surfacePrimary, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(palette.stroke)
        }
    }

    @ViewBuilder
    private var reunionSection: some View {
        if timeCapsuleEnabled || nearbyMemoriesEnabled {
            VStack(alignment: .leading, spacing: 14) {
                if !timeCapsuleEntries.isEmpty {
                    sectionHeader(title: "Time Capsule", subtitle: "過去の同じ日に残した空気")

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(timeCapsuleEntries.prefix(6)) { entry in
                                NavigationLink {
                                    MemoryDetailView(entry: entry)
                                } label: {
                                    TimeCapsuleCard(entry: entry)
                                        .frame(width: 248)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                if nearbyMemoriesEnabled {
                    nearbySection
                }
            }
        }
    }

    @ViewBuilder
    private var nearbySection: some View {
        if let currentLocation {
            if nearbyEntries.isEmpty {
                ResonanceCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("近くの記録")
                            .font(.headline)
                            .foregroundStyle(palette.primaryText)
                        Text("\(nearbyRadius.localizedLabel)圏内にはまだ記録がありません。少し離れた場所で残した空気は、再び訪れたときにここへ出ます。")
                            .font(.subheadline)
                            .foregroundStyle(palette.secondaryText)
                    }
                }
            } else {
                sectionHeader(title: "近くの記録", subtitle: "\(nearbyRadius.localizedLabel) 圏内で再会できる記録")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(nearbyEntries.prefix(8)) { entry in
                            NearbyMemoryCard(
                                entry: entry,
                                distanceText: distanceText(for: entry, from: currentLocation),
                                onOpenMap: { focusMap(on: entry) }
                            )
                            .frame(width: 272)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } else {
            ResonanceCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("近くの記録")
                        .font(.headline)
                        .foregroundStyle(palette.primaryText)
                    Text("現在地の取得後に、今いる場所の近くに残した記録を表示します。")
                        .font(.subheadline)
                        .foregroundStyle(palette.secondaryText)
                }
            }
            .task {
                await refreshCurrentLocation()
            }
        }
    }

    @ViewBuilder
    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionHeader(title: "コレクション", subtitle: "場所やテーマで束ねた記憶")
                Spacer()
                Button {
                    collectionDraftEntryIDs = []
                    editingCollection = nil
                    showingCollectionEditor = true
                } label: {
                    Label("作成", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                }
            }

            if collections.isEmpty {
                ResonanceCard {
                    Text("手動コレクションやスマートコレクションを作ると、複数の記録をひとまとまりで再生できます。")
                        .font(.subheadline)
                        .foregroundStyle(palette.secondaryText)
                }
            } else {
                LazyVGrid(columns: cardGridColumns, spacing: 14) {
                    ForEach(collections) { collection in
                        NavigationLink {
                            MemoryCollectionDetailView(collection: collection)
                        } label: {
                            MemoryCollectionCardView(collection: collection, entries: collection.resolvedEntries(from: entries))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("編集") {
                                editingCollection = collection
                                collectionDraftEntryIDs = collection.entryIDs
                                showingCollectionEditor = true
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var scenesSection: some View {
        if !scenes.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(title: "シーン", subtitle: "連続して残した記録の束")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(scenes) { scene in
                            NavigationLink {
                                MemorySceneDetailView(scene: scene)
                            } label: {
                                MemorySceneCardView(scene: scene, entries: scene.resolvedEntries(from: entries))
                                    .frame(width: 280)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var mapSection: some View {
        VStack(spacing: 14) {
            if mapEntries.isEmpty {
                ResonanceEmptyState(
                    title: "地図に表示できる記録がありません",
                    message: "位置情報が付いた記録を保存すると、ここから場所ごとに思い出を選べます。",
                    symbol: "map"
                )
            } else {
                 ZStack(alignment: .bottom) {
                     Map(coordinateRegion: $mapRegion, annotationItems: mapEntries) { entry in
                        MapAnnotation(coordinate: entry.coordinate ?? mapRegion.center) {
                            Button {
                                selectedMapEntry = entry
                            } label: {
                                VStack(spacing: 6) {
                                    MemoryThumbnail(entry: entry, width: 44, height: 44)
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .strokeBorder(selectedMapEntry?.id == entry.id ? palette.accent : Color.white, lineWidth: 2)
                                        }

                                    Image(systemName: "mappin.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(selectedMapEntry?.id == entry.id ? palette.accent : .white)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(height: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .strokeBorder(.white.opacity(0.14))
                    }

                    if let selectedMapEntry {
                        NavigationLink {
                            MemoryDetailView(entry: selectedMapEntry)
                        } label: {
                            MapSelectionCard(entry: selectedMapEntry)
                        }
                        .buttonStyle(.plain)
                        .padding(16)
                    }
                }
            }
        }
    }

    private var mapTopChrome: some View {
        VStack(spacing: 12) {
            modePicker

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Spatial Map")
                        .font(.headline)
                        .foregroundStyle(palette.primaryText)
                    Spacer()
                    Text("\(mapEntries.count)件")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.secondaryText)
                }

                filterBar
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(palette.stroke)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var mapBottomChrome: some View {
        VStack(spacing: 10) {
            HStack {
                Text("画面内の記録をスワイプで選ぶ")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
                Spacer()
                Text("画面内 \(visibleMapEntries.count)件")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.68))
            }
            .padding(.horizontal, 4)

            if visibleMapEntries.isEmpty {
                Text("この画面内には記録がありません")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.84))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            } else {
                HStack(spacing: 8) {
                    if visibleMapEntries.count > 1 {
                        carouselArrow(systemImage: "chevron.left", isEnabled: (selectedVisibleMapIndex ?? 0) > 0) {
                            moveVisibleSelection(by: -1)
                        }
                    }

                    TabView(selection: selectedVisibleMapEntryID) {
                        ForEach(visibleMapEntries) { entry in
                            NavigationLink {
                                MemoryDetailView(entry: entry)
                            } label: {
                                MapSelectionCard(entry: entry)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                                            .strokeBorder(selectedMapEntry?.id == entry.id ? palette.accent : .white.opacity(0.08), lineWidth: selectedMapEntry?.id == entry.id ? 2 : 1)
                                    }
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 4)
                            .tag(Optional(entry.id))
                        }
                    }
                    .frame(height: 164)
                    .tabViewStyle(.page(indexDisplayMode: .never))

                    if visibleMapEntries.count > 1 {
                        carouselArrow(
                            systemImage: "chevron.right",
                            isEnabled: (selectedVisibleMapIndex ?? 0) < visibleMapEntries.count - 1
                        ) {
                            moveVisibleSelection(by: 1)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
    }

    private var emptyState: some View {
        ResonanceEmptyState(
            title: "まだ記録はありません",
            message: "最初の1件を残すと、ここに写真と環境音が並びます。",
            symbol: "photo.on.rectangle.angled"
        )
    }

    private var selectedDateBounds: (start: Date, end: Date) {
        let calendar = Calendar.current
        let now = Date.now

        switch selectedDateFilter {
        case .all:
            return (.distantPast, .distantFuture)
        case .today:
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? .distantFuture
            return (start, end)
        case .week:
            let interval = calendar.dateInterval(of: .weekOfYear, for: now)
            return (interval?.start ?? .distantPast, interval?.end ?? .distantFuture)
        case .month:
            let interval = calendar.dateInterval(of: .month, for: now)
            return (interval?.start ?? .distantPast, interval?.end ?? .distantFuture)
        case .year:
            let interval = calendar.dateInterval(of: .year, for: now)
            return (interval?.start ?? .distantPast, interval?.end ?? .distantFuture)
        }
    }

    private func updateMapRegion() {
        let coordinates = mapEntries.compactMap(\.coordinate)
        guard !coordinates.isEmpty else { return }

        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        guard
            let minLatitude = latitudes.min(),
            let maxLatitude = latitudes.max(),
            let minLongitude = longitudes.min(),
            let maxLongitude = longitudes.max()
        else {
            return
        }

        let center = CLLocationCoordinate2D(
            latitude: (minLatitude + maxLatitude) / 2,
            longitude: (minLongitude + maxLongitude) / 2
        )

        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLatitude - minLatitude) * 1.6, 0.03),
            longitudeDelta: max((maxLongitude - minLongitude) * 1.6, 0.03)
        )

        mapRegion = MKCoordinateRegion(center: center, span: span)
    }

    private func syncMapSelection() {
        updateMapRegion()
        syncVisibleMapSelection()
    }

    private func syncVisibleMapSelection() {
        if visibleMapEntries.isEmpty {
            selectedMapEntry = nil
        } else if let selectedMapEntry, !visibleMapEntries.contains(where: { $0.id == selectedMapEntry.id }) {
            self.selectedMapEntry = visibleMapEntries.first
        } else if selectedMapEntry == nil {
            selectedMapEntry = visibleMapEntries.first
        }
    }

    private func refreshLibraryState() {
        recomputeFilteredEntries()
        pruneSelectionToVisibleEntries()
        syncMapSelection()
        Task {
            await backfillVisiblePhotoCaptionsIfNeeded()
        }
    }

    private func pruneSelectionToVisibleEntries() {
        let visibleIDs = Set(filteredEntries.map(\.id))
        selectedEntryIDs.formIntersection(visibleIDs)
        if isSelectionModeEnabled, visibleIDs.isEmpty {
            endSelectionMode()
        }
    }

    private func toggleSelectionMode() {
        if isSelectionModeEnabled {
            endSelectionMode()
        } else {
            isSelectionModeEnabled = true
            pruneSelectionToVisibleEntries()
        }
    }

    private func endSelectionMode() {
        isSelectionModeEnabled = false
        selectedEntryIDs.removeAll()
    }

    private func toggleSelection(for entry: MemoryEntry) {
        if selectedEntryIDs.contains(entry.id) {
            selectedEntryIDs.remove(entry.id)
        } else {
            selectedEntryIDs.insert(entry.id)
        }
    }

    private func deleteSelectedEntries() {
        let entriesToDelete = selectedEntries
        guard !entriesToDelete.isEmpty else {
            endSelectionMode()
            return
        }

        AudioPlaybackDiagnostics.shared.record("bulk delete requested count=\(entriesToDelete.count)", category: "storage")

        for entry in entriesToDelete {
            ResonancePersistence.prune(entryID: entry.id, collections: collections, scenes: scenes)
            MediaStore.deleteAssets(for: entry)
            modelContext.delete(entry)
        }

        do {
            try modelContext.save()
            AudioPlaybackDiagnostics.shared.record("bulk delete completed count=\(entriesToDelete.count)", category: "storage")
            endSelectionMode()
            refreshLibraryState()
        } catch {
            AudioPlaybackDiagnostics.shared.record(
                "bulk delete save failed count=\(entriesToDelete.count) error=\(error.localizedDescription)",
                category: "storage"
            )
        }
    }

    private func handleMapPinSelection(_ group: MapPinGroup) {
        if let currentlySelected = selectedMapEntry,
           let matchingEntry = group.entries.first(where: { $0.id == currentlySelected.id }) {
            selectedMapEntry = matchingEntry
        } else {
            selectedMapEntry = group.representativeEntry
        }

        guard group.count > 1 else { return }
        mapRegion = focusedRegion(for: group)
    }

    private func focusedRegion(for group: MapPinGroup) -> MKCoordinateRegion {
        let coordinates = group.entries.compactMap(\.coordinate)
        guard !coordinates.isEmpty else { return mapRegion }

        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        let minLatitude = latitudes.min() ?? group.coordinate.latitude
        let maxLatitude = latitudes.max() ?? group.coordinate.latitude
        let minLongitude = longitudes.min() ?? group.coordinate.longitude
        let maxLongitude = longitudes.max() ?? group.coordinate.longitude

        return MKCoordinateRegion(
            center: group.coordinate,
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLatitude - minLatitude) * 2.4, mapRegion.span.latitudeDelta * 0.42, 0.012),
                longitudeDelta: max((maxLongitude - minLongitude) * 2.4, mapRegion.span.longitudeDelta * 0.42, 0.012)
            )
        )
    }

    private func backfillVisiblePhotoCaptionsIfNeeded() async {
        let candidateEntries = Array((Array(filteredEntries.prefix(12)) + Array(visibleMapEntries.prefix(8))).reduce(into: [UUID: MemoryEntry]()) { partialResult, entry in
            partialResult[entry.id] = entry
        }.values)

        var updatedAnyCaption = false

        for entry in candidateEntries {
            let needsCaptionRefresh = entry.atmosphereMetadata?.needsPhotoCaptionRefresh ?? true
            if let existingCaption = entry.photoCaption, !existingCaption.isEmpty, !needsCaptionRefresh {
                continue
            }
            guard let imageData = try? Data(contentsOf: entry.photoURL) else { continue }
            guard let generation = await MemoryAnalysisService.captionGeneration(
                from: imageData,
                title: entry.title,
                placeLabel: entry.placeLabel
            ) else { continue }
            do {
                try MediaStore.updateAtmosphereMetadata(for: entry.id) { metadata in
                    let existingCaption = metadata.photoCaption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if existingCaption.isEmpty || metadata.needsPhotoCaptionRefresh {
                        metadata.photoCaption = generation.text
                        metadata.photoCaptionSourceRaw = generation.source.rawValue
                        metadata.photoCaptionVersion = MemoryAtmosphereMetadata.currentPhotoCaptionVersion
                    }
                }
                updatedAnyCaption = true
            } catch {
                continue
            }
        }

        if updatedAnyCaption {
            await MainActor.run {
                captionRefreshToken += 1
            }
        }
    }

    private func moveVisibleSelection(by delta: Int) {
        guard let currentIndex = selectedVisibleMapIndex else { return }
        let targetIndex = min(max(currentIndex + delta, 0), visibleMapEntries.count - 1)
        guard targetIndex != currentIndex else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            selectedMapEntry = visibleMapEntries[targetIndex]
        }
    }

    private func recomputeFilteredEntries() {
        let bounds = selectedDateBounds
        let startDate = bounds.start
        let endDate = bounds.end
        let selectedMoodValue = selectedMood ?? "__all__"
        let shouldMatchMood = selectedMood != nil
        let shouldMatchFavorites = favoritesOnly
        let shouldMatchAudio = hasAudioOnly
        let emptyAudioName = ""
        let sortOrder: SortOrder = sortOption == .newest ? .reverse : .forward

        let predicate = #Predicate<MemoryEntry> { entry in
            entry.createdAt >= startDate
                && entry.createdAt < endDate
                && (!shouldMatchFavorites || entry.isFavorite)
                && (!shouldMatchAudio || (entry.audioFileName != nil && entry.audioFileName != emptyAudioName))
                && (!shouldMatchMood || entry.mood == selectedMoodValue)
        }

        var descriptor = FetchDescriptor<MemoryEntry>(
            predicate: predicate,
            sortBy: [SortDescriptor<MemoryEntry>(\.createdAt, order: sortOrder)]
        )
        descriptor.fetchLimit = 5000

        do {
            let fetched = try modelContext.fetch(descriptor)
            let atmosphereFiltered = fetched.filter { selectedAtmosphere == nil || $0.atmosphereStyle == selectedAtmosphere }
            filteredEntryIDsCache = atmosphereFiltered.map(\.id)
        } catch {
            AudioPlaybackDiagnostics.shared.record("library fetch failed: \(error.localizedDescription)", category: "storage")
            let fallback = entries
                .filter { $0.createdAt >= bounds.start && $0.createdAt < bounds.end }
                .filter { !favoritesOnly || $0.isFavorite }
                .filter { !hasAudioOnly || $0.hasAudio }
                .filter { !shouldMatchMood || $0.mood == selectedMoodValue }
                .filter { selectedAtmosphere == nil || $0.atmosphereStyle == selectedAtmosphere }

            switch sortOption {
            case .newest:
                filteredEntryIDsCache = fallback.sorted { $0.createdAt > $1.createdAt }.map(\.id)
            case .oldest:
                filteredEntryIDsCache = fallback.sorted { $0.createdAt < $1.createdAt }.map(\.id)
            }
        }
    }

    private func addEntries(_ ids: [UUID], to collection: MemoryCollection) {
        guard !ids.isEmpty else { return }
        collection.addEntries(ids)
        collection.updatedAt = .now
        try? modelContext.save()
        AudioPlaybackDiagnostics.shared.record(
            "collection add entries collection=\(collection.title) count=\(ids.count)",
            category: "storage"
        )
        if isSelectionModeEnabled {
            endSelectionMode()
        }
    }

    private func focusMap(on entry: MemoryEntry) {
        guard let coordinate = entry.coordinate else { return }
        selectedMode = .map
        selectedMapEntry = entry
        mapRegion = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.018, longitudeDelta: 0.018)
        )
    }

    private func refreshCurrentLocation() async {
        currentLocation = await locationService.currentLocation(forceRefresh: true)
    }

    private func distance(to entry: MemoryEntry) -> CLLocationDistance {
        guard let currentLocation, let coordinate = entry.coordinate else { return .greatestFiniteMagnitude }
        return CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            .distance(from: currentLocation)
    }

    private func distanceText(for entry: MemoryEntry, from currentLocation: CLLocation) -> String {
        guard let coordinate = entry.coordinate else { return "位置情報なし" }
        let distance = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            .distance(from: currentLocation)
        let formatter = MeasurementFormatter()
        formatter.unitStyle = .short
        formatter.unitOptions = .providedUnit
        if distance >= 1000 {
            return formatter.string(from: Measurement(value: distance / 1000, unit: UnitLength.kilometers))
        }
        return formatter.string(from: Measurement(value: distance.rounded(), unit: UnitLength.meters))
    }

    private func contextMenu(for entry: MemoryEntry) -> some View {
        Group {
            if !manualCollections.isEmpty {
                ForEach(manualCollections) { collection in
                    Button("「\(collection.title)」に追加") {
                        addEntries([entry.id], to: collection)
                    }
                }
            }

            Button("新しいコレクションを作成") {
                collectionDraftEntryIDs = [entry.id]
                editingCollection = nil
                showingCollectionEditor = true
            }

            if entry.coordinate != nil {
                Button("地図で開く") {
                    focusMap(on: entry)
                }
            }
        }
    }

    private func menuFilterLabel(title: String, isSelected: Bool) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? palette.accent : palette.surfaceSecondary, in: Capsule())
            .foregroundStyle(isSelected ? Color.white : palette.primaryText)
    }

    private func carouselArrow(systemImage: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white.opacity(isEnabled ? 0.95 : 0.28))
                .frame(width: 36, height: 96)
                .background(.black.opacity(isEnabled ? 0.34 : 0.18), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityHidden(visibleMapEntries.count <= 1)
    }

    @ViewBuilder
    private func timelineListEntry(for entry: MemoryEntry) -> some View {
        if isSelectionModeEnabled {
            Button {
                toggleSelection(for: entry)
            } label: {
                LibrarySelectableCard(isSelected: selectedEntryIDs.contains(entry.id), palette: palette) {
                    MemoryCardView(entry: entry)
                }
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                MemoryDetailView(entry: entry)
            } label: {
                MemoryCardView(entry: entry)
            }
            .buttonStyle(.plain)
            .contextMenu {
                contextMenu(for: entry)
            }
        }
    }

}

private struct AdvancedLibraryFilterSheet: View {
    @Binding var selectedMood: String?
    @Binding var selectedAtmosphere: AtmosphereStyle?
    @Binding var favoritesOnly: Bool
    @Binding var hasAudioOnly: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("空気感") {
                    Toggle("お気に入りのみ", isOn: $favoritesOnly)
                    Toggle("音声付きのみ", isOn: $hasAudioOnly)
                }

                Section("ムード") {
                    Button("すべて") { selectedMood = nil }
                    ForEach(MemoryMood.allCases) { mood in
                        Button(mood.localizedLabel) {
                            selectedMood = mood.rawValue
                        }
                    }
                }

                Section("時間帯") {
                    Button("すべて") { selectedAtmosphere = nil }
                    ForEach(AtmosphereStyle.allCases) { style in
                        Button(style.localizedLabel) {
                            selectedAtmosphere = style
                        }
                    }
                }
            }
            .navigationTitle("詳細フィルター")
        }
    }
}

private struct MapSelectionCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let entry: MemoryEntry

    var body: some View {
        let palette = ResonancePalette.make(for: colorScheme, atmosphere: entry.atmosphereStyle)

        HStack(spacing: 14) {
            MemoryThumbnail(entry: entry, width: 82, height: 82)

            VStack(alignment: .leading, spacing: 8) {
                Text(entry.displayTitle)
                    .font(.headline)
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)

                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)

                if let placeLabel = entry.placeLabel {
                    Text(placeLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }

                Text(entry.descriptiveCaption)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(2)

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            ResonanceBadge(title: entry.localizedMood, systemImage: "sparkles", atmosphere: entry.atmosphereStyle)
                            ResonanceBadge(title: entry.atmosphereStyle.localizedLabel, systemImage: entry.atmosphereStyle.symbolName, atmosphere: entry.atmosphereStyle)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            ResonanceBadge(title: entry.localizedMood, systemImage: "sparkles", atmosphere: entry.atmosphereStyle)
                            ResonanceBadge(title: entry.atmosphereStyle.localizedLabel, systemImage: entry.atmosphereStyle.symbolName, atmosphere: entry.atmosphereStyle)
                        }
                    }
            }

            Spacer()
        }
        .padding(16)
        .background(palette.surfacePrimary, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(palette.stroke)
        }
        .shadow(color: palette.shadow, radius: 16, y: 8)
    }
}

private struct ClusteredMapPinView: View {
    let group: MapPinGroup
    let isSelected: Bool
    let palette: ResonancePalette

    var body: some View {
        if group.count <= 1, let entry = group.representativeEntry {
            VStack(spacing: 6) {
                MemoryThumbnail(entry: entry, width: isSelected ? 56 : 48, height: isSelected ? 56 : 48)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(isSelected ? palette.accent : Color.white, lineWidth: 2)
                    }
                    .shadow(color: .black.opacity(0.28), radius: 12, y: 6)

                Image(systemName: "mappin.circle.fill")
                    .font(isSelected ? .title2 : .title3)
                    .foregroundStyle(isSelected ? palette.accent : .white)
            }
        } else {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(.black.opacity(0.78))
                    Circle()
                        .strokeBorder(isSelected ? palette.accent : Color.white.opacity(0.94), lineWidth: isSelected ? 3 : 2)

                    VStack(spacing: 2) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(isSelected ? palette.accent : .white)
                        Text("\(group.count)")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: isSelected ? 62 : 56, height: isSelected ? 62 : 56)
                .shadow(color: .black.opacity(0.28), radius: 12, y: 6)

                Image(systemName: "mappin.circle.fill")
                    .font(isSelected ? .title2 : .title3)
                    .foregroundStyle(isSelected ? palette.accent : .white)
            }
        }
    }
}

private struct LibrarySectionHeader: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let subtitle: String

    var body: some View {
        let palette = ResonancePalette.make(for: colorScheme)

        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(palette.primaryText)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
        }
    }
}

private struct TimeCapsuleCard: View {
    let entry: MemoryEntry

    var body: some View {
        MemoryGridCardView(entry: entry)
    }
}

private struct NearbyMemoryCard: View {
    let entry: MemoryEntry
    let distanceText: String
    let onOpenMap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink {
                MemoryDetailView(entry: entry)
            } label: {
                MemoryGridCardView(entry: entry)
            }
            .buttonStyle(.plain)

            Button(action: onOpenMap) {
                Label("\(distanceText)先を地図で開く", systemImage: "map.fill")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

private struct LibrarySelectableCard<Content: View>: View {
    let isSelected: Bool
    let palette: ResonancePalette
    let content: Content

    init(isSelected: Bool, palette: ResonancePalette, @ViewBuilder content: () -> Content) {
        self.isSelected = isSelected
        self.palette = palette
        self.content = content()
    }

    var body: some View {
        content
            .overlay(alignment: .topTrailing) {
                ZStack {
                    Circle()
                        .fill(isSelected ? palette.accent : palette.surfacePrimary.opacity(0.92))
                    Circle()
                        .strokeBorder(isSelected ? Color.white.opacity(0.94) : palette.stroke, lineWidth: isSelected ? 1.5 : 1)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 28, height: 28)
                .padding(12)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .strokeBorder(isSelected ? palette.accent : palette.stroke.opacity(0.55), lineWidth: isSelected ? 2.5 : 1)
            }
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
                        samples: entry.previewWaveformFingerprint,
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
                            ForEach(entry.sensorHighlights.prefix(2), id: \.self) { highlight in
                                ResonanceBadge(title: highlight, systemImage: "dot.radiowaves.left.and.right", atmosphere: entry.atmosphereStyle)
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

private struct MemoryGridCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    let entry: MemoryEntry

    var body: some View {
        let palette = ResonancePalette.make(for: colorScheme, atmosphere: entry.atmosphereStyle)

        ResonanceCard(atmosphere: entry.atmosphereStyle) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    MemoryThumbnail(entry: entry, width: nil, height: 152)

                    if entry.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.32), in: Circle())
                            .padding(10)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.displayTitle)
                        .font(.headline)
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(2)

                    Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)

                    if let placeLabel = entry.placeLabel, !placeLabel.isEmpty {
                        Text(placeLabel)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(1)
                    }

                    Text(entry.notePreview)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(2)

                    AudioWaveformView(
                        samples: entry.previewWaveformFingerprint,
                        progress: 1,
                        activeColor: palette.accent,
                        inactiveColor: palette.accent.opacity(0.18),
                        minimumBarHeight: 8
                    )
                    .frame(height: 22)

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            ResonanceBadge(title: entry.localizedMood, systemImage: "sparkles", atmosphere: entry.atmosphereStyle)
                            if entry.hasAudio {
                                ResonanceBadge(title: "\(Int(entry.audioDuration.rounded()))秒", systemImage: "waveform", atmosphere: entry.atmosphereStyle)
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            ResonanceBadge(title: entry.localizedMood, systemImage: "sparkles", atmosphere: entry.atmosphereStyle)
                            if entry.hasAudio {
                                ResonanceBadge(title: "\(Int(entry.audioDuration.rounded()))秒", systemImage: "waveform", atmosphere: entry.atmosphereStyle)
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
    var width: CGFloat? = 76
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
        .frame(maxWidth: width == nil ? .infinity : nil)
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
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? palette.accent : palette.surfaceSecondary, in: Capsule())
                .foregroundStyle(isSelected ? Color.white : palette.primaryText)
        }
        .buttonStyle(.plain)
    }
}

private extension LibraryView {
    func sectionHeader(title: String, subtitle: String) -> some View {
        LibrarySectionHeader(title: title, subtitle: subtitle)
    }
}

#Preview {
    NavigationStack {
        LibraryView()
    }
    .modelContainer(ResonancePersistence.makeContainer(inMemory: true))
}

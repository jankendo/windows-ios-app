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

struct LibraryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \MemoryEntry.createdAt, order: .reverse) private var entries: [MemoryEntry]

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

    private var palette: ResonancePalette {
        ResonancePalette.make(for: colorScheme)
    }

    private var filteredEntries: [MemoryEntry] {
        let base = entries
            .filter(matchesDateFilter)
            .filter { !favoritesOnly || $0.isFavorite }
            .filter { !hasAudioOnly || $0.hasAudio }
            .filter { selectedAtmosphere == nil || $0.atmosphereStyle == selectedAtmosphere }

        let moodFiltered = MemorySearchEngine.filter(base, query: "", mood: selectedMood)

        switch sortOption {
        case .newest:
            return moodFiltered.sorted { $0.createdAt > $1.createdAt }
        case .oldest:
            return moodFiltered.sorted { $0.createdAt < $1.createdAt }
        }
    }

    private var mapEntries: [MemoryEntry] {
        filteredEntries.filter {
            guard let coordinate = $0.coordinate else { return false }
            return CLLocationCoordinate2DIsValid(coordinate)
                && coordinate.latitude.isFinite
                && coordinate.longitude.isFinite
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

            if selectedMode == .map {
                mapExperience
            } else {
                timelineExperience
            }
        }
        .navigationTitle("ライブラリ")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingFilterSheet) {
            AdvancedLibraryFilterSheet(
                selectedMood: $selectedMood,
                selectedAtmosphere: $selectedAtmosphere,
                favoritesOnly: $favoritesOnly,
                hasAudioOnly: $hasAudioOnly
            )
            .presentationDetents([.medium])
        }
        .onAppear {
            syncMapSelection()
        }
        .onChange(of: entries.count) { _, _ in syncMapSelection() }
        .onChange(of: selectedDateFilter) { _, _ in syncMapSelection() }
        .onChange(of: selectedMood) { _, _ in syncMapSelection() }
        .onChange(of: selectedAtmosphere) { _, _ in syncMapSelection() }
        .onChange(of: favoritesOnly) { _, _ in syncMapSelection() }
        .onChange(of: hasAudioOnly) { _, _ in syncMapSelection() }
        .onChange(of: sortOption) { _, _ in syncMapSelection() }
    }

    private var timelineExperience: some View {
        ScrollView {
            VStack(spacing: 18) {
                summaryCard
                modePicker
                filterBar

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
                Map(coordinateRegion: $mapRegion, annotationItems: mapEntries) { entry in
                    MapAnnotation(coordinate: entry.coordinate ?? mapRegion.center) {
                        Button {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                                selectedMapEntry = entry
                            }
                        } label: {
                            VStack(spacing: 6) {
                                MemoryThumbnail(entry: entry, width: selectedMapEntry?.id == entry.id ? 56 : 48, height: selectedMapEntry?.id == entry.id ? 56 : 48)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .strokeBorder(selectedMapEntry?.id == entry.id ? palette.accent : Color.white, lineWidth: 2)
                                    }
                                    .shadow(color: .black.opacity(0.28), radius: 12, y: 6)

                                Image(systemName: "mappin.circle.fill")
                                    .font(selectedMapEntry?.id == entry.id ? .title2 : .title3)
                                    .foregroundStyle(selectedMapEntry?.id == entry.id ? palette.accent : .white)
                            }
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
                    ResonanceStatTile(title: "地図対応", value: "\(entries.filter(\.hasMapLocation).count)", symbol: "map.fill")
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
                Text("地図の中で、その場の空気を探す")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
                Spacer()
                Text("\(mapEntries.count) memories")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.68))
            }
            .padding(.horizontal, 4)

            if let selectedMapEntry {
                NavigationLink {
                    MemoryDetailView(entry: selectedMapEntry)
                } label: {
                    MapSelectionCard(entry: selectedMapEntry)
                }
                .buttonStyle(.plain)
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

    private func matchesDateFilter(_ entry: MemoryEntry) -> Bool {
        let calendar = Calendar.current

        switch selectedDateFilter {
        case .all:
            return true
        case .today:
            return calendar.isDateInToday(entry.createdAt)
        case .week:
            return calendar.isDate(entry.createdAt, equalTo: .now, toGranularity: .weekOfYear)
        case .month:
            return calendar.isDate(entry.createdAt, equalTo: .now, toGranularity: .month)
        case .year:
            return calendar.isDate(entry.createdAt, equalTo: .now, toGranularity: .year)
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
        if let selectedMapEntry, !mapEntries.contains(where: { $0.id == selectedMapEntry.id }) {
            self.selectedMapEntry = mapEntries.first
        } else if selectedMapEntry == nil {
            selectedMapEntry = mapEntries.first
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

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        ResonanceBadge(title: entry.localizedMood, systemImage: "sparkles", atmosphere: entry.atmosphereStyle)
                        ResonanceBadge(title: entry.atmosphereStyle.localizedLabel, systemImage: entry.atmosphereStyle.symbolName, atmosphere: entry.atmosphereStyle)
                        if let weatherSummary = entry.weatherSnapshot?.compactSummary, !weatherSummary.isEmpty {
                            ResonanceBadge(title: weatherSummary, systemImage: entry.weatherSnapshot?.symbolName ?? "cloud.sun.fill", atmosphere: entry.atmosphereStyle)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ResonanceBadge(title: entry.localizedMood, systemImage: "sparkles", atmosphere: entry.atmosphereStyle)
                        ResonanceBadge(title: entry.atmosphereStyle.localizedLabel, systemImage: entry.atmosphereStyle.symbolName, atmosphere: entry.atmosphereStyle)
                        if let weatherSummary = entry.weatherSnapshot?.compactSummary, !weatherSummary.isEmpty {
                            ResonanceBadge(title: weatherSummary, systemImage: entry.weatherSnapshot?.symbolName ?? "cloud.sun.fill", atmosphere: entry.atmosphereStyle)
                        }
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

#Preview {
    NavigationStack {
        LibraryView()
    }
    .modelContainer(for: [MemoryEntry.self], inMemory: true)
}

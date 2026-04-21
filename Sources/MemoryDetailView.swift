import SwiftData
import SwiftUI
import UIKit

struct MemoryDetailView: View {
    @Bindable var entry: MemoryEntry
    @Query(sort: \MemoryEntry.createdAt, order: .reverse) private var allEntries: [MemoryEntry]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var player = AudioPlayerController()
    @State private var waveformSamples: [CGFloat] = Array(repeating: 0.25, count: 40)
    @State private var showingEditor = false
    @State private var showingDeleteConfirmation = false
    @State private var showingShareSheet = false
    @State private var showingAutoTags = false
    @State private var showingImmersivePreview = false

    private var palette: ResonancePalette {
        ResonancePalette.make(for: colorScheme, atmosphere: entry.atmosphereStyle)
    }

    private var shareItems: [Any] {
        var items: [Any] = [entry.shareSummary, entry.photoURL]
        if let audioURL = entry.audioURL {
            items.append(audioURL)
        }
        return items
    }

    private var relatedEntries: [MemoryEntry] {
        allEntries
            .filter { $0.id != entry.id }
            .map { candidate in
                let sharedTags = Set(candidate.autoTags).intersection(entry.autoTags).count
                let moodScore = candidate.mood == entry.mood ? 2 : 0
                let placeScore = candidate.placeLabel == entry.placeLabel && entry.placeLabel != nil ? 2 : 0
                return (candidate, sharedTags + moodScore + placeScore)
            }
            .filter { $0.1 > 0 }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.createdAt > rhs.0.createdAt
                }
                return lhs.1 > rhs.1
            }
            .map(\.0)
            .prefix(3)
            .map { $0 }
    }

    var body: some View {
        ZStack {
            ResonanceGradientBackground(atmosphere: entry.atmosphereStyle)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heroScene

                    if !entry.notes.isEmpty {
                        ResonanceCard(atmosphere: entry.atmosphereStyle) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("メモ")
                                    .font(.headline)
                                    .foregroundStyle(palette.primaryText)
                                Text(entry.notes)
                                    .font(.body)
                                    .foregroundStyle(palette.primaryText)
                            }
                        }
                    }

                    if entry.sensorSnapshot != nil || entry.minimumDecibels != nil || entry.maximumDecibels != nil || entry.weatherSnapshot != nil {
                        ResonanceCard(atmosphere: entry.atmosphereStyle) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("空間センサー")
                                    .font(.headline)
                                    .foregroundStyle(palette.primaryText)

                                SensorDetailRow(title: "場所", value: entry.placeLabel ?? "取得なし")
                                SensorDetailRow(title: "天気", value: entry.weatherSnapshot?.compactSummary ?? "取得なし")

                                if let sensorSnapshot = entry.sensorSnapshot,
                                   let latitude = sensorSnapshot.latitude,
                                   let longitude = sensorSnapshot.longitude {
                                    SensorDetailRow(title: "座標", value: String(format: "%.6f, %.6f", latitude, longitude))
                                }
                                if let horizontalAccuracy = entry.sensorSnapshot?.horizontalAccuracy {
                                    SensorDetailRow(title: "水平精度", value: String(format: "±%.1f m", horizontalAccuracy))
                                }
                                if let altitude = entry.sensorSnapshot?.altitude {
                                    SensorDetailRow(title: "標高", value: String(format: "%.0f m", altitude))
                                }
                                if let pressure = entry.sensorSnapshot?.pressureKilopascals {
                                    SensorDetailRow(title: "気圧", value: String(format: "%.1f kPa", pressure))
                                }
                                if let minimumDecibels = entry.minimumDecibels, let maximumDecibels = entry.maximumDecibels {
                                    SensorDetailRow(title: "音量", value: String(format: "最小 %.1f dB / 最大 %.1f dB", minimumDecibels, maximumDecibels))
                                }
                                if let heading = entry.sensorSnapshot?.heading {
                                    SensorDetailRow(title: "方角", value: String(format: "%.0f°", heading))
                                }
                                if let orientation = entry.sensorSnapshot?.deviceOrientationLabel {
                                    SensorDetailRow(title: "端末向き", value: orientation)
                                }
                            }
                        }
                    }

                    if !entry.transcript.isEmpty {
                        ResonanceCard(atmosphere: entry.atmosphereStyle) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("文字起こし")
                                    .font(.headline)
                                    .foregroundStyle(palette.primaryText)
                                Text(entry.transcript)
                                    .foregroundStyle(palette.secondaryText)
                            }
                        }
                    }

                    ResonanceCard(atmosphere: entry.atmosphereStyle) {
                        DisclosureGroup(isExpanded: $showingAutoTags) {
                            VStack(alignment: .leading, spacing: 12) {
                                if entry.autoTags.isEmpty {
                                    Text("まだ自動タグはありません。")
                                        .font(.subheadline)
                                        .foregroundStyle(palette.secondaryText)
                                } else {
                                    FlexibleTagCloud(tags: entry.autoTags, atmosphere: entry.atmosphereStyle)
                                }
                            }
                            .padding(.top, 12)
                        } label: {
                            Label("自動タグ", systemImage: "tag")
                                .font(.headline)
                                .foregroundStyle(palette.primaryText)
                        }
                    }

                    if !relatedEntries.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("関連する記録")
                                .font(.headline)
                                .foregroundStyle(palette.primaryText)

                            ForEach(relatedEntries) { related in
                                NavigationLink {
                                    MemoryDetailView(entry: related)
                                } label: {
                                    MemoryCardView(entry: related)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("記録")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showingShareSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }

                Menu {
                    Button("編集") {
                        showingEditor = true
                    }

                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("削除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            MemoryEditView(entry: entry)
        }
        .sheet(isPresented: $showingShareSheet) {
            ShareSheet(items: shareItems)
        }
        .fullScreenCover(isPresented: $showingImmersivePreview) {
            SavedMemoryImmersivePreviewView(entry: entry)
        }
        .alert("この記録を削除しますか？", isPresented: $showingDeleteConfirmation) {
            Button("削除", role: .destructive) {
                deleteEntry()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("写真、音声、メモ情報がこの端末から削除されます。")
        }
        .onAppear {
            waveformSamples = entry.waveformFingerprint
            if let audioURL = entry.audioURL {
                player.load(url: audioURL)
            }
        }
        .onDisappear {
            player.stop()
        }
    }

    private var heroScene: some View {
        ZStack(alignment: .bottomLeading) {
            MemoryHeroImage(entry: entry)
                .overlay {
                    ResonanceHeroScrim(atmosphere: entry.atmosphereStyle)
                        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                }

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.displayTitle)
                            .font(.largeTitle.bold())
                            .foregroundStyle(.white)

                        Text(entry.atmosphereStyle.poeticLine)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.84))
                    }

                    Spacer()

                    Button {
                        entry.isFavorite.toggle()
                        try? modelContext.save()
                    } label: {
                        Image(systemName: entry.isFavorite ? "heart.fill" : "heart")
                            .font(.title3)
                            .foregroundStyle(entry.isFavorite ? .pink : .white.opacity(0.88))
                    }
                    .buttonStyle(.plain)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ResonanceBadge(title: entry.localizedMood, systemImage: "sparkles", tint: .white, atmosphere: entry.atmosphereStyle)
                        ResonanceBadge(title: entry.atmosphereStyle.localizedLabel, systemImage: entry.atmosphereStyle.symbolName, tint: .white, atmosphere: entry.atmosphereStyle)
                        if let placeLabel = entry.placeLabel {
                            ResonanceBadge(title: placeLabel, systemImage: "location.fill", tint: .white, atmosphere: entry.atmosphereStyle)
                        }
                        if entry.hasAudio {
                            ResonanceBadge(title: "\(Int(entry.audioDuration.rounded()))秒", systemImage: "waveform", tint: .white, atmosphere: entry.atmosphereStyle)
                        }
                        if let weatherSummary = entry.weatherSnapshot?.compactSummary, !weatherSummary.isEmpty {
                            ResonanceBadge(title: weatherSummary, systemImage: entry.weatherSnapshot?.symbolName ?? "cloud.sun.fill", tint: .white, atmosphere: entry.atmosphereStyle)
                        }
                    }
                }

                if let audioURL = entry.audioURL {
                    ResonanceCard(atmosphere: entry.atmosphereStyle) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Label("空気の再生", systemImage: "waveform")
                                    .font(.headline)
                                    .foregroundStyle(palette.primaryText)
                                Spacer()
                                Button {
                                    player.togglePlayback(for: audioURL)
                                } label: {
                                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                        .font(.system(size: 34))
                                        .foregroundStyle(palette.accent)
                                }
                                .buttonStyle(.plain)
                            }

                            AudioWaveformView(
                                samples: waveformSamples,
                                progress: player.duration > 0 ? player.currentTime / player.duration : 0,
                                activeColor: palette.accent,
                                inactiveColor: Color.white.opacity(colorScheme == .dark ? 0.2 : 0.26),
                                minimumBarHeight: 10
                            )

                            Slider(
                                value: Binding(
                                    get: { player.currentTime },
                                    set: { player.seek(to: $0) }
                                ),
                                in: 0...max(max(player.duration, entry.audioDuration), 1)
                            )
                            .tint(palette.accent)

                            HStack {
                                Text(player.currentTime.resonanceClockText)
                                    .font(.caption)
                                    .foregroundStyle(palette.secondaryText)
                                Spacer()
                                Text(entry.createdAt.formatted(date: .complete, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(palette.secondaryText)
                            }

                            Button {
                                showingImmersivePreview = true
                            } label: {
                                Label("写真と録音を全画面でプレビュー", systemImage: "arrow.up.left.and.arrow.down.right")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(palette.accent)
                        }
                    }
                }
            }
            .padding(22)
        }
    }

    private func deleteEntry() {
        MediaStore.deleteAssets(for: entry)
        modelContext.delete(entry)
        try? modelContext.save()
        dismiss()
    }
}

private struct SensorDetailRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
        }
        .font(.subheadline)
    }
}

private struct MemoryHeroImage: View {
    let entry: MemoryEntry

    var body: some View {
        Group {
            if let image = UIImage(contentsOfFile: entry.photoURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 32)
                    .fill(.gray.opacity(0.15))
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 460)
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
    }
}

private struct SavedMemoryImmersivePreviewView: View {
    let entry: MemoryEntry

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var environmentService = CaptureLocationService.shared
    @StateObject private var player = AudioPlayerController()
    @State private var controlsVisible = true
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image = UIImage(contentsOfFile: entry.photoURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(1.12)
                    .offset(
                        x: dragOffset.width * 0.22 + environmentService.previewHorizontalShift,
                        y: dragOffset.height * 0.12 + environmentService.previewVerticalShift
                    )
                    .rotation3DEffect(.degrees(Double(-environmentService.previewHorizontalShift) * 0.18), axis: (x: 0, y: 1, z: 0))
                    .rotation3DEffect(.degrees(Double(environmentService.previewVerticalShift) * 0.12), axis: (x: 1, y: 0, z: 0))
                    .ignoresSafeArea()
            }

            LinearGradient(
                colors: [Color.black.opacity(0.18), .clear, Color.black.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .safeAreaInset(edge: .top) {
            if controlsVisible {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    if entry.hasAudio {
                        ResonanceBadge(
                            title: "ループ再生中",
                            systemImage: "waveform",
                            tint: .white,
                            atmosphere: entry.atmosphereStyle
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if controlsVisible {
                VStack(alignment: .leading, spacing: 14) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .bottom, spacing: 16) {
                            previewTexts
                            previewPlayButton
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            previewTexts

                            HStack {
                                Spacer()
                                previewPlayButton
                            }
                        }
                    }

                    HStack {
                        Text(entry.createdAt.formatted(date: .complete, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.82))

                        Spacer(minLength: 12)

                        Text("傾きとドラッグで奥行きが動きます")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.74))
                            .multilineTextAlignment(.trailing)
                    }
                }
                .padding(20)
                .background(.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.22)) {
                controlsVisible.toggle()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    dragOffset = value.translation
                    player.setPan(Float(value.translation.width / 180))
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        dragOffset = .zero
                    }
                    player.setPan(0)
                }
        )
        .onAppear {
            if let audioURL = entry.audioURL {
                player.load(url: audioURL, autoPlay: true, loop: true, volume: 0.78)
            }
        }
        .onDisappear {
            player.stop()
        }
    }

    @ViewBuilder
    private var previewPlayButton: some View {
        if let audioURL = entry.audioURL {
            Button {
                player.togglePlayback(for: audioURL)
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }

    private var previewTexts: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Immersive Memory")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))

            Text(entry.displayTitle)
                .font(.title3.bold())
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text("視差効果で写真が揺れ、録音はループ再生されます")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct FlexibleTagCloud: View {
    @Environment(\.colorScheme) private var colorScheme
    let tags: [String]
    let atmosphere: AtmosphereStyle

    var body: some View {
        let palette = ResonancePalette.make(for: colorScheme, atmosphere: atmosphere)

        VStack(alignment: .leading, spacing: 8) {
            ForEach(chunkedTags, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { tag in
                        Text(tag)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(palette.accentSoft, in: Capsule())
                            .foregroundStyle(palette.primaryText)
                    }
                }
            }
        }
    }

    private var chunkedTags: [[String]] {
        stride(from: 0, to: tags.count, by: 3).map { start in
            Array(tags[start..<min(start + 3, tags.count)])
        }
    }
}

private struct MemoryEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var entry: MemoryEntry

    var body: some View {
        NavigationStack {
            Form {
                TextField("タイトル", text: $entry.title)
                TextField("メモ", text: $entry.notes, axis: .vertical)
                    .lineLimit(4...8)
            }
            .navigationTitle("記録を編集")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        try? modelContext.save()
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        MemoryDetailView(
            entry: MemoryEntry(
                title: "Evening Walk",
                notes: "Wind, street lights, and a soft jazz leak from the cafe.",
                photoFileName: "",
                audioFileName: nil,
                audioDuration: 0,
                visualTags: ["street", "night"],
                audioTags: ["music", "traffic"],
                transcript: "Nice to meet you",
                mood: MemoryMood.urban.rawValue
            )
        )
    }
    .modelContainer(for: [MemoryEntry.self], inMemory: true)
}

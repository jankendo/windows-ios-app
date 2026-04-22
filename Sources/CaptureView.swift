import CoreLocation
import SwiftData
import SwiftUI
import UIKit

@MainActor
final class CaptureFlowModel: ObservableObject {
    @Published var title = ""
    @Published var notes = ""
    @Published var isSaving = false
    @Published var isPreparingReview = false
    @Published var capturedDraft: CapturedMemoryDraft?
    @Published var lastSavedEntry: MemoryEntry?
    @Published var errorMessage: String?
    @Published var saveMessage: String?
    @Published var isGeneratingAICaption = false
    @Published var captionGenerationMessage: String?

    let camera = CameraCaptureService()
    private let locationService = CaptureLocationService.shared
    private let weatherService = AmbientWeatherCaptureService.shared
    private var captionRefreshTask: Task<Void, Never>?

    func prepare() {
        camera.prepare()
        locationService.prepare()
        Task {
            await MemoryAnalysisService.requestSpeechAuthorizationIfNeeded()
        }
    }

    func capture(duration: TimeInterval, delayRecordingUntilAfterShutter: Bool) {
        guard !isSaving else { return }
        errorMessage = nil
        saveMessage = nil
        lastSavedEntry = nil
        isPreparingReview = false
        captionGenerationMessage = nil

        camera.captureMemory(duration: duration, delayRecordingUntilAfterShutter: delayRecordingUntilAfterShutter) { [weak self] result in
            guard let self else { return }

            Task { @MainActor in
                do {
                    var draft = try result.get()
                    async let placeLabel = self.locationService.currentPlaceLabel(forceRefresh: true)
                    async let photoCaption = MemoryAnalysisService.captionGeneration(from: draft.photoData)
                    async let sensorSnapshot = self.locationService.currentEnvironmentSnapshot(forceRefresh: true)
                    async let resolvedLocation = self.locationService.currentLocation(forceRefresh: true)
                    let captionGeneration = await photoCaption
                    draft.placeLabel = await placeLabel
                    draft.photoCaption = captionGeneration?.text
                    draft.photoCaptionSource = captionGeneration?.source
                    draft.sensorSnapshot = await sensorSnapshot
                    let weatherLocation =
                        await resolvedLocation
                        ?? draft.sensorSnapshot?.coordinate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
                    if let location = weatherLocation {
                        draft.weatherSnapshot = await self.weatherService.currentWeatherSnapshot(for: location)
                    }
                    self.isPreparingReview = false
                    self.capturedDraft = draft
                    self.scheduleDraftCaptionRefresh()
                } catch {
                    self.isPreparingReview = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }

        if camera.isCapturing {
            isPreparingReview = true
        }
    }

    func saveDraft(using modelContext: ModelContext) {
        guard let draft = capturedDraft, !isSaving else { return }
        errorMessage = nil
        saveMessage = nil
        isSaving = true
        cancelDraftCaptionRefresh()

        let currentTitle = title
        let currentNotes = notes

        Task { @MainActor in
            do {
                let storedMedia = try MediaStore.save(photoData: draft.photoData, audioTempURL: draft.audioTempURL)
                let storedAudioURL = storedMedia.audioFileName.map(MediaStore.audioURL(for:))
                let analysis = await MemoryAnalysisService.analyze(photoData: draft.photoData, audioURL: storedAudioURL)
                let captionGeneration = await MemoryAnalysisService.captionGeneration(
                    from: draft.photoData,
                    title: currentTitle,
                    placeLabel: draft.placeLabel
                )
                let hasVerifiedFoundationCaption =
                    draft.photoCaptionSource == .foundationModels
                    && !(draft.photoCaption?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                let shouldPreserveVerifiedFoundationCaption =
                    hasVerifiedFoundationCaption && captionGeneration?.source != .foundationModels
                let resolvedPhotoCaption =
                    shouldPreserveVerifiedFoundationCaption
                    ? draft.photoCaption
                    : (captionGeneration?.text ?? draft.photoCaption)
                let resolvedPhotoCaptionSource =
                    shouldPreserveVerifiedFoundationCaption
                    ? draft.photoCaptionSource
                    : (captionGeneration?.source ?? draft.photoCaptionSource)

                let entry = MemoryEntry(
                    createdAt: draft.capturedAt,
                    title: currentTitle,
                    notes: currentNotes,
                    photoFileName: storedMedia.photoFileName,
                    audioFileName: storedMedia.audioFileName,
                    audioDuration: storedMedia.audioDuration,
                    visualTags: analysis.visualTags,
                    audioTags: analysis.audioTags,
                    transcript: analysis.transcript,
                    mood: analysis.mood
                )

                let metadata = MemoryAtmosphereMetadata(
                    placeLabel: draft.placeLabel,
                    waveformFingerprint: WaveformExtractor.samples(from: storedAudioURL, sampleCount: 28).map { Double($0) },
                    photoCaption: resolvedPhotoCaption,
                    atmosphereStyle: draft.atmosphereStyle,
                    captureDuration: draft.audioDuration,
                    sensorSnapshot: draft.sensorSnapshot,
                    weatherSnapshot: draft.weatherSnapshot,
                    minimumDecibels: draft.minimumDecibels,
                    maximumDecibels: draft.maximumDecibels
                )
                var finalMetadata = metadata
                finalMetadata.photoCaptionSourceRaw =
                    (resolvedPhotoCaption?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                    ? resolvedPhotoCaptionSource?.rawValue
                    : nil

                try MediaStore.saveAtmosphereMetadata(finalMetadata, for: entry.id)
                modelContext.insert(entry)
                try modelContext.save()

                title = ""
                notes = ""
                capturedDraft = nil
                lastSavedEntry = entry
                saveMessage = draft.placeLabel.map { "\($0)の空気を保存しました。" } ?? "記録を保存しました。"
            } catch {
                errorMessage = error.localizedDescription
            }

            isSaving = false
        }
    }

    func discardDraft() {
        cancelDraftCaptionRefresh()
        if let audioURL = capturedDraft?.audioTempURL {
            try? FileManager.default.removeItem(at: audioURL)
        }
        capturedDraft = nil
    }

    func resetSuccessState() {
        lastSavedEntry = nil
        saveMessage = nil
    }

    func scheduleDraftCaptionRefresh() {
        guard let draft = capturedDraft else { return }

        let currentTitle = title
        let currentPlaceLabel = draft.placeLabel
        let draftID = draft.id
        let photoData = draft.photoData
        captionGenerationMessage = nil

        captionRefreshTask?.cancel()
        captionRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            let refreshedCaption = await MemoryAnalysisService.captionGeneration(
                from: photoData,
                title: currentTitle,
                placeLabel: currentPlaceLabel
            )
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self, var currentDraft = self.capturedDraft, currentDraft.id == draftID else { return }
                currentDraft.photoCaption = refreshedCaption?.text ?? currentDraft.photoCaption
                currentDraft.photoCaptionSource = refreshedCaption?.source ?? currentDraft.photoCaptionSource
                self.capturedDraft = currentDraft
            }
        }
    }

    func cancelDraftCaptionRefresh() {
        captionRefreshTask?.cancel()
        captionRefreshTask = nil
    }

    func regenerateAICaption() {
        guard let draft = capturedDraft else { return }

        let currentTitle = title
        let currentPlaceLabel = draft.placeLabel
        let draftID = draft.id
        let photoData = draft.photoData

        isGeneratingAICaption = true
        captionGenerationMessage = nil
        cancelDraftCaptionRefresh()

        Task { [weak self] in
            defer {
                Task { @MainActor in
                    self?.isGeneratingAICaption = false
                }
            }

            do {
                let generation = try await MemoryAnalysisService.forceFoundationModelsCaption(
                    from: photoData,
                    title: currentTitle,
                    placeLabel: currentPlaceLabel
                )
                await MainActor.run {
                    guard let self, var currentDraft = self.capturedDraft, currentDraft.id == draftID else { return }
                    currentDraft.photoCaption = generation.text
                    currentDraft.photoCaptionSource = generation.source
                    self.capturedDraft = currentDraft
                    self.captionGenerationMessage = "Apple Intelligence で内容を再作成しました。"
                }
            } catch {
                await MainActor.run {
                    self?.captionGenerationMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }
}

struct CaptureView: View {
    let isActive: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \MemoryEntry.createdAt, order: .reverse) private var entries: [MemoryEntry]
    @ObservedObject private var environmentService = CaptureLocationService.shared
    @AppStorage("captureDurationSeconds") private var captureDurationSeconds = 6.0
    @AppStorage("delayRecordingUntilAfterShutter") private var delayRecordingUntilAfterShutter = true
    @StateObject private var model = CaptureFlowModel()
    @State private var showingCaptureSettings = false
    @State private var hasCompletedInitialStartup = false

    private var atmosphere: AtmosphereStyle {
        model.capturedDraft?.atmosphereStyle ?? AtmosphereStyle(date: .now)
    }

    private var palette: ResonancePalette {
        ResonancePalette.make(for: colorScheme, atmosphere: atmosphere)
    }

    private var recentEntry: MemoryEntry? {
        entries.first
    }

    private var todayCount: Int {
        let calendar = Calendar.current
        return entries.filter { calendar.isDateInToday($0.createdAt) }.count
    }

    private var needsStartupOverlay: Bool {
        !hasCompletedInitialStartup
            && model.camera.permissionState != .denied
            && (model.camera.permissionState == .unknown || !model.camera.isSessionRunning || model.camera.isPreparingSession)
    }

    private var needsProcessingOverlay: Bool {
        !model.camera.isCapturing && (model.camera.isProcessingCapture || model.isPreparingReview)
    }

    var body: some View {
        ZStack {
            cameraSurface

            ResonanceHeroScrim(atmosphere: atmosphere)
                .ignoresSafeArea()

            if model.camera.permissionState == .denied {
                permissionCenterOverlay
            }

            if needsStartupOverlay {
                startupOverlay
                    .transition(.opacity)
            }

            if needsProcessingOverlay {
                reviewProcessingOverlay
                    .transition(.opacity)
            }
        }
        .safeAreaInset(edge: .top) {
            topChrome
        }
        .safeAreaInset(edge: .bottom) {
            bottomChrome
        }
        .toolbar(.hidden, for: .navigationBar)
        .animation(.easeInOut(duration: 0.25), value: needsStartupOverlay)
        .onAppear {
            if isActive {
                model.prepare()
            }
        }
        .onChange(of: isActive) { _, active in
            if active {
                model.prepare()
            } else {
                model.camera.suspend()
            }
        }
        .onChange(of: model.camera.isSessionRunning) { _, isRunning in
            if isRunning {
                hasCompletedInitialStartup = true
            }
        }
        .onChange(of: model.camera.permissionState) { _, state in
            if state == .denied {
                hasCompletedInitialStartup = true
            }
        }
        .onDisappear {
            model.cancelDraftCaptionRefresh()
            model.camera.suspend()
        }
        .onChange(of: model.title) { _, _ in
            model.scheduleDraftCaptionRefresh()
        }
        .onChange(of: model.capturedDraft?.id) { _, _ in
            model.scheduleDraftCaptionRefresh()
        }
        .fullScreenCover(item: $model.capturedDraft) { draft in
            MemorySceneReviewView(
                draft: draft,
                title: $model.title,
                notes: $model.notes,
                isSaving: model.isSaving,
                isRegeneratingCaption: model.isGeneratingAICaption,
                captionGenerationMessage: model.captionGenerationMessage,
                onRetake: {
                    model.discardDraft()
                },
                onRegenerateCaption: {
                    model.regenerateAICaption()
                },
                onSave: {
                    model.saveDraft(using: modelContext)
                }
            )
        }
        .sheet(isPresented: $showingCaptureSettings) {
            captureSettingsSheet
                .presentationDetents([.height(320)])
                .presentationDragIndicator(.visible)
        }
    }

    private var cameraSurface: some View {
        Group {
            if model.camera.permissionState == .ready {
                CameraPreviewView(session: model.camera.session)
                    .ignoresSafeArea()
            } else {
                ZStack {
                    ResonanceGradientBackground(atmosphere: atmosphere)
                    Color.black.opacity(colorScheme == .dark ? 0.45 : 0.2)
                        .ignoresSafeArea()
                }
            }
        }
    }

    private var topChrome: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Resonance")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)

                    Text("写真ではなく、その場の空気まで連れて帰る")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.78))
                }

                Spacer()

                Button {
                    showingCaptureSettings = true
                } label: {
                    ResonanceBadge(
                        title: "Ambient \(Int(captureDurationSeconds.rounded()))s",
                        systemImage: "slider.horizontal.3",
                        tint: .white,
                        atmosphere: atmosphere
                    )
                }
                .buttonStyle(.plain)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ResonanceBadge(
                        title: atmosphere.localizedLabel,
                        systemImage: atmosphere.symbolName,
                        tint: .white,
                        atmosphere: atmosphere
                    )

                    if let placeLabel = recentEntry?.placeLabel, !placeLabel.isEmpty {
                        ResonanceBadge(
                            title: placeLabel,
                            systemImage: "location.fill",
                            tint: .white,
                            atmosphere: atmosphere
                        )
                    }

                    if let weatherSummary = recentEntry?.weatherSnapshot?.compactSummary, !weatherSummary.isEmpty {
                        ResonanceBadge(
                            title: weatherSummary,
                            systemImage: recentEntry?.weatherSnapshot?.symbolName ?? "cloud.sun.fill",
                            tint: .white,
                            atmosphere: atmosphere
                        )
                    }
                }
            }

            HStack {
                Text(model.camera.statusText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.84))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.44), in: Capsule())

                Spacer()

                Text("今日 \(todayCount)件")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.84))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.44), in: Capsule())
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.38), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var bottomChrome: some View {
        VStack(spacing: 14) {
            if let errorMessage = model.errorMessage {
                StatusMessageView(symbol: "exclamationmark.triangle.fill", text: errorMessage, tint: .red, atmosphere: atmosphere)
            }

            if let saveMessage = model.saveMessage {
                compactSuccessToast(message: saveMessage)
            }

            if model.camera.permissionState == .denied {
                permissionBottomCard
            } else {
                captureInfoPill
                captureControlsBar
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.28), .black.opacity(0.52)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var captureInfoPill: some View {
        Group {
            if model.camera.isCapturing || model.camera.isProcessingCapture {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label(model.camera.isCapturing ? "Capturing the air" : "Composing your memory", systemImage: model.camera.isCapturing ? "waveform.and.mic" : "sparkles")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .symbolEffect(.pulse, options: .repeating, isActive: model.camera.isCapturing || model.camera.isProcessingCapture)
                        Spacer()
                        if model.camera.isWaitingForRecordingStart {
                            Text("静音待ち")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white.opacity(0.82))
                        } else if model.camera.isCapturing {
                            Text("\(model.camera.remainingRecordingSeconds)秒")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(palette.accent)
                                .contentTransition(.numericText())
                        } else {
                            Text("整え中")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white.opacity(0.82))
                        }
                    }

                    Text(
                        model.camera.isWaitingForRecordingStart
                        ? "シャッター音が録音に混ざらないよう、静かな立ち上がりを待っています。"
                        : (model.camera.isCapturing
                            ? "シャッターのあとも、その場の空気を静かに集めています。"
                            : "写真と音、場所と空気をひとつのシーンとしてまとめています。")
                    )
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.82))

                    AudioWaveformView(
                        samples: model.camera.liveMeterSamples,
                        progress: model.camera.isCapturing ? model.camera.captureProgress : 1,
                        activeColor: palette.accent,
                        inactiveColor: Color.white.opacity(0.18),
                        minimumBarHeight: 10
                    )
                    .frame(height: 42)

                    if model.camera.isCapturing {
                        ProgressView(value: model.camera.captureProgress)
                            .tint(palette.accent)
                    }
                }
                .padding(16)
                .background(.black.opacity(0.56), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(.white.opacity(0.18))
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.white)
                    Text(
                        delayRecordingUntilAfterShutter
                        ? "シャッター後の静けさから\(Int(captureDurationSeconds.rounded()))秒間の空気を記録します"
                        : "シャッターと同時に\(Int(captureDurationSeconds.rounded()))秒間の空気を記録します"
                    )
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.black.opacity(0.5), in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(.white.opacity(0.18))
                }
            }
        }
    }

    private var captureControlsBar: some View {
        HStack(alignment: .center) {
            recentPeek

            Spacer()

            CameraShutterButton(
                isEnabled: model.camera.isReadyToCapture && !model.isSaving && !model.camera.isCapturing,
                isRecording: model.camera.isCapturing || model.camera.isProcessingCapture,
                progress: model.camera.captureProgress,
                accent: palette.accent
            ) {
                model.capture(
                    duration: captureDurationSeconds,
                    delayRecordingUntilAfterShutter: delayRecordingUntilAfterShutter
                )
            }

            Spacer()

            captureModeIndicator
        }
        .padding(.horizontal, 8)
    }

    private var recentPeek: some View {
        Group {
            if let recentEntry {
                NavigationLink {
                    MemoryDetailView(entry: recentEntry)
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        MemoryThumbnail(entry: recentEntry, width: 58, height: 58)

                        Image(systemName: "arrow.up.right.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .shadow(radius: 6)
                    }
                }
                .buttonStyle(.plain)
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(0.12))
                    .frame(width: 58, height: 58)
                    .overlay {
                        Image(systemName: "photo.on.rectangle")
                            .foregroundStyle(.white.opacity(0.78))
                    }
            }
        }
        .frame(width: 72, alignment: .leading)
    }

    private var captureModeIndicator: some View {
        Button {
            showingCaptureSettings = true
        } label: {
            VStack(spacing: 6) {
            Text("AMBIENT")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.7))
            Text("\(Int(captureDurationSeconds.rounded()))s")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
            Text(delayRecordingUntilAfterShutter ? "quiet" : "instant")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
            }
            .frame(width: 72)
            .padding(.vertical, 10)
            .background(.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.18))
            }
        }
        .buttonStyle(.plain)
    }

    private var permissionCenterOverlay: some View {
        VStack(spacing: 14) {
            permissionPlaceholder
            OpenSettingsButton()
        }
        .padding(24)
    }

    private var permissionBottomCard: some View {
        ResonanceCard(atmosphere: atmosphere) {
            VStack(alignment: .leading, spacing: 12) {
                Text("カメラとマイクを許可すると、撮影画面として使えます。")
                    .font(.headline)
                    .foregroundStyle(palette.primaryText)

                Text("写真と音を一緒に残すため、設定からアクセスを有効にしてください。")
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryText)

                OpenSettingsButton()
            }
        }
    }

    private func compactSuccessToast(message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                if let lastSavedEntry = model.lastSavedEntry {
                    NavigationLink {
                        MemoryDetailView(entry: lastSavedEntry)
                    } label: {
                        Text("今すぐ確認")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                }
            }

            Spacer()

            Button("閉じる") {
                model.resetSuccessState()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.82))
        }
        .padding(14)
        .background(.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.14))
        }
    }

    private var permissionPlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.92))
            Text("カメラとマイクへのアクセスが必要です")
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text("許可すると、写真と環境音、そしてその場の空気感をひとつの記録として残せます。")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.78))
                .padding(.horizontal)
        }
        .padding(24)
        .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.12))
        }
    }

    private var startupOverlay: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.15)

                Text("Preparing your scene")
                    .font(.title3.bold())
                    .foregroundStyle(.white)

                Text("カメラと空間センサーを整えて、心地よく撮影できる状態へ導いています。")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.82))
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                readinessRow(title: "Camera", isReady: model.camera.isSessionRunning)
                readinessRow(title: "Location", isReady: environmentService.isLocationReady || environmentService.authorizationStatus == .denied)
                readinessRow(title: "Spatial sensors", isReady: environmentService.isMotionReady || environmentService.isPressureReady)
            }
        }
        .padding(28)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .strokeBorder(.white.opacity(0.18))
        }
        .padding(24)
    }

    private var reviewProcessingOverlay: some View {
        ZStack {
            Color.black.opacity(0.76)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.18)

                VStack(spacing: 8) {
                    Text("Preparing your memory scene")
                        .font(.title3.bold())
                        .foregroundStyle(.white)

                    Text("写真、音、位置、空気感をひとつのシーンへまとめています。完了までお待ちください。")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.82))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(28)
            .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .strokeBorder(.white.opacity(0.16))
            }
            .padding(24)
        }
    }

    private func readinessRow(title: String, isReady: Bool) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Spacer()
            Label(isReady ? "Ready" : "Preparing", systemImage: isReady ? "checkmark.circle.fill" : "clock.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isReady ? .green : .white.opacity(0.8))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var captureSettingsSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Ambient capture")
                .font(.title3.bold())

            Text("環境音の長さをシーンに合わせて調整できます。短く素早く残すことも、少し長めに空気を集めることもできます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            let columns = [GridItem(.adaptive(minimum: 92), spacing: 10)]

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach([3.0, 6.0, 10.0, 15.0], id: \.self) { duration in
                    Button("\(Int(duration))秒") {
                        captureDurationSeconds = duration
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(captureDurationSeconds == duration ? palette.accent : palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(captureDurationSeconds == duration ? Color.white : palette.primaryText)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("長さ")
                    Spacer()
                    Text("\(Int(captureDurationSeconds.rounded()))秒")
                        .fontWeight(.semibold)
                }

                Slider(value: $captureDurationSeconds, in: 3...20, step: 1)
                    .tint(palette.accent)
            }

            Toggle(isOn: $delayRecordingUntilAfterShutter) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("シャッター音を避けて録音を始める")
                        .font(.subheadline.weight(.semibold))
                    Text("iPhone ではシャッター音を無効化できないため、オンにすると撮影後に少し待ってから環境音を記録します。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(palette.accent)

            Spacer()
        }
        .padding(24)
        .presentationBackground(.regularMaterial)
    }
}

private struct CameraShutterButton: View {
    let isEnabled: Bool
    let isRecording: Bool
    let progress: Double
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .trim(from: 0, to: isRecording ? max(progress, 0.08) : 1)
                    .stroke(accent.opacity(isRecording ? 0.95 : 0), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 96, height: 96)
                    .animation(.easeInOut(duration: 0.2), value: progress)

                Circle()
                    .strokeBorder(.white.opacity(isEnabled ? 0.95 : 0.35), lineWidth: 6)
                    .frame(width: 88, height: 88)

                Circle()
                    .fill(isEnabled ? Color.white : Color.white.opacity(0.35))
                    .frame(width: 70, height: 70)
                    .overlay {
                        if isRecording {
                            Image(systemName: "waveform")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.black.opacity(0.6))
                                .symbolEffect(.pulse, options: .repeating, isActive: true)
                        } else if !isEnabled {
                            ProgressView()
                                .tint(.black.opacity(0.55))
                        }
                    }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }
}

struct StatusMessageView: View {
    let symbol: String
    let text: String
    let tint: Color
    var atmosphere: AtmosphereStyle? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = ResonancePalette.make(for: colorScheme, atmosphere: atmosphere)

        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(palette.primaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(tint.opacity(colorScheme == .dark ? 0.18 : 0.1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(tint.opacity(colorScheme == .dark ? 0.32 : 0.2))
        }
    }
}

#Preview {
    NavigationStack {
        CaptureView(isActive: true)
    }
    .modelContainer(for: [MemoryEntry.self], inMemory: true)
}

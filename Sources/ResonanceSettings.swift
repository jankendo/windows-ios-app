import CoreLocation
import SwiftUI

enum NearbyMemoriesRadius: Double, CaseIterable, Identifiable, Codable {
    case meters250 = 250
    case meters500 = 500
    case meters1000 = 1_000

    var id: Double { rawValue }

    var localizedLabel: String {
        switch self {
        case .meters250:
            return "250m"
        case .meters500:
            return "500m"
        case .meters1000:
            return "1km"
        }
    }
}

enum PhotoCaptionStyle: String, CaseIterable, Identifiable, Codable {
    case poetic
    case factual
    case diary
    case haiku
    case oneLine

    var id: String { rawValue }

    var localizedLabel: String {
        switch self {
        case .poetic:
            return "詩的"
        case .factual:
            return "事実的"
        case .diary:
            return "日記調"
        case .haiku:
            return "俳句調"
        case .oneLine:
            return "一行"
        }
    }

    var localizedDescription: String {
        switch self {
        case .poetic:
            return "現行の余韻を残す語り口"
        case .factual:
            return "場所・時間・状況を客観的に整理"
        case .diary:
            return "一人称でやわらかく記述"
        case .haiku:
            return "短く余白を残す表現"
        case .oneLine:
            return "30文字前後の簡潔な一文"
        }
    }
}

enum ResonancePreferenceKey {
    static let timeCapsuleEnabled = "timeCapsuleEnabled"
    static let nearbyMemoriesEnabled = "nearbyMemoriesEnabled"
    static let nearbyMemoriesRadius = "nearbyMemoriesRadius"
    static let immersiveParticlesEnabled = "immersiveParticlesEnabled"
    static let immersiveAudioReactiveLightEnabled = "immersiveAudioReactiveLightEnabled"
    static let defaultCaptionStyle = "defaultCaptionStyle"
    static let intervalCaptureSpacingSeconds = "intervalCaptureSpacingSeconds"
    static let intervalCapturePlannedCount = "intervalCapturePlannedCount"
    static let intervalCaptureClipDuration = "intervalCaptureClipDuration"
    static let intervalCaptureSceneTitle = "intervalCaptureSceneTitle"
}

enum ResonancePreferences {
    static var timeCapsuleEnabled: Bool {
        value(for: ResonancePreferenceKey.timeCapsuleEnabled, default: true)
    }

    static var nearbyMemoriesEnabled: Bool {
        value(for: ResonancePreferenceKey.nearbyMemoriesEnabled, default: true)
    }

    static var nearbyMemoriesRadius: NearbyMemoriesRadius {
        let rawValue = UserDefaults.standard.double(forKey: ResonancePreferenceKey.nearbyMemoriesRadius)
        return NearbyMemoriesRadius(rawValue: rawValue == 0 ? NearbyMemoriesRadius.meters500.rawValue : rawValue) ?? .meters500
    }

    static var immersiveParticlesEnabled: Bool {
        value(for: ResonancePreferenceKey.immersiveParticlesEnabled, default: true)
    }

    static var immersiveAudioReactiveLightEnabled: Bool {
        value(for: ResonancePreferenceKey.immersiveAudioReactiveLightEnabled, default: true)
    }

    static var defaultCaptionStyle: PhotoCaptionStyle {
        guard let rawValue = UserDefaults.standard.string(forKey: ResonancePreferenceKey.defaultCaptionStyle) else {
            return .poetic
        }
        return PhotoCaptionStyle(rawValue: rawValue) ?? .poetic
    }

    private static func value(for key: String, default defaultValue: Bool) -> Bool {
        if UserDefaults.standard.object(forKey: key) == nil {
            return defaultValue
        }
        return UserDefaults.standard.bool(forKey: key)
    }
}

struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ResonancePreferenceKey.timeCapsuleEnabled) private var timeCapsuleEnabled = true
    @AppStorage(ResonancePreferenceKey.nearbyMemoriesEnabled) private var nearbyMemoriesEnabled = true
    @AppStorage(ResonancePreferenceKey.nearbyMemoriesRadius) private var nearbyMemoriesRadius = NearbyMemoriesRadius.meters500.rawValue
    @AppStorage(ResonancePreferenceKey.immersiveParticlesEnabled) private var immersiveParticlesEnabled = true
    @AppStorage(ResonancePreferenceKey.immersiveAudioReactiveLightEnabled) private var immersiveAudioReactiveLightEnabled = true
    @AppStorage(ResonancePreferenceKey.defaultCaptionStyle) private var defaultCaptionStyle = PhotoCaptionStyle.poetic.rawValue
    @AppStorage(ResonancePreferenceKey.intervalCaptureSpacingSeconds) private var intervalCaptureSpacingSeconds = 30.0
    @AppStorage(ResonancePreferenceKey.intervalCapturePlannedCount) private var intervalCapturePlannedCount = 3
    @AppStorage(ResonancePreferenceKey.intervalCaptureSceneTitle) private var intervalCaptureSceneTitle = ""

    private var palette: ResonancePalette {
        ResonancePalette.make(for: colorScheme)
    }

    var body: some View {
        ZStack {
            ResonanceGradientBackground()

            Form {
                Section("再会体験") {
                    Toggle("Time Capsule を表示", isOn: $timeCapsuleEnabled)
                    Toggle("近くの記録を表示", isOn: $nearbyMemoriesEnabled)

                    Picker("検索半径", selection: $nearbyMemoriesRadius) {
                        ForEach(NearbyMemoriesRadius.allCases) { radius in
                            Text(radius.localizedLabel).tag(radius.rawValue)
                        }
                    }
                    .disabled(!nearbyMemoriesEnabled)
                }

                Section("没入プレビュー") {
                    Toggle("環境粒子を有効化", isOn: $immersiveParticlesEnabled)
                    Toggle("音量連動の光を有効化", isOn: $immersiveAudioReactiveLightEnabled)

                    Text("Reduce Motion が有効な場合は動きの強い演出を自動的に抑えます。")
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryText)
                }

                Section("キャプション") {
                    Picker("標準スタイル", selection: $defaultCaptionStyle) {
                        ForEach(PhotoCaptionStyle.allCases) { style in
                            Text(style.localizedLabel).tag(style.rawValue)
                        }
                    }

                    if let selectedStyle = PhotoCaptionStyle(rawValue: defaultCaptionStyle) {
                        Text(selectedStyle.localizedDescription)
                            .font(.footnote)
                            .foregroundStyle(palette.secondaryText)
                    }
                }

                Section("Interval capture") {
                    TextField("既定のシーン名", text: $intervalCaptureSceneTitle)

                    HStack {
                        Text("撮影間隔")
                        Spacer()
                        Text("\(Int(intervalCaptureSpacingSeconds.rounded()))秒")
                            .foregroundStyle(palette.secondaryText)
                    }

                    Slider(value: $intervalCaptureSpacingSeconds, in: 10...180, step: 5)
                        .tint(palette.accent)

                    Stepper("既定の枚数 \(intervalCapturePlannedCount)", value: $intervalCapturePlannedCount, in: 2...12)

                    Text("Capture 画面の Interval モードで使う既定値です。")
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryText)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}

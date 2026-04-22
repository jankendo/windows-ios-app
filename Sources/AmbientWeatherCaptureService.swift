import CoreLocation
import Foundation
#if canImport(WeatherKit)
import WeatherKit
#endif

actor AmbientWeatherCaptureService {
    static let shared = AmbientWeatherCaptureService()

    struct FetchResult {
        let snapshot: MemoryWeatherSnapshot?
        let statusNote: String?
    }

#if canImport(WeatherKit)
    private let service = WeatherService()
#endif

    func currentWeatherSnapshot(for location: CLLocation?) async -> MemoryWeatherSnapshot? {
        let result = await currentWeatherResult(for: location)
        return result.snapshot
    }

    func currentWeatherResult(for location: CLLocation?) async -> FetchResult {
        guard let location else {
            return FetchResult(
                snapshot: nil,
                statusNote: "位置情報が安定してから天気を取得します。"
            )
        }

#if canImport(WeatherKit)
        for attempt in 0..<4 {
            do {
                let weather = try await service.weather(for: location)
                let current = weather.currentWeather
                return FetchResult(
                    snapshot: MemoryWeatherSnapshot(
                        conditionLabel: localizedConditionLabel(for: String(describing: current.condition)),
                        temperatureCelsius: current.temperature.converted(to: .celsius).value,
                        apparentTemperatureCelsius: current.apparentTemperature.converted(to: .celsius).value,
                        symbolName: current.symbolName
                    ),
                    statusNote: nil
                )
            } catch let weatherError as WeatherError {
                if case .permissionDenied = weatherError {
                    return FetchResult(
                        snapshot: nil,
                        statusNote: "WeatherKit がこの App ID で有効になっていません。Apple Developer の Identifiers で WeatherKit を有効化し、少し待ってから再ビルドしてください。"
                    )
                }

                if attempt == 3 {
                    return FetchResult(
                        snapshot: nil,
                        statusNote: weatherFailureNote(for: weatherError)
                    )
                }
            } catch {
                if attempt == 3 {
                    return FetchResult(
                        snapshot: nil,
                        statusNote: weatherFailureNote(for: error)
                    )
                }
            }

            try? await Task.sleep(nanoseconds: UInt64((0.6 + (Double(attempt) * 0.35)) * 1_000_000_000))
        }
        return FetchResult(snapshot: nil, statusNote: "天気の取得が完了しませんでした。")
#else
        return FetchResult(snapshot: nil, statusNote: "このビルドでは WeatherKit を利用できません。")
#endif
    }
}

#if canImport(WeatherKit)
private func weatherFailureNote(for error: Error) -> String {
    if let weatherError = error as? WeatherError {
        let detail = [
            weatherError.errorDescription,
            weatherError.failureReason,
            weatherError.recoverySuggestion
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }

        return detail ?? "WeatherKit の取得に失敗しました。App ID の WeatherKit と provisioning の反映を確認してから再試行してください。"
    }

    let nsError = error as NSError
    let detail = [
        nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines),
        nsError.localizedFailureReason?.trimmingCharacters(in: .whitespacesAndNewlines)
    ]
    .compactMap { $0 }
    .first { !$0.isEmpty }

    if let detail, !detail.isEmpty {
        return "\(detail) WeatherKit の capability / provisioning も確認してください。"
    }

    return "WeatherKit の取得に失敗しました。App ID の WeatherKit と provisioning の反映を確認してから再試行してください。"
}

private func localizedConditionLabel(for rawCondition: String) -> String {
    switch rawCondition.lowercased() {
    case "clear":
        return "快晴"
    case "mostlyclear":
        return "晴れ"
    case "partlycloudy":
        return "薄曇り"
    case "mostlycloudy", "cloudy":
        return "曇り"
    case "drizzle", "freezingdrizzle":
        return "霧雨"
    case "heavyrain", "sunshowers", "freezingrain":
        return "雨"
    case "heavysnow", "flurries", "sunflurries":
        return "雪"
    case "wintrymix":
        return "みぞれ"
    case "thunderstorms", "isolatedthunderstorms", "strongstorms":
        return "雷雨"
    case "foggy":
        return "霧"
    case "windy":
        return "風が強い"
    case "haze", "smoky", "blowingdust":
        return "霞"
    case "hail":
        return "ひょう"
    case "hot":
        return "暑い"
    case "frigid":
        return "厳しい寒さ"
    case "blizzard":
        return "吹雪"
    case "tropicalstorm", "hurricane":
        return "荒天"
    default:
        return "空模様"
    }
}
#endif

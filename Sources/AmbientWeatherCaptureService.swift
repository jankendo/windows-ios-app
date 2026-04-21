import CoreLocation
import Foundation
#if canImport(WeatherKit)
import WeatherKit
#endif

actor AmbientWeatherCaptureService {
    static let shared = AmbientWeatherCaptureService()

#if canImport(WeatherKit)
    private let service = WeatherService()
#endif

    func currentWeatherSnapshot(for location: CLLocation?) async -> MemoryWeatherSnapshot? {
        guard let location else { return nil }

#if canImport(WeatherKit)
        do {
            let weather = try await service.weather(for: location)
            let current = weather.currentWeather
            return MemoryWeatherSnapshot(
                conditionLabel: localizedConditionLabel(for: String(describing: current.condition)),
                temperatureCelsius: current.temperature.converted(to: .celsius).value,
                apparentTemperatureCelsius: current.apparentTemperature.converted(to: .celsius).value,
                symbolName: current.symbolName
            )
        } catch {
            return nil
        }
#else
        return nil
#endif
    }
}

#if canImport(WeatherKit)
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

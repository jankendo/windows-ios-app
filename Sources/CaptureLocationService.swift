import CoreLocation
import Foundation

@MainActor
final class CaptureLocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = CaptureLocationService()

    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var latestLocation: CLLocation?
    private var latestPlaceLabel: String?
    private var locationContinuation: CheckedContinuation<Void, Never>?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorizationStatus = manager.authorizationStatus
    }

    func prepare() {
        authorizationStatus = manager.authorizationStatus

        switch authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        default:
            break
        }
    }

    func currentPlaceLabel() async -> String? {
        guard authorizationStatus.allowsLocationAccess else { return nil }

        if let latestPlaceLabel {
            return latestPlaceLabel
        }

        if latestLocation == nil {
            await refreshLocation()
        }

        guard let latestLocation else { return nil }

        if let latestPlaceLabel {
            return latestPlaceLabel
        }

        let label = await reverseGeocodeLabel(for: latestLocation)
        latestPlaceLabel = label
        return label
    }

    private func refreshLocation() async {
        guard authorizationStatus.allowsLocationAccess else { return }
        guard locationContinuation == nil else { return }

        await withCheckedContinuation { continuation in
            locationContinuation = continuation
            manager.requestLocation()
        }
    }

    private func reverseGeocodeLabel(for location: CLLocation) async -> String? {
        let placemarks = try? await geocoder.reverseGeocodeLocation(location)
        guard let placemark = placemarks?.first else { return nil }

        let parts = [
            placemark.locality,
            placemark.subLocality,
            placemark.name
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        return parts.first
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus.allowsLocationAccess {
            manager.requestLocation()
        } else {
            latestLocation = nil
            latestPlaceLabel = nil
            locationContinuation?.resume()
            locationContinuation = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        latestLocation = locations.last
        locationContinuation?.resume()
        locationContinuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationContinuation?.resume()
        locationContinuation = nil
    }
}

private extension CLAuthorizationStatus {
    var allowsLocationAccess: Bool {
        self == .authorizedAlways || self == .authorizedWhenInUse
    }
}

import CoreLocation
import CoreMotion
import Foundation
import UIKit

@MainActor
final class CaptureLocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = CaptureLocationService()

    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isLocationReady = false
    @Published private(set) var isMotionReady = false
    @Published private(set) var isPressureReady = false

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private let motionManager = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let preferredHorizontalAccuracy: CLLocationAccuracy = 10

    private var latestLocation: CLLocation?
    private var latestPlaceLabel: String?
    private var latestHeading: CLLocationDirection?
    private var latestPressureKilopascals: Double?
    private var latestRelativeAltitude: Double?
    private var latestPitchDegrees: Double?
    private var latestRollDegrees: Double?
    private var latestYawDegrees: Double?
    private var locationContinuation: CheckedContinuation<Void, Never>?
    private var locationTimeoutTask: Task<Void, Never>?
    private var isLocationPipelineActive = false

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        authorizationStatus = manager.authorizationStatus
    }

    func prepare() {
        authorizationStatus = manager.authorizationStatus
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        startSpatialSensors()

        switch authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            startLocationPipeline()
        default:
            break
        }
    }

    func suspend() {
        stopLocationPipeline()
        stopSpatialSensors()
    }

    func currentPlaceLabel() async -> String? {
        guard authorizationStatus.allowsLocationAccess else { return nil }

        if latestLocation == nil {
            await refreshLocation()
        }

        guard let latestLocation else { return latestPlaceLabel }

        if let latestPlaceLabel {
            return latestPlaceLabel
        }

        let label = await reverseGeocodeLabel(for: latestLocation)
        latestPlaceLabel = label
        return label
    }

    func currentEnvironmentSnapshot() async -> CaptureEnvironmentSnapshot? {
        if authorizationStatus.allowsLocationAccess, needsHigherPrecisionLocation {
            await refreshLocation()
        }

        let orientationRaw = UIDevice.current.orientation.resonanceOrientationName
        let altitude = latestLocation.flatMap { $0.verticalAccuracy >= 0 ? $0.altitude : nil }
        let speed = latestLocation.flatMap { $0.speed >= 0 ? $0.speed : nil }
        let course = latestLocation.flatMap { $0.course >= 0 ? $0.course : nil }

        return CaptureEnvironmentSnapshot(
            latitude: latestLocation?.coordinate.latitude,
            longitude: latestLocation?.coordinate.longitude,
            horizontalAccuracy: latestLocation?.horizontalAccuracy,
            altitude: altitude,
            speed: speed,
            course: course,
            heading: latestHeading,
            pressureKilopascals: latestPressureKilopascals,
            relativeAltitudeMeters: latestRelativeAltitude,
            pitchDegrees: latestPitchDegrees,
            rollDegrees: latestRollDegrees,
            yawDegrees: latestYawDegrees,
            deviceOrientationRaw: orientationRaw,
            timeZoneIdentifier: TimeZone.current.identifier
        )
    }

    func currentLocation() async -> CLLocation? {
        if authorizationStatus.allowsLocationAccess, needsHigherPrecisionLocation {
            await refreshLocation()
        }
        return latestLocation ?? manager.location
    }

    private func startLocationPipeline() {
        guard !isLocationPipelineActive else { return }
        isLocationPipelineActive = true
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.headingFilter = 5
            manager.startUpdatingHeading()
        }
    }

    private func stopLocationPipeline() {
        locationTimeoutTask?.cancel()
        locationTimeoutTask = nil
        guard isLocationPipelineActive else { return }
        isLocationPipelineActive = false
        manager.stopUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.stopUpdatingHeading()
        }
    }

    private func startSpatialSensors() {
        if motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive {
            motionManager.deviceMotionUpdateInterval = 0.25
            motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
                guard let self, let motion else { return }
                self.latestPitchDegrees = motion.attitude.pitch * 180 / .pi
                self.latestRollDegrees = motion.attitude.roll * 180 / .pi
                self.latestYawDegrees = motion.attitude.yaw * 180 / .pi
                self.isMotionReady = true
            }
        }

        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let self, let data else { return }
                self.latestPressureKilopascals = data.pressure.doubleValue
                self.latestRelativeAltitude = data.relativeAltitude.doubleValue
                self.isPressureReady = true
            }
        }
    }

    private func stopSpatialSensors() {
        if motionManager.isDeviceMotionActive {
            motionManager.stopDeviceMotionUpdates()
        }
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.stopRelativeAltitudeUpdates()
        }
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        isMotionReady = false
        isPressureReady = false
    }

    private func refreshLocation() async {
        guard authorizationStatus.allowsLocationAccess else { return }
        guard locationContinuation == nil else { return }

        if let currentLocation = manager.location, currentLocation.horizontalAccuracy > 0, currentLocation.horizontalAccuracy <= preferredHorizontalAccuracy {
            latestLocation = currentLocation
            isLocationReady = true
            return
        }

        await withCheckedContinuation { continuation in
            locationContinuation = continuation
            locationTimeoutTask?.cancel()
            locationTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await MainActor.run {
                    self?.resumeLocationContinuationIfNeeded()
                }
            }
            manager.requestLocation()
        }
    }

    private func resumeLocationContinuationIfNeeded() {
        locationTimeoutTask?.cancel()
        locationTimeoutTask = nil
        locationContinuation?.resume()
        locationContinuation = nil
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

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            authorizationStatus = manager.authorizationStatus
            if authorizationStatus.allowsLocationAccess {
                startLocationPipeline()
            } else {
                isLocationReady = false
                latestLocation = nil
                latestPlaceLabel = nil
                latestHeading = nil
                resumeLocationContinuationIfNeeded()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            let bestLocation = (locations + [latestLocation].compactMap { $0 })
                .filter { $0.horizontalAccuracy > 0 }
                .min { lhs, rhs in
                    lhs.horizontalAccuracy < rhs.horizontalAccuracy
                }
                ?? locations.last
            latestLocation = bestLocation
            isLocationReady = latestLocation != nil
            resumeLocationContinuationIfNeeded()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        Task { @MainActor in
            latestHeading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            resumeLocationContinuationIfNeeded()
        }
    }
}

private extension CaptureLocationService {
    var needsHigherPrecisionLocation: Bool {
        guard let latestLocation else { return true }
        return latestLocation.horizontalAccuracy <= 0 || latestLocation.horizontalAccuracy > preferredHorizontalAccuracy
    }
}

private extension CLAuthorizationStatus {
    var allowsLocationAccess: Bool {
        self == .authorizedAlways || self == .authorizedWhenInUse
    }
}

private extension UIDeviceOrientation {
    var resonanceOrientationName: String? {
        switch self {
        case .portrait:
            return "portrait"
        case .portraitUpsideDown:
            return "portraitUpsideDown"
        case .landscapeLeft:
            return "landscapeLeft"
        case .landscapeRight:
            return "landscapeRight"
        case .faceUp:
            return "faceUp"
        case .faceDown:
            return "faceDown"
        default:
            return nil
        }
    }
}

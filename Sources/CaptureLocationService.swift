import CoreLocation
import CoreMotion
import Foundation
import UIKit

@MainActor
final class CaptureLocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = CaptureLocationService()

    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var accuracyAuthorization: CLAccuracyAuthorization = .reducedAccuracy
    @Published private(set) var isLocationReady = false
    @Published private(set) var isMotionReady = false
    @Published private(set) var isPressureReady = false
    @Published private(set) var previewParallax: CGSize = .zero

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private let motionManager = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "CaptureLocationService.motion"
        queue.qualityOfService = .userInteractive
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let preferredHorizontalAccuracy: CLLocationAccuracy = 6
    private let cachedLocationFreshnessLimit: TimeInterval = 8
    private let preciseLocationRetryInterval: TimeInterval = 30
    private let diagnostics = AudioPlaybackDiagnostics.shared

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
    private var lastPreciseLocationRequestAt: Date?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        authorizationStatus = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
    }

    func prepare() {
        authorizationStatus = manager.authorizationStatus
        diagnostics.record("prepare auth=\(authorizationStatus.rawValue) precise=\(manager.accuracyAuthorization == .fullAccuracy)", category: "location")
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        startSpatialSensors()

        switch authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            startLocationPipeline()
            requestPreciseLocationIfNeeded()
        default:
            break
        }
    }

    func suspend() {
        diagnostics.record("suspend location pipeline", category: "location")
        stopLocationPipeline()
        stopSpatialSensors()
    }

    func currentPlaceLabel(forceRefresh: Bool = false) async -> String? {
        guard authorizationStatus.allowsLocationAccess else { return nil }

        if forceRefresh || latestLocation == nil || needsHigherPrecisionLocation {
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

    func currentEnvironmentSnapshot(forceRefresh: Bool = false) async -> CaptureEnvironmentSnapshot? {
        if authorizationStatus.allowsLocationAccess, forceRefresh || needsHigherPrecisionLocation {
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

    func currentLocation(forceRefresh: Bool = false) async -> CLLocation? {
        if authorizationStatus.allowsLocationAccess, forceRefresh || needsHigherPrecisionLocation {
            await refreshLocation()
        }
        return latestLocation ?? manager.location
    }

    var previewHorizontalShift: CGFloat {
        previewParallax.width
    }

    var previewVerticalShift: CGFloat {
        previewParallax.height
    }

    private func startLocationPipeline() {
        guard !isLocationPipelineActive else { return }
        isLocationPipelineActive = true
        diagnostics.record("start location updates", category: "location")
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
        diagnostics.record("stop location updates", category: "location")
        manager.stopUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.stopUpdatingHeading()
        }
    }

    private func startSpatialSensors() {
        if motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive {
            motionManager.deviceMotionUpdateInterval = 1.0 / 120.0
            motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
                guard let self, let motion else { return }
                let horizontalTilt = max(-1.0, min(1.0, motion.gravity.x / 0.42))
                let verticalTilt = max(-1.0, min(1.0, (-motion.gravity.z) / 0.56))
                let targetHorizontalShift = CGFloat(horizontalTilt * 18)
                let targetVerticalShift = CGFloat(verticalTilt * 14)
                let pitchDegrees = motion.attitude.pitch * 180 / .pi
                let rollDegrees = motion.attitude.roll * 180 / .pi
                let yawDegrees = motion.attitude.yaw * 180 / .pi

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let currentParallax = self.previewParallax
                    let smoothedHorizontalShift = currentParallax.width + ((targetHorizontalShift - currentParallax.width) * 0.5)
                    let smoothedVerticalShift = currentParallax.height + ((targetVerticalShift - currentParallax.height) * 0.5)
                    self.previewParallax = CGSize(width: smoothedHorizontalShift, height: smoothedVerticalShift)
                    self.latestPitchDegrees = pitchDegrees
                    self.latestRollDegrees = rollDegrees
                    self.latestYawDegrees = yawDegrees
                    if !self.isMotionReady {
                        self.isMotionReady = true
                    }
                }
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
        previewParallax = .zero
    }

    private func refreshLocation() async {
        guard authorizationStatus.allowsLocationAccess else { return }
        guard locationContinuation == nil else { return }
        requestPreciseLocationIfNeeded()

        if let currentLocation = manager.location, isFreshEnough(currentLocation) {
            if manager.accuracyAuthorization == .reducedAccuracy {
                latestLocation = currentLocation
                isLocationReady = true
                return
            }
            if currentLocation.horizontalAccuracy > 0, currentLocation.horizontalAccuracy <= preferredHorizontalAccuracy {
                latestLocation = currentLocation
                isLocationReady = true
                return
            }
        }

        await withCheckedContinuation { continuation in
            locationContinuation = continuation
            locationTimeoutTask?.cancel()
            locationTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
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

        let label = parts.first
        diagnostics.record("reverse geocode label=\(label ?? "nil")", category: "location")
        return label
    }

    private func requestPreciseLocationIfNeeded() {
        guard authorizationStatus.allowsLocationAccess else { return }
        guard manager.accuracyAuthorization == .reducedAccuracy else { return }
        if let lastPreciseLocationRequestAt,
           Date().timeIntervalSince(lastPreciseLocationRequestAt) < preciseLocationRetryInterval {
            return
        }
        lastPreciseLocationRequestAt = .now
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "ResonancePreciseCapture") { _ in }
    }

    private func isFreshEnough(_ location: CLLocation) -> Bool {
        abs(location.timestamp.timeIntervalSinceNow) <= cachedLocationFreshnessLimit
    }

    private func updateStoredLocation(_ location: CLLocation?) {
        guard let location else { return }
        if let latestLocation, latestLocation.distance(from: location) > 5 {
            latestPlaceLabel = nil
        }
        latestLocation = location
        isLocationReady = true
    }

    private func shouldResumeLocationWait(with location: CLLocation?) -> Bool {
        guard let location else { return false }
        if manager.accuracyAuthorization == .reducedAccuracy {
            return true
        }
        return location.horizontalAccuracy > 0 && location.horizontalAccuracy <= preferredHorizontalAccuracy
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            authorizationStatus = manager.authorizationStatus
            accuracyAuthorization = manager.accuracyAuthorization
            diagnostics.record("authorization changed auth=\(authorizationStatus.rawValue) precise=\(accuracyAuthorization == .fullAccuracy)", category: "location")
            if authorizationStatus.allowsLocationAccess {
                startLocationPipeline()
                requestPreciseLocationIfNeeded()
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
            let historicalLocations = latestLocation.map { [$0] } ?? []
            let candidateLocations = locations + historicalLocations
            let preciseLocations = candidateLocations.filter { $0.horizontalAccuracy > 0 }
            let bestLocation = preciseLocations.min { lhs, rhs in
                lhs.horizontalAccuracy < rhs.horizontalAccuracy
            } ?? candidateLocations.last
            updateStoredLocation(bestLocation)
            if let bestLocation {
                diagnostics.record(
                    "location update lat=\(String(format: "%.6f", bestLocation.coordinate.latitude)) lon=\(String(format: "%.6f", bestLocation.coordinate.longitude)) acc=\(String(format: "%.1f", bestLocation.horizontalAccuracy))",
                    category: "location"
                )
            }
            if shouldResumeLocationWait(with: bestLocation) {
                resumeLocationContinuationIfNeeded()
            }
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
        if accuracyAuthorization == .reducedAccuracy {
            return !isFreshEnough(latestLocation)
        }
        return !isFreshEnough(latestLocation)
            || latestLocation.horizontalAccuracy <= 0
            || latestLocation.horizontalAccuracy > preferredHorizontalAccuracy
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

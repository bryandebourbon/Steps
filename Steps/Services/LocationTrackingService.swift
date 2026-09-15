import Foundation
import CoreLocation

final class LocationTrackingService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var locations: [CLLocation] = []
    private let coarseAccuracy: CLLocationAccuracy = 2_000
    var onChange: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 6
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        manager.allowsBackgroundLocationUpdates = true
    }

    var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return true
        default:
            return false
        }
    }

    var isAlwaysAuthorized: Bool {
        manager.authorizationStatus == .authorizedAlways
    }

    func requestAccess() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            beginForegroundUpdates()
            manager.requestAlwaysAuthorization()
        case .authorizedAlways:
            beginAlwaysUpdates()
        default:
            break
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    func restore(_ stored: [CLLocation]) {
        let start = Calendar.current.startOfDay(for: Date())
        locations = stored
            .filter { $0.timestamp >= start }
            .sorted { $0.timestamp < $1.timestamp }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        start()
        notify()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        append(locations, maxAccuracy: coarseAccuracy)
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let timestamp: Date
        if visit.departureDate != .distantFuture {
            timestamp = visit.departureDate
        } else if visit.arrivalDate != .distantPast {
            timestamp = visit.arrivalDate
        } else {
            timestamp = Date()
        }
        let fix = CLLocation(
            coordinate: visit.coordinate,
            altitude: 0,
            horizontalAccuracy: 65,
            verticalAccuracy: -1,
            timestamp: timestamp
        )
        append([fix], maxAccuracy: coarseAccuracy)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        notify()
    }

    private func beginForegroundUpdates() {
        manager.allowsBackgroundLocationUpdates = false
        manager.pausesLocationUpdatesAutomatically = false
        manager.startUpdatingLocation()
    }

    private func beginAlwaysUpdates() {
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }
        manager.startMonitoringVisits()
    }

    private func append(_ incoming: [CLLocation], maxAccuracy: CLLocationAccuracy) {
        let useful = incoming.filter {
            $0.horizontalAccuracy > 0 && $0.horizontalAccuracy <= maxAccuracy
        }
        let lastTime = locations.last?.timestamp ?? .distantPast
        let fresh = useful.filter { $0.timestamp > lastTime }
        guard !fresh.isEmpty else { return }
        locations.append(contentsOf: fresh)
        notify()
    }

    private func notify() {
        DispatchQueue.main.async { [weak self] in
            self?.onChange?()
        }
    }
}

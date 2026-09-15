import Foundation
import CoreLocation

final class LocationTrackingService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var locations: [CLLocation] = []
    var onChange: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 6
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
    }

    var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return true
        default:
            return false
        }
    }

    func requestAccess() {
        manager.requestWhenInUseAuthorization()
    }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways:
            manager.allowsBackgroundLocationUpdates = true
            manager.startUpdatingLocation()
        case .authorizedWhenInUse:
            manager.startUpdatingLocation()
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        start()
        notify()
    }

    func restore(_ stored: [CLLocation]) {
        let start = Calendar.current.startOfDay(for: Date())
        locations = stored
            .filter { $0.timestamp >= start }
            .sorted { $0.timestamp < $1.timestamp }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let useful = locations.filter { $0.horizontalAccuracy > 0 && $0.horizontalAccuracy < 50 }
        let lastTime = self.locations.last?.timestamp ?? .distantPast
        let fresh = useful.filter { $0.timestamp > lastTime }
        guard !fresh.isEmpty else { return }
        self.locations.append(contentsOf: fresh)
        notify()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        notify()
    }

    private func notify() {
        DispatchQueue.main.async { [weak self] in
            self?.onChange?()
        }
    }
}

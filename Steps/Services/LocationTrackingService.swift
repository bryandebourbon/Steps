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

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let useful = locations.filter { $0.horizontalAccuracy > 0 && $0.horizontalAccuracy < 50 }
        self.locations.append(contentsOf: useful)
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

import Foundation
import CoreLocation

struct PersistedFix: Codable, Equatable {
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    var horizontalAccuracy: Double

    init(location: CLLocation) {
        timestamp = location.timestamp
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        horizontalAccuracy = location.horizontalAccuracy
    }

    var clLocation: CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 0,
            horizontalAccuracy: max(horizontalAccuracy, 1),
            verticalAccuracy: -1,
            timestamp: timestamp
        )
    }
}

struct StepBucket: Codable, Equatable {
    var date: Date
    var steps: Double
}

struct WalkSnapshot: Codable {
    var savedAt: Date
    var dayStart: Date
    var usingSample: Bool
    var day: WalkDay
    var totals: LiveTotals?
    var timeline: [StepBucket]
    var fixes: [PersistedFix]
}

enum WalkCache {
    private static var fileURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = folder.appendingPathComponent("Steps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("today-walk.json")
    }

    static func loadToday() -> WalkSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let snap = try? decoder.decode(WalkSnapshot.self, from: data) else { return nil }
        guard Calendar.current.isDateInToday(snap.dayStart) else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        return snap
    }

    static func save(_ snapshot: WalkSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}

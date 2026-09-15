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
    private static var directory: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = folder.appendingPathComponent("Steps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func fileURL(for date: Date) -> URL {
        directory.appendingPathComponent("walk-\(dayKey(date)).json")
    }

    static func loadToday() -> WalkSnapshot? {
        load(for: Date())
    }

    static func load(for date: Date) -> WalkSnapshot? {
        migrateLegacyIfNeeded()
        let start = Calendar.current.startOfDay(for: date)
        guard let snap = decode(fileURL(for: start)) else { return nil }
        guard Calendar.current.isDate(snap.dayStart, inSameDayAs: start) else { return nil }
        return snap
    }

    static func save(_ snapshot: WalkSnapshot) {
        migrateLegacyIfNeeded()
        let start = Calendar.current.startOfDay(for: snapshot.dayStart)
        let stamped = WalkSnapshot(
            savedAt: snapshot.savedAt,
            dayStart: start,
            usingSample: snapshot.usingSample,
            day: snapshot.day,
            totals: snapshot.totals,
            timeline: snapshot.timeline,
            fixes: snapshot.fixes
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(stamped) else { return }
        try? data.write(to: fileURL(for: start), options: [.atomic])
    }

    private static func migrateLegacyIfNeeded() {
        let legacy = directory.appendingPathComponent("today-walk.json")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        if let snap = decode(legacy) {
            let dest = fileURL(for: snap.dayStart)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.copyItem(at: legacy, to: dest)
            }
        }
        try? FileManager.default.removeItem(at: legacy)
    }

    private static func decode(_ url: URL) -> WalkSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(WalkSnapshot.self, from: data)
    }
}

import Foundation
import CoreLocation

enum DataSource: String, Equatable {
    case sample
    case live
}

struct DayStats: Equatable {
    var steps: Int
    var meters: Double
    var activeSeconds: TimeInterval
    var flights: Int
    var calories: Int
}

struct TrackPoint: Identifiable, Equatable {
    let id: Int
    let date: Date
    let latitude: Double
    let longitude: Double
    let cumulativeSteps: Int
    let cumulativeMeters: Double
    let isMoving: Bool

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct AverageSample: Identifiable, Equatable {
    let id: Int
    let date: Date
    let steps: Int
}

struct WalkDay: Equatable {
    var date: Date
    var points: [TrackPoint]
    var average: [AverageSample]
    var stats: DayStats
    var source: DataSource

    var startOfDay: Date {
        Calendar.current.startOfDay(for: date)
    }

    var endOfDay: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: startOfDay) ?? date
    }

    /// Enough distinct moving samples to draw a path and tick while scrubbing.
    var canScrub: Bool {
        guard points.count >= 16 else { return false }
        let moving = points.filter(\.isMoving)
        guard moving.count >= 8 else { return false }
        guard (points.last?.cumulativeMeters ?? 0) >= 80 else { return false }
        var unique = Set<String>()
        for point in moving {
            unique.insert(String(format: "%.4f,%.4f", point.latitude, point.longitude))
            if unique.count >= 8 { return true }
        }
        return false
    }

    func point(nearestTo target: Date) -> TrackPoint? {
        guard !points.isEmpty else { return nil }
        var low = 0
        var high = points.count - 1
        if target <= points[low].date { return points[low] }
        if target >= points[high].date { return points[high] }
        while low + 1 < high {
            let mid = (low + high) / 2
            if points[mid].date == target { return points[mid] }
            if points[mid].date < target {
                low = mid
            } else {
                high = mid
            }
        }
        let left = points[low]
        let right = points[high]
        let dl = abs(left.date.timeIntervalSince(target))
        let dr = abs(right.date.timeIntervalSince(target))
        return dl <= dr ? left : right
    }

    func averageSteps(at target: Date) -> Int {
        guard !average.isEmpty else { return 0 }
        var closest = average[0]
        var best = abs(closest.date.timeIntervalSince(target))
        for sample in average.dropFirst() {
            let delta = abs(sample.date.timeIntervalSince(target))
            if delta < best {
                best = delta
                closest = sample
            }
        }
        return closest.steps
    }

    func highlightedCoordinates(upTo point: TrackPoint?) -> [CLLocationCoordinate2D] {
        guard let point else { return [] }
        return points.prefix(point.id + 1).map(\.coordinate)
    }

    func remainingCoordinates(after point: TrackPoint?) -> [CLLocationCoordinate2D] {
        guard let point, point.id < points.count - 1 else { return [] }
        return points.suffix(from: point.id).map(\.coordinate)
    }

    func activeSeconds(upTo point: TrackPoint?) -> TimeInterval {
        guard let point, !points.isEmpty else { return stats.activeSeconds }
        let end = min(point.id, points.count - 1)
        guard end > 0 else { return 0 }
        var total: TimeInterval = 0
        for index in 1...end {
            if points[index].isMoving {
                total += points[index].date.timeIntervalSince(points[index - 1].date)
            }
        }
        return total
    }
}

enum Geo {
    static let earthRadius = 6_371_000.0

    static func haversine(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLat = (to.latitude - from.latitude) * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * atan2(sqrt(a), sqrt(1 - a))
    }

    static func interpolate(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        fraction: Double
    ) -> CLLocationCoordinate2D {
        let t = min(max(fraction, 0), 1)
        return CLLocationCoordinate2D(
            latitude: from.latitude + (to.latitude - from.latitude) * t,
            longitude: from.longitude + (to.longitude - from.longitude) * t
        )
    }

    static func offset(
        _ coordinate: CLLocationCoordinate2D,
        eastMeters: Double,
        northMeters: Double
    ) -> CLLocationCoordinate2D {
        let dLat = northMeters / 111_111.0
        let dLon = eastMeters / (111_111.0 * cos(coordinate.latitude * .pi / 180))
        return CLLocationCoordinate2D(
            latitude: coordinate.latitude + dLat,
            longitude: coordinate.longitude + dLon
        )
    }
}

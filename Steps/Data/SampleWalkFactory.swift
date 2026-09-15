import Foundation
import CoreLocation

enum SampleWalkFactory {
    private static let metersPerStep = 0.712
    private static let home = CLLocationCoordinate2D(latitude: 37.76052, longitude: -122.42698)
    private static let work = CLLocationCoordinate2D(latitude: 37.76492, longitude: -122.41942)

    static func makeDay(for date: Date = Date()) -> WalkDay {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        var rng = SeededGenerator(seed: 0x5EED_0014)

        let morning = densify(
            waypoints: [
                home,
                CLLocationCoordinate2D(latitude: 37.75986, longitude: -122.42690),
                CLLocationCoordinate2D(latitude: 37.75970, longitude: -122.42410),
                CLLocationCoordinate2D(latitude: 37.76090, longitude: -122.42220),
                CLLocationCoordinate2D(latitude: 37.76180, longitude: -122.42155),
                CLLocationCoordinate2D(latitude: 37.76420, longitude: -122.42160),
                work
            ],
            start: at(start, 7, 18),
            duration: 32 * 60,
            rng: &rng
        )

        let lunch = densify(
            waypoints: [
                work,
                CLLocationCoordinate2D(latitude: 37.76495, longitude: -122.41780),
                CLLocationCoordinate2D(latitude: 37.76655, longitude: -122.41770),
                CLLocationCoordinate2D(latitude: 37.76660, longitude: -122.42150),
                CLLocationCoordinate2D(latitude: 37.76510, longitude: -122.42155),
                work
            ],
            start: at(start, 12, 22),
            duration: 18 * 60,
            rng: &rng
        )

        let evening = densify(
            waypoints: [
                work,
                CLLocationCoordinate2D(latitude: 37.76340, longitude: -122.41940),
                CLLocationCoordinate2D(latitude: 37.76210, longitude: -122.42110),
                CLLocationCoordinate2D(latitude: 37.76100, longitude: -122.42340),
                CLLocationCoordinate2D(latitude: 37.76040, longitude: -122.42550),
                home
            ],
            start: at(start, 17, 32),
            duration: 25 * 60,
            rng: &rng
        )

        var raw: [(date: Date, coordinate: CLLocationCoordinate2D, moving: Bool)] = []
        raw.append(contentsOf: linger(at: home, from: at(start, 0, 0), to: at(start, 7, 18), step: 12 * 60))
        raw.append(contentsOf: morning)
        raw.append(contentsOf: linger(at: work, from: at(start, 8, 0), to: at(start, 12, 22), step: 8 * 60))
        raw.append(contentsOf: lunch)
        raw.append(contentsOf: linger(at: work, from: at(start, 12, 51), to: at(start, 17, 32), step: 8 * 60))
        raw.append(contentsOf: evening)
        raw.append(contentsOf: linger(at: home, from: at(start, 18, 2), to: at(start, 18, 15), step: 4 * 60))

        raw.sort { $0.date < $1.date }

        var points: [TrackPoint] = []
        var steps = 0
        var meters = 0.0
        var active: TimeInterval = 0
        var lastCoord = raw.first?.coordinate ?? home
        var lastDate = raw.first?.date ?? start

        for (index, sample) in raw.enumerated() {
            let gap = sample.date.timeIntervalSince(lastDate)
            let distance = Geo.haversine(from: lastCoord, to: sample.coordinate)
            if sample.moving {
                meters += distance
                steps += max(1, Int((distance / metersPerStep).rounded()))
                active += max(gap, 0)
            } else if gap >= 7 * 60 {
                steps += Int.random(in: 4...14, using: &rng)
            }
            points.append(
                TrackPoint(
                    id: index,
                    date: sample.date,
                    latitude: sample.coordinate.latitude,
                    longitude: sample.coordinate.longitude,
                    cumulativeSteps: steps,
                    cumulativeMeters: meters,
                    isMoving: sample.moving
                )
            )
            lastCoord = sample.coordinate
            lastDate = sample.date
        }

        let last = points.last
        let stats = DayStats(
            steps: last?.cumulativeSteps ?? 0,
            meters: last?.cumulativeMeters ?? 0,
            activeSeconds: active,
            flights: 8,
            calories: max(1, Int(Double(last?.cumulativeSteps ?? 0) * 0.0465))
        )

        return WalkDay(
            date: start,
            points: points,
            average: averageCurve(for: date),
            stats: stats,
            source: .sample
        )
    }

    static func averageCurve(for date: Date) -> [AverageSample] {
        makeAverage(start: Calendar.current.startOfDay(for: date))
    }

    private static func makeAverage(start: Date) -> [AverageSample] {
        let end = start.addingTimeInterval(24 * 60 * 60)
        var samples: [AverageSample] = []
        var cursor = start
        var index = 0
        while cursor <= end {
            let hour = cursor.timeIntervalSince(start) / 3600
            let steps: Double
            switch hour {
            case ..<6:
                steps = 80 * hour
            case 6..<9:
                steps = 480 + (hour - 6) * 720
            case 9..<12:
                steps = 2_640 + (hour - 9) * 620
            case 12..<18:
                steps = 4_500 + (hour - 12) * 1_080
            default:
                steps = 10_980 + (hour - 18) * 1_420
            }
            samples.append(AverageSample(id: index, date: cursor, steps: Int(steps.rounded())))
            cursor = cursor.addingTimeInterval(5 * 60)
            index += 1
        }
        return samples
    }

    private static func densify(
        waypoints: [CLLocationCoordinate2D],
        start: Date,
        duration: TimeInterval,
        rng: inout SeededGenerator
    ) -> [(date: Date, coordinate: CLLocationCoordinate2D, moving: Bool)] {
        guard waypoints.count >= 2, duration > 0 else { return [] }
        var legs: [Double] = []
        var total = 0.0
        for index in 1..<waypoints.count {
            let length = Geo.haversine(from: waypoints[index - 1], to: waypoints[index])
            legs.append(length)
            total += length
        }

        let interval: TimeInterval = 15
        let count = max(2, Int(duration / interval))
        var result: [(date: Date, coordinate: CLLocationCoordinate2D, moving: Bool)] = []

        for step in 0...count {
            let fraction = Double(step) / Double(count)
            let distanceAlong = total * fraction
            var remaining = distanceAlong
            var coordinate = waypoints.last ?? waypoints[0]
            for index in 0..<legs.count {
                if remaining <= legs[index] || index == legs.count - 1 {
                    let t = legs[index] == 0 ? 1 : remaining / legs[index]
                    coordinate = Geo.interpolate(from: waypoints[index], to: waypoints[index + 1], fraction: t)
                    break
                }
                remaining -= legs[index]
            }
            let jittered = Geo.offset(
                coordinate,
                eastMeters: Double.random(in: -4...4, using: &rng),
                northMeters: Double.random(in: -4...4, using: &rng)
            )
            result.append(
                (
                    date: start.addingTimeInterval(fraction * duration),
                    coordinate: jittered,
                    moving: true
                )
            )
        }
        return result
    }

    private static func linger(
        at coordinate: CLLocationCoordinate2D,
        from: Date,
        to: Date,
        step: TimeInterval
    ) -> [(date: Date, coordinate: CLLocationCoordinate2D, moving: Bool)] {
        guard to > from else { return [] }
        var result: [(date: Date, coordinate: CLLocationCoordinate2D, moving: Bool)] = []
        var cursor = from
        while cursor <= to {
            result.append((date: cursor, coordinate: coordinate, moving: false))
            cursor = cursor.addingTimeInterval(step)
        }
        if result.last?.date != to {
            result.append((date: to, coordinate: coordinate, moving: false))
        }
        return result
    }

    private static func at(_ start: Date, _ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(byAdding: DateComponents(hour: hour, minute: minute), to: start) ?? start
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return state
    }
}

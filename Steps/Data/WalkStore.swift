import Foundation
import CoreLocation
import Observation

@MainActor
@Observable
final class WalkStore {
    var loadState: LoadState = .loading
    var day: WalkDay?
    var scrubDate: Date?
    var usingSample = false

    @ObservationIgnored private let location = LocationTrackingService()
    @ObservationIgnored private let pedometer = PedometerService()
    @ObservationIgnored private let health = HealthKitService()
    @ObservationIgnored private var liveTotals: LiveTotals?
    @ObservationIgnored private var healthTimeline: [(date: Date, steps: Double)] = []
    @ObservationIgnored private var liveDay: WalkDay?

    @ObservationIgnored private var persistTask: Task<Void, Never>?

    init() {
        _ = restoreFromDisk()
    }

    var displayPoint: TrackPoint? {
        guard let day else { return nil }
        if let scrubDate {
            return day.point(nearestTo: scrubDate)
        }
        return day.points.last
    }

    var isScrubbing: Bool {
        scrubDate != nil
    }

    func load() async {
        scrubDate = nil
        let restored = restoreFromDisk()
        if !restored {
            loadState = .loading
            day = nil
        }

        location.onChange = { [weak self] in
            self?.rebuildLiveDay()
        }
        location.requestAccess()
        location.start()

        if PedometerService.isAvailable {
            if let fresh = await pedometer.queryToday() {
                liveTotals = mergedTotals(liveTotals, fresh)
            }
        }

        if PedometerService.isAvailable {
            pedometer.startUpdates { [weak self] totals in
                guard let self else { return }
                self.liveTotals = self.mergedTotals(self.liveTotals, totals)
                self.rebuildLiveDay()
            }
        }

        if !usingSample {
            applyLiveDay()
        }
        flushToDisk()

        _ = await health.requestReadAccess()
        if let healthTotals = await health.todayTotals() {
            liveTotals = mergedTotals(liveTotals, healthTotals)
        }
        let freshTimeline = await health.todayStepTimeline()
        if !freshTimeline.isEmpty {
            healthTimeline = freshTimeline
        }
        if !usingSample {
            applyLiveDay()
        }
        flushToDisk()
    }

    func showSampleDay() {
        usingSample = true
        let sample = SampleWalkFactory.makeDay(for: Date())
        if sample.points.isEmpty {
            day = nil
            loadState = .failed("The sample walk could not be built. Try running again from Xcode.")
            return
        }
        day = sample
        loadState = .ready
        scrubDate = nil
        flushToDisk()
    }

    func useLiveWalk() {
        scrubDate = nil
        usingSample = false
        applyLiveDay()
    }

    func retry() async {
        await load()
    }

    func flushToDisk() {
        persistTask?.cancel()
        persistNow()
    }

    func beginScrub(at date: Date) {
        scrubDate = clamped(date)
    }

    func updateScrub(at date: Date) {
        scrubDate = clamped(date)
    }

    func endScrub() {
        scrubDate = nil
    }

    private func clamped(_ date: Date) -> Date {
        guard let day else { return date }
        return min(max(date, day.startOfDay), day.points.last?.date ?? day.endOfDay)
    }

    private func rebuildLiveDay() {
        guard loadState != .loading, !usingSample else { return }
        applyLiveDay()
    }

    private func applyLiveDay() {
        let built = makeLiveDay()
        if let built, let previous = liveDay ?? day, previous.source == .live {
            liveDay = mergeLive(previous, onto: built)
        } else {
            liveDay = built
        }
        usingSample = false
        day = liveDay
        loadState = .ready
        schedulePersist()
    }

    private func mergeLive(_ previous: WalkDay, onto built: WalkDay) -> WalkDay {
        let points = built.points.count >= previous.points.count ? built.points : previous.points
        return WalkDay(
            date: built.date,
            points: points,
            average: built.average,
            stats: DayStats(
                steps: max(previous.stats.steps, built.stats.steps),
                meters: max(previous.stats.meters, built.stats.meters),
                activeSeconds: max(previous.stats.activeSeconds, built.stats.activeSeconds),
                flights: max(previous.stats.flights, built.stats.flights),
                calories: max(previous.stats.calories, built.stats.calories)
            ),
            source: .live
        )
    }

    @discardableResult
    private func restoreFromDisk() -> Bool {
        guard let snap = WalkCache.loadToday() else { return false }
        usingSample = snap.usingSample
        liveTotals = snap.totals
        healthTimeline = snap.timeline.map { ($0.date, $0.steps) }
        var fixes = snap.fixes.map(\.clLocation)
        if fixes.isEmpty {
            fixes = snap.day.points.map {
                CLLocation(
                    coordinate: $0.coordinate,
                    altitude: 0,
                    horizontalAccuracy: 10,
                    verticalAccuracy: -1,
                    timestamp: $0.date
                )
            }
        }
        location.restore(fixes)
        liveDay = snap.usingSample ? nil : snap.day
        day = snap.day
        loadState = .ready
        return true
    }

    private func mergedTotals(_ current: LiveTotals?, _ incoming: LiveTotals) -> LiveTotals {
        guard let current else { return incoming }
        return LiveTotals(
            steps: max(current.steps, incoming.steps),
            meters: max(current.meters, incoming.meters),
            floors: max(current.floors, incoming.floors),
            activeSeconds: max(current.activeSeconds, incoming.activeSeconds)
        )
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            persistNow()
        }
    }

    private func persistNow() {
        guard let day else { return }
        let start = Calendar.current.startOfDay(for: day.date)
        guard Calendar.current.isDateInToday(start) || usingSample else { return }
        let snapshot = WalkSnapshot(
            savedAt: Date(),
            dayStart: start,
            usingSample: usingSample,
            day: day,
            totals: liveTotals,
            timeline: healthTimeline.map { StepBucket(date: $0.date, steps: $0.steps) },
            fixes: location.locations.map(PersistedFix.init(location:))
        )
        WalkCache.save(snapshot)
    }

    private func makeLiveDay() -> WalkDay? {
        let start = Calendar.current.startOfDay(for: Date())
        let gps = location.locations.filter { $0.timestamp >= start }
        let totals = liveTotals
        let points = buildLivePoints(start: start, gps: gps, totals: totals, timeline: healthTimeline)
        let stats: DayStats
        if let totals {
            stats = DayStats(
                steps: totals.steps,
                meters: totals.meters > 0 ? totals.meters : (points.last?.cumulativeMeters ?? 0),
                activeSeconds: totals.activeSeconds > 0
                    ? totals.activeSeconds
                    : movingDuration(points),
                flights: totals.floors,
                calories: max(1, Int(Double(totals.steps) * 0.0465))
            )
        } else if !points.isEmpty {
            stats = DayStats(
                steps: points.last?.cumulativeSteps ?? 0,
                meters: points.last?.cumulativeMeters ?? 0,
                activeSeconds: movingDuration(points),
                flights: 0,
                calories: max(0, Int(Double(points.last?.cumulativeSteps ?? 0) * 0.0465))
            )
        } else {
            return WalkDay(
                date: start,
                points: [],
                average: SampleWalkFactory.averageCurve(for: Date()),
                stats: DayStats(steps: 0, meters: 0, activeSeconds: 0, flights: 0, calories: 0),
                source: .live
            )
        }

        return WalkDay(
            date: start,
            points: points,
            average: SampleWalkFactory.averageCurve(for: Date()),
            stats: stats,
            source: .live
        )
    }

    private func movingDuration(_ points: [TrackPoint]) -> TimeInterval {
        zip(points, points.dropFirst()).reduce(0) { sum, pair in
            pair.1.isMoving ? sum + pair.1.date.timeIntervalSince(pair.0.date) : sum
        }
    }

    private func buildLivePoints(
        start _: Date,
        gps: [CLLocation],
        totals: LiveTotals?,
        timeline: [(date: Date, steps: Double)]
    ) -> [TrackPoint] {
        if !gps.isEmpty {
            var points: [TrackPoint] = []
            var meters = 0.0
            var last = gps[0]
            let totalDistance = zip(gps, gps.dropFirst()).reduce(0.0) { $0 + $1.1.distance(from: $1.0) }
            let totalSteps = totals?.steps ?? Int(totalDistance / 0.712)

            for (index, location) in gps.enumerated() {
                if index > 0 {
                    meters += location.distance(from: last)
                }
                let progress = totalDistance > 0 ? meters / totalDistance : 0
                let moving = index == 0 || location.distance(from: last) > 4
                points.append(
                    TrackPoint(
                        id: index,
                        date: location.timestamp,
                        latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude,
                        cumulativeSteps: Int(Double(totalSteps) * progress),
                        cumulativeMeters: meters,
                        isMoving: moving
                    )
                )
                last = location
            }
            if let totals, let lastPoint = points.last, lastPoint.cumulativeSteps != totals.steps {
                points[points.count - 1] = TrackPoint(
                    id: lastPoint.id,
                    date: lastPoint.date,
                    latitude: lastPoint.latitude,
                    longitude: lastPoint.longitude,
                    cumulativeSteps: totals.steps,
                    cumulativeMeters: max(lastPoint.cumulativeMeters, totals.meters),
                    isMoving: lastPoint.isMoving
                )
            }
            return points
        }

        guard !timeline.isEmpty else { return [] }
        var cumulative = 0.0
        var points: [TrackPoint] = []
        let fallback = gps.last?.coordinate ?? CLLocationCoordinate2D(latitude: 37.76052, longitude: -122.42698)
        for (index, sample) in timeline.enumerated() {
            cumulative += sample.steps
            points.append(
                TrackPoint(
                    id: index,
                    date: sample.date,
                    latitude: fallback.latitude,
                    longitude: fallback.longitude,
                    cumulativeSteps: Int(cumulative.rounded()),
                    cumulativeMeters: cumulative * 0.712,
                    isMoving: sample.steps > 8
                )
            )
        }
        return points
    }
}

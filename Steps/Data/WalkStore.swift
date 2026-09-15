import Foundation
import CoreLocation
import Observation
import UIKit

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
    @ObservationIgnored private var midnightTask: Task<Void, Never>?
    @ObservationIgnored private var dayChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var timeChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var sessionDayStart = Calendar.current.startOfDay(for: Date())

    init() {
        _ = restoreFromDisk()
        rollToTodayIfNeeded()
        location.onChange = { [weak self] in
            self?.rebuildLiveDay()
        }
        location.start()
        listenForDayChanges()
        scheduleMidnightRollover()
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
        rollToTodayIfNeeded()
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
        startPedometerUpdates()

        await refreshTodayFromSensors(showLoadingIfEmpty: !restored)
    }

    func becameActive() {
        rollToTodayIfNeeded()
        Task { await refreshTodayFromSensors(showLoadingIfEmpty: false) }
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
        rollToTodayIfNeeded()
        guard loadState != .loading, !usingSample else { return }
        applyLiveDay()
        flushToDisk()
    }

    @discardableResult
    private func rollToTodayIfNeeded() -> Bool {
        let today = Calendar.current.startOfDay(for: Date())
        let held = day.map { Calendar.current.startOfDay(for: $0.date) } ?? sessionDayStart

        guard held != today || sessionDayStart != today else {
            location.keepOnly(from: today)
            pruneTimeline(to: today)
            return false
        }

        if let day, !usingSample, Calendar.current.startOfDay(for: day.date) < today {
            persistNow()
        }

        sessionDayStart = today
        usingSample = false
        liveTotals = nil
        healthTimeline = []
        liveDay = nil
        scrubDate = nil
        location.keepOnly(from: today)
        startPedometerUpdates()
        applyLiveDay()
        flushToDisk()
        scheduleMidnightRollover()
        return true
    }

    private func applyLiveDay() {
        let today = Calendar.current.startOfDay(for: Date())
        let built = makeLiveDay()
        if let built,
           let previous = liveDay ?? day,
           previous.source == .live,
           Calendar.current.isDate(previous.date, inSameDayAs: today)
        {
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
        guard Calendar.current.isDate(previous.date, inSameDayAs: built.date) else {
            return built
        }
        let points = built.points.count >= previous.points.count ? built.points : previous.points
        let todayPoints = points.filter { Calendar.current.isDate($0.date, inSameDayAs: built.date) }
        let cap = max(0, Date().timeIntervalSince(Calendar.current.startOfDay(for: built.date)))
        return WalkDay(
            date: built.date,
            points: todayPoints.isEmpty ? built.points : todayPoints,
            average: built.average,
            stats: DayStats(
                steps: max(previous.stats.steps, built.stats.steps),
                meters: max(previous.stats.meters, built.stats.meters),
                activeSeconds: min(max(previous.stats.activeSeconds, built.stats.activeSeconds), cap),
                flights: max(previous.stats.flights, built.stats.flights),
                calories: max(previous.stats.calories, built.stats.calories)
            ),
            source: .live
        )
    }

    @discardableResult
    private func restoreFromDisk() -> Bool {
        let today = Calendar.current.startOfDay(for: Date())
        guard let snap = WalkCache.loadToday() else { return false }
        guard Calendar.current.isDate(snap.dayStart, inSameDayAs: today) else { return false }
        usingSample = snap.usingSample
        liveTotals = snap.totals.map(clampedToToday)
        healthTimeline = snap.timeline
            .filter { Calendar.current.isDate($0.date, inSameDayAs: today) }
            .map { ($0.date, $0.steps) }
        var fixes = snap.fixes.map(\.clLocation).filter { $0.timestamp >= today }
        if fixes.isEmpty {
            fixes = snap.day.points
                .filter { Calendar.current.isDate($0.date, inSameDayAs: today) }
                .map {
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
        if snap.usingSample || !Calendar.current.isDate(snap.day.date, inSameDayAs: today) {
            liveDay = nil
            day = snap.usingSample ? snap.day : nil
        } else {
            liveDay = snap.day
            day = snap.day
        }
        sessionDayStart = today
        let elapsed = Date().timeIntervalSince(today)
        let leakedDuration = (snap.totals?.activeSeconds ?? snap.day.stats.activeSeconds) > elapsed + 90
        let foreignCount = snap.day.points.filter { !Calendar.current.isDate($0.date, inSameDayAs: today) }.count
        let leakedPoints = !snap.day.points.isEmpty && foreignCount * 2 >= snap.day.points.count
        if !snap.usingSample, leakedDuration || leakedPoints {
            liveTotals = nil
            healthTimeline = []
            liveDay = nil
            day = nil
            location.keepOnly(from: today)
            return false
        }
        if day != nil {
            loadState = .ready
            return true
        }
        return false
    }

    private func mergedTotals(_ current: LiveTotals?, _ incoming: LiveTotals) -> LiveTotals {
        let incoming = clampedToToday(incoming)
        guard let current else { return incoming }
        return LiveTotals(
            steps: max(current.steps, incoming.steps),
            meters: max(current.meters, incoming.meters),
            floors: max(current.floors, incoming.floors),
            activeSeconds: max(current.activeSeconds, incoming.activeSeconds)
        )
    }

    private func clampedToToday(_ totals: LiveTotals) -> LiveTotals {
        let start = Calendar.current.startOfDay(for: Date())
        let cap = max(0, Date().timeIntervalSince(start))
        return LiveTotals(
            steps: totals.steps,
            meters: totals.meters,
            floors: totals.floors,
            activeSeconds: min(max(0, totals.activeSeconds), cap)
        )
    }

    private func pruneTimeline(to start: Date) {
        healthTimeline.removeAll { $0.date < start }
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
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "steps.persist") {
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        let snapshot = WalkSnapshot(
            savedAt: Date(),
            dayStart: start,
            usingSample: usingSample && Calendar.current.isDateInToday(start),
            day: day,
            totals: Calendar.current.isDateInToday(start) ? liveTotals : nil,
            timeline: healthTimeline
                .filter { Calendar.current.isDate($0.date, inSameDayAs: start) }
                .map { StepBucket(date: $0.date, steps: $0.steps) },
            fixes: location.locations
                .filter { Calendar.current.isDate($0.timestamp, inSameDayAs: start) }
                .map(PersistedFix.init(location:))
        )
        WalkCache.save(snapshot)
        if task != .invalid {
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    private func makeLiveDay() -> WalkDay? {
        let start = Calendar.current.startOfDay(for: Date())
        let gps = location.locations.filter { $0.timestamp >= start }
        let totals = liveTotals.map(clampedToToday)
        let timeline = healthTimeline.filter { $0.date >= start }
        let points = buildLivePoints(start: start, gps: gps, totals: totals, timeline: timeline)
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

    private func startPedometerUpdates() {
        let start = Calendar.current.startOfDay(for: Date())
        pedometer.restartUpdates(from: start) { [weak self] totals in
            guard let self else { return }
            self.rollToTodayIfNeeded()
            guard Calendar.current.isDateInToday(Date()) else { return }
            self.liveTotals = self.mergedTotals(self.liveTotals, totals)
            self.rebuildLiveDay()
        }
    }

    private func refreshTodayFromSensors(showLoadingIfEmpty: Bool) async {
        rollToTodayIfNeeded()
        let start = Calendar.current.startOfDay(for: Date())

        if PedometerService.isAvailable {
            if let fresh = await pedometer.query(from: start, to: Date()) {
                liveTotals = mergedTotals(liveTotals, fresh)
            }
        }

        if !usingSample {
            applyLiveDay()
        }
        flushToDisk()

        _ = await health.requestReadAccess()
        if let healthTotals = await health.totals(from: start, to: Date()) {
            liveTotals = mergedTotals(liveTotals, healthTotals)
        }
        let freshTimeline = await health.stepTimeline(from: start, to: Date())
        if !freshTimeline.isEmpty {
            healthTimeline = freshTimeline.filter { $0.date >= start }
        }
        if !usingSample {
            applyLiveDay()
        } else if showLoadingIfEmpty, day == nil {
            loadState = .empty
        }
        flushToDisk()
    }

    private func listenForDayChanges() {
        dayChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rollToTodayIfNeeded()
                await self?.refreshTodayFromSensors(showLoadingIfEmpty: false)
            }
        }
        timeChangeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.significantTimeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rollToTodayIfNeeded()
                await self?.refreshTodayFromSensors(showLoadingIfEmpty: false)
            }
        }
    }

    private func scheduleMidnightRollover() {
        midnightTask?.cancel()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let nextMidnight = calendar.date(byAdding: .day, value: 1, to: today) else { return }
        let delay = max(nextMidnight.timeIntervalSinceNow, 1)
        midnightTask = Task { @MainActor in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            rollToTodayIfNeeded()
            await refreshTodayFromSensors(showLoadingIfEmpty: false)
            scheduleMidnightRollover()
        }
    }
}

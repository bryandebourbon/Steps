import Foundation
import Observation
import UIKit
import WidgetKit

@MainActor
@Observable
final class WalkStore {
    var loadState: LoadState = .loading
    var day: WalkDay?
    var scrubDate: Date?
    var usingSample = false

    @ObservationIgnored private let pedometer = PedometerService()
    @ObservationIgnored private var liveTotals: LiveTotals?
    @ObservationIgnored private var healthTimeline: [(date: Date, steps: Double)] = []
    @ObservationIgnored private var liveDay: WalkDay?
    @ObservationIgnored private var weeklyAverage: [AverageSample] = []
    @ObservationIgnored private var weeklyAverageDay: Date?
    @ObservationIgnored private var weeklyTask: Task<Void, Never>?

    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private var midnightTask: Task<Void, Never>?
    @ObservationIgnored private var dayChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var timeChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var sessionDayStart = Calendar.current.startOfDay(for: Date())
    @ObservationIgnored private var lastWidgetReload = Date.distantPast

    init() {
        _ = restoreFromDisk()
        rollToTodayIfNeeded()
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
        startPedometerUpdates()
        applyLiveDay()
        flushToDisk()
        scheduleMidnightRollover()
        return true
    }

    private func applyLiveDay() {
        liveDay = makeLiveDay()
        usingSample = false
        day = liveDay
        loadState = .ready
        schedulePersist()
    }

    @discardableResult
    private func restoreFromDisk() -> Bool {
        let today = Calendar.current.startOfDay(for: Date())
        guard let snap = WalkCache.loadToday() else { return false }
        guard Calendar.current.isDate(snap.dayStart, inSameDayAs: today) else { return false }
        // Live totals used to include every phone on the iCloud Health account.
        // Leave that cache unread so this phone shows only its own pedometer.
        guard snap.usingSample else { return false }
        usingSample = snap.usingSample
        liveTotals = snap.totals.map(clampedToToday)
        healthTimeline = snap.timeline
            .filter { Calendar.current.isDate($0.date, inSameDayAs: today) }
            .map { ($0.date, $0.steps) }
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
            return false
        }
        if day != nil {
            loadState = .ready
            return true
        }
        return false
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
            reloadWidget()
        }
    }

    private func reloadWidget(force: Bool = false) {
        let now = Date()
        if !force, now.timeIntervalSince(lastWidgetReload) < 60 { return }
        publishWidgetSnapshot()
        lastWidgetReload = now
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// The widgets read Health on their own, which lags the pedometer count on screen.
    /// Hand them the number the app is actually showing.
    private func publishWidgetSnapshot() {
        guard let day, !usingSample, Calendar.current.isDateInToday(day.date) else { return }
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suite) else { return }
        let start = Calendar.current.startOfDay(for: day.date)
        let steps = day.stats.steps
        var offsets = day.points.map { $0.date.timeIntervalSince(start) }
        var series = day.points.map(\.cumulativeSteps)
        if series.last != steps {
            offsets.append(Date().timeIntervalSince(start))
            series.append(steps)
        }
        let snapshot = WidgetSnapshot(
            dayStart: start,
            steps: steps,
            offsets: offsets,
            stepsSeries: series
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: WidgetSnapshot.key)
        if !weeklyAverage.isEmpty {
            let average = WidgetAveragePayload(
                dayStart: start,
                offsets: weeklyAverage.map { $0.date.timeIntervalSince(start) },
                steps: weeklyAverage.map(\.steps)
            )
            if let averageData = try? JSONEncoder().encode(average) {
                defaults.set(averageData, forKey: WidgetSnapshot.averageKey)
            }
        }
        defaults.synchronize()
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
            fixes: []
        )
        WalkCache.save(snapshot)
        if task != .invalid {
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    private func makeLiveDay() -> WalkDay? {
        let start = Calendar.current.startOfDay(for: Date())
        let totals = liveTotals.map(clampedToToday)
        let timeline = healthTimeline.filter { $0.date >= start }
        let points = buildLivePoints(start: start, totals: totals, timeline: timeline)
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
                average: weeklyAverage,
                stats: DayStats(steps: 0, meters: 0, activeSeconds: 0, flights: 0, calories: 0),
                source: .live
            )
        }

        return WalkDay(
            date: start,
            points: points,
            average: weeklyAverage,
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
        start: Date,
        totals: LiveTotals?,
        timeline: [(date: Date, steps: Double)]
    ) -> [TrackPoint] {
        var points: [TrackPoint] = []
        if timeline.isEmpty {
            guard let totals, totals.steps > 0 else { return [] }
            points = [
                TrackPoint(
                    id: 0,
                    date: start,
                    latitude: 0,
                    longitude: 0,
                    cumulativeSteps: 0,
                    cumulativeMeters: 0,
                    isMoving: false
                ),
                TrackPoint(
                    id: 1,
                    date: Date(),
                    latitude: 0,
                    longitude: 0,
                    cumulativeSteps: totals.steps,
                    cumulativeMeters: totals.meters,
                    isMoving: true
                )
            ]
            return points
        }

        var cumulative = 0.0
        for (index, sample) in timeline.enumerated() {
            cumulative += sample.steps
            points.append(
                TrackPoint(
                    id: index,
                    date: sample.date,
                    latitude: 0,
                    longitude: 0,
                    cumulativeSteps: Int(cumulative.rounded()),
                    cumulativeMeters: cumulative * 0.712,
                    isMoving: sample.steps > 8
                )
            )
        }

        guard let totals, let lastPoint = points.last, lastPoint.cumulativeSteps < totals.steps else {
            return points
        }
        let meters = max(lastPoint.cumulativeMeters, totals.meters)
        if Date().timeIntervalSince(lastPoint.date) > 60 {
            points.append(
                TrackPoint(
                    id: points.count,
                    date: Date(),
                    latitude: 0,
                    longitude: 0,
                    cumulativeSteps: totals.steps,
                    cumulativeMeters: meters,
                    isMoving: true
                )
            )
        } else {
            points[points.count - 1] = TrackPoint(
                id: lastPoint.id,
                date: lastPoint.date,
                latitude: 0,
                longitude: 0,
                cumulativeSteps: totals.steps,
                cumulativeMeters: meters,
                isMoving: lastPoint.isMoving
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
            self.liveTotals = totals
            self.rebuildLiveDay()
        }
    }

    private func refreshTodayFromSensors(showLoadingIfEmpty: Bool) async {
        rollToTodayIfNeeded()
        let start = Calendar.current.startOfDay(for: Date())
        loadCachedWeeklyAverage(start)

        if PedometerService.isAvailable {
            if let fresh = await pedometer.query(from: start, to: Date()) {
                liveTotals = fresh
            }
            if !usingSample {
                applyLiveDay()
            }
            let buckets = await pedometer.stepBuckets(from: start, to: Date())
            if !buckets.isEmpty {
                healthTimeline = buckets
            }
        }
        if !usingSample {
            applyLiveDay()
        } else if showLoadingIfEmpty, day == nil {
            loadState = .empty
        }
        flushToDisk()
        reloadWidget(force: true)
        scheduleWeeklyAverage(for: start)
    }

    private func loadCachedWeeklyAverage(_ start: Date) {
        guard weeklyAverageDay != start else { return }
        guard let cached = WeeklyAverageCache.load(for: start) else { return }
        weeklyAverage = cached
        weeklyAverageDay = start
    }

    private func scheduleWeeklyAverage(for start: Date) {
        guard weeklyAverageDay != start else { return }
        guard weeklyTask == nil else { return }
        weeklyTask = Task { [weak self] in
            let curve = await PedometerService.weeklyAverageCurve(before: start)
            guard let self else { return }
            self.weeklyTask = nil
            guard Calendar.current.isDate(start, inSameDayAs: Date()) else { return }
            self.weeklyAverage = curve
            self.weeklyAverageDay = start
            WeeklyAverageCache.save(dayStart: start, samples: curve)
            if !self.usingSample {
                self.applyLiveDay()
            }
            self.reloadWidget(force: true)
        }
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

struct WidgetSnapshot: Codable {
    static let suite = "group.com.bryandebourbon.steps"
    static let key = "steps.widget.published"
    static let averageKey = "steps.widget.average"

    var dayStart: Date
    var steps: Int
    var offsets: [TimeInterval]
    var stepsSeries: [Int]
}

private struct WidgetAveragePayload: Codable {
    var dayStart: Date
    var offsets: [TimeInterval]
    var steps: [Int]
}

private enum WeeklyAverageCache {
    private struct Stored: Codable {
        var dayStart: Date
        var offsets: [TimeInterval]
        var steps: [Int]
    }

    private static let key = "steps.weeklyAverage"

    static func load(for dayStart: Date) -> [AverageSample]? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              Calendar.current.isDate(stored.dayStart, inSameDayAs: dayStart),
              stored.offsets.count == stored.steps.count,
              stored.steps.contains(where: { $0 > 0 }) else { return nil }
        return zip(stored.offsets, stored.steps).enumerated().map { index, pair in
            AverageSample(id: index, date: dayStart.addingTimeInterval(pair.0), steps: pair.1)
        }
    }

    static func save(dayStart: Date, samples: [AverageSample]) {
        let stored = Stored(
            dayStart: dayStart,
            offsets: samples.map { $0.date.timeIntervalSince(dayStart) },
            steps: samples.map(\.steps)
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

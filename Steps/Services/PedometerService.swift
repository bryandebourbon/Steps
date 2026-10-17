import Foundation
import CoreMotion

struct LiveTotals: Equatable, Codable {
    var steps: Int
    var meters: Double
    var floors: Int
    var activeSeconds: TimeInterval
}

@MainActor
final class PedometerService {
    private let pedometer = CMPedometer()
    private var updatesStarted = false
    private var updatesFrom: Date?

    static var isAvailable: Bool {
        CMPedometer.isStepCountingAvailable()
    }

    func queryToday() async -> LiveTotals? {
        let start = Calendar.current.startOfDay(for: Date())
        return await query(from: start, to: Date())
    }

    func query(from start: Date, to end: Date) async -> LiveTotals? {
        guard Self.isAvailable else { return nil }
        return await withCheckedContinuation { continuation in
            pedometer.queryPedometerData(from: start, to: end) { data, _ in
                continuation.resume(returning: data.flatMap { Self.totals(from: $0, dayStart: start) })
            }
        }
    }

    /// Steps sensed by this phone only, in 15-minute slices. HealthKit totals include every phone on the iCloud account.
    func stepBuckets(from start: Date, to end: Date) async -> [(date: Date, steps: Double)] {
        let width: TimeInterval = 15 * 60
        var cursor = start
        var previous = 0
        var samples: [(date: Date, steps: Double)] = []
        while cursor < end {
            let sliceEnd = min(cursor.addingTimeInterval(width), end)
            let cumulative = await query(from: start, to: sliceEnd)?.steps ?? previous
            let delta = max(0, cumulative - previous)
            samples.append((date: sliceEnd, steps: Double(delta)))
            previous = cumulative
            cursor = sliceEnd
        }
        return samples
    }

    func startUpdates(from start: Date? = nil, handler: @escaping (LiveTotals) -> Void) {
        guard Self.isAvailable else { return }
        let dayStart = start ?? Calendar.current.startOfDay(for: Date())
        if updatesStarted, updatesFrom == dayStart { return }
        stop()
        updatesStarted = true
        updatesFrom = dayStart
        pedometer.startUpdates(from: dayStart) { data, _ in
            guard let data else { return }
            guard let totals = Self.totals(from: data, dayStart: dayStart) else { return }
            Task { @MainActor in
                handler(totals)
            }
        }
    }

    func restartUpdates(from start: Date, handler: @escaping (LiveTotals) -> Void) {
        stop()
        startUpdates(from: start, handler: handler)
    }

    func stop() {
        guard updatesStarted else { return }
        pedometer.stopUpdates()
        updatesStarted = false
        updatesFrom = nil
    }

    /// Average steps this phone had finished by each half hour, over the previous seven days.
    nonisolated static func weeklyAverageCurve(before dayStart: Date) async -> [AverageSample] {
        let calendar = Calendar.current
        let minutes = Array(stride(from: 30, through: 24 * 60, by: 30))
        var starts: [Date] = []
        for offset in 1...7 {
            if let start = calendar.date(byAdding: .day, value: -offset, to: dayStart) {
                starts.append(start)
            }
        }
        var curves: [[Int]] = []
        await withTaskGroup(of: [Int]?.self) { group in
            for start in starts {
                group.addTask {
                    await cumulativeDay(start: start, minutes: minutes)
                }
            }
            for await curve in group {
                if let curve { curves.append(curve) }
            }
        }
        var samples = [AverageSample(id: 0, date: dayStart, steps: 0)]
        guard !curves.isEmpty else { return samples }
        let count = curves.count
        for (index, minute) in minutes.enumerated() {
            let total = curves.reduce(0) { $0 + $1[index] }
            let date = dayStart.addingTimeInterval(TimeInterval(minute * 60))
            samples.append(AverageSample(id: index + 1, date: date, steps: total / count))
        }
        return samples
    }

    private nonisolated static func cumulativeDay(start: Date, minutes: [Int]) async -> [Int]? {
        let pedometer = CMPedometer()
        guard CMPedometer.isStepCountingAvailable() else { return nil }
        var totals: [Int] = []
        var previous = 0
        var any = false
        for minute in minutes {
            let end = start.addingTimeInterval(TimeInterval(minute * 60))
            if let steps = await steps(on: pedometer, from: start, to: end) {
                previous = steps
                any = true
            }
            totals.append(previous)
        }
        return any ? totals : nil
    }

    private nonisolated static func steps(on pedometer: CMPedometer, from start: Date, to end: Date) async -> Int? {
        await withCheckedContinuation { continuation in
            pedometer.queryPedometerData(from: start, to: end) { data, _ in
                guard let data, data.endDate >= start, data.startDate >= start.addingTimeInterval(-1) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: data.numberOfSteps.intValue)
            }
        }
    }

    private static func totals(from data: CMPedometerData, dayStart: Date) -> LiveTotals? {
        guard data.endDate >= dayStart else { return nil }
        if data.startDate < dayStart.addingTimeInterval(-1) { return nil }
        let cap = max(0, data.endDate.timeIntervalSince(dayStart))
        return LiveTotals(
            steps: data.numberOfSteps.intValue,
            meters: data.distance?.doubleValue ?? 0,
            floors: data.floorsAscended?.intValue ?? 0,
            activeSeconds: min(data.endDate.timeIntervalSince(data.startDate), cap)
        )
    }
}

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

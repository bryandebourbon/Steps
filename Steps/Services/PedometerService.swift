import Foundation
import CoreMotion

struct LiveTotals: Equatable {
    var steps: Int
    var meters: Double
    var floors: Int
    var activeSeconds: TimeInterval
}

@MainActor
final class PedometerService {
    private let pedometer = CMPedometer()
    private var updatesStarted = false

    static var isAvailable: Bool {
        CMPedometer.isStepCountingAvailable()
    }

    func queryToday() async -> LiveTotals? {
        guard Self.isAvailable else { return nil }
        let start = Calendar.current.startOfDay(for: Date())
        return await withCheckedContinuation { continuation in
            pedometer.queryPedometerData(from: start, to: Date()) { data, _ in
                continuation.resume(returning: data.map(Self.totals(from:)))
            }
        }
    }

    func startUpdates(handler: @escaping (LiveTotals) -> Void) {
        guard Self.isAvailable, !updatesStarted else { return }
        updatesStarted = true
        let start = Calendar.current.startOfDay(for: Date())
        pedometer.startUpdates(from: start) { data, _ in
            guard let data else { return }
            Task { @MainActor in
                handler(Self.totals(from: data))
            }
        }
    }

    func stop() {
        guard updatesStarted else { return }
        pedometer.stopUpdates()
        updatesStarted = false
    }

    private static func totals(from data: CMPedometerData) -> LiveTotals {
        LiveTotals(
            steps: data.numberOfSteps.intValue,
            meters: data.distance?.doubleValue ?? 0,
            floors: data.floorsAscended?.intValue ?? 0,
            activeSeconds: data.endDate.timeIntervalSince(data.startDate)
        )
    }
}

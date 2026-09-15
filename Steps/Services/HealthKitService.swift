import Foundation
import HealthKit

@MainActor
final class HealthKitService {
    private let store = HKHealthStore()

    static var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func requestReadAccess() async -> Bool {
        guard Self.isAvailable else { return false }
        var types: Set<HKObjectType> = []
        if let steps = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            types.insert(steps)
        }
        if let distance = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) {
            types.insert(distance)
        }
        if let flights = HKQuantityType.quantityType(forIdentifier: .flightsClimbed) {
            types.insert(flights)
        }
        if let energy = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
            types.insert(energy)
        }
        if let exercise = HKQuantityType.quantityType(forIdentifier: .appleExerciseTime) {
            types.insert(exercise)
        }
        do {
            try await store.requestAuthorization(toShare: [], read: types)
            return true
        } catch {
            return false
        }
    }

    func todayTotals() async -> LiveTotals? {
        guard Self.isAvailable else { return nil }
        let start = Calendar.current.startOfDay(for: Date())
        async let steps = sum(.stepCount, unit: .count(), from: start)
        async let meters = sum(.distanceWalkingRunning, unit: .meter(), from: start)
        async let flights = sum(.flightsClimbed, unit: .count(), from: start)
        async let exercise = sum(.appleExerciseTime, unit: .minute(), from: start)
        let stepCount = Int(await steps)
        guard stepCount > 0 else { return nil }
        return LiveTotals(
            steps: stepCount,
            meters: await meters,
            floors: Int(await flights),
            activeSeconds: (await exercise) * 60
        )
    }

    func todayStepTimeline() async -> [(date: Date, steps: Double)] {
        guard let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return [] }
        let start = Calendar.current.startOfDay(for: Date())
        let interval = DateComponents(minute: 5)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: start,
                intervalComponents: interval
            )
            query.initialResultsHandler = { _, collection, _ in
                var samples: [(date: Date, steps: Double)] = []
                collection?.enumerateStatistics(from: start, to: Date()) { statistic, _ in
                    let value = statistic.sumQuantity()?.doubleValue(for: .count()) ?? 0
                    samples.append((statistic.startDate, value))
                }
                continuation.resume(returning: samples)
            }
            store.execute(query)
        }
    }

    private func sum(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, from start: Date) async -> Double {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return 0 }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, stats, _ in
                let value = stats?.sumQuantity()?.doubleValue(for: unit) ?? 0
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }
}

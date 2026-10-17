import Foundation
import WidgetKit

enum StepGoal {
    static let key = "steps.goal"
    static let suite = "group.com.bryandebourbon.steps"
    static let fallback = 20_000

    static func load() -> Int {
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        guard defaults.object(forKey: key) != nil else { return fallback }
        return sanitize(defaults.integer(forKey: key))
    }

    @discardableResult
    static func save(_ raw: Int) -> Int {
        let value = sanitize(raw)
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.set(value, forKey: key)
        defaults.synchronize()
        WidgetCenter.shared.reloadAllTimelines()
        return value
    }

    static func sanitize(_ raw: Int) -> Int {
        min(max(raw, 500), 200_000)
    }

    static func axisMark(_ value: Int) -> String {
        if value <= 0 { return "0" }
        if value % 1_000 == 0 { return "\(value / 1_000)K" }
        if value % 100 == 0 {
            return "\(value / 1_000).\((value % 1_000) / 100)K"
        }
        return label(value)
    }

    static func label(_ goal: Int) -> String {
        if goal >= 1_000, goal % 1_000 == 0 {
            return "\(goal / 1_000)K"
        }
        if goal >= 10_000 {
            let fraction = goal % 1_000 == 0 ? 0 : 1
            return goal.formatted(.number.notation(.compactName).precision(.fractionLength(fraction)))
        }
        return goal.formatted(.number.grouping(.automatic))
    }
}

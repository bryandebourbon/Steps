import SwiftUI

enum Palette {
    static let skyTop = Color(red: 0.55, green: 0.64, blue: 0.84)
    static let skyBottom = Color(red: 0.33, green: 0.41, blue: 0.66)
    static let ink = Color.white
    static let inkMuted = Color.white.opacity(0.62)
    static let card = Color(red: 0.09, green: 0.09, blue: 0.10)
    static let actual = Color(red: 0.55, green: 0.68, blue: 0.98)
    static let average = Color.white.opacity(0.48)
    static let behind = Color(red: 1.0, green: 0.36, blue: 0.36)
    static let ahead = Color(red: 0.22, green: 0.84, blue: 0.45)
    static let path = Color(red: 0.45, green: 0.62, blue: 1.0)
    static let pathRest = Color(red: 0.45, green: 0.62, blue: 1.0).opacity(0.28)
    static let marker = Color(red: 0.38, green: 0.56, blue: 1.0)
}

enum Formatters {
    static let dayHeader: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter
    }()

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    static let axisTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        return formatter
    }()

    static func steps(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    static func distance(meters: Double) -> String {
        let measurement = Measurement(value: meters, unit: UnitLength.meters)
        return measurement.formatted(
            .measurement(
                width: .abbreviated,
                usage: .road,
                numberFormatStyle: .number.precision(.fractionLength(0...2))
            )
        )
    }

    static func activeTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    static func calories(_ value: Int) -> String {
        "\(value.formatted(.number.grouping(.automatic))) cal"
    }

    static func flights(_ value: Int) -> String {
        value == 1 ? "1 flight" : "\(value) flights"
    }

    static func percentVsAverage(actual: Int, average: Int) -> (text: String, isBehind: Bool) {
        guard average > 0 else { return ("On pace with average", false) }
        let delta = Double(actual - average) / Double(average)
        let percent = Int((delta * 100).rounded())
        if percent == 0 {
            return ("Even with average", false)
        }
        let signed = percent > 0 ? "+\(percent)%" : "\(percent)%"
        return ("\(signed) vs. average", percent < 0)
    }
}

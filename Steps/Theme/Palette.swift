import SwiftUI

enum Palette {
    static let ink = Color.white
    static let inkMuted = Color.white.opacity(0.55)
    static let card = Color.black
    static let actual = Color.white
    static let average = Color.white.opacity(0.32)
    static let behind = Color.white.opacity(0.72)
    static let ahead = Color.white

    static func friendColor(_ index: Int) -> Color {
        let colors = [
            Color(red: 0.35, green: 0.78, blue: 1),
            Color(red: 1, green: 0.62, blue: 0.28),
            Color(red: 0.78, green: 0.56, blue: 1)
        ]
        return colors[index % colors.count].opacity(0.62)
    }
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

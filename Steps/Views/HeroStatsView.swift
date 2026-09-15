import SwiftUI

struct HeroStatsView: View {
    let day: WalkDay
    let focus: TrackPoint?
    var compact = false

    var body: some View {
        Group {
            if compact {
                compactBody
            } else {
                fullBody
            }
        }
        .animation(.snappy(duration: 0.15), value: focus?.id)
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Formatters.steps(focus?.cumulativeSteps ?? day.stats.steps))
                    .font(.system(size: 44, weight: .light, design: .rounded))
                    .foregroundStyle(Palette.ink)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                Text("STEPS")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Palette.inkMuted)
            }

            HStack(spacing: 0) {
                CompactStat(
                    label: "DISTANCE",
                    value: Formatters.distance(meters: focus?.cumulativeMeters ?? day.stats.meters)
                )
                CompactStat(
                    label: "TIME",
                    value: Formatters.activeTime(
                        focus == nil ? day.stats.activeSeconds : day.activeSeconds(upTo: focus)
                    )
                )
                CompactStat(label: "FLIGHTS", value: Formatters.flights(day.stats.flights))
                CompactStat(label: "CAL", value: Formatters.calories(day.stats.calories))
            }
        }
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Formatters.steps(focus?.cumulativeSteps ?? day.stats.steps))
                    .font(.system(size: 64, weight: .light, design: .rounded))
                    .foregroundStyle(Palette.ink)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                Text("STEPS")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Palette.inkMuted)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                StatBlock(
                    label: "DISTANCE",
                    value: Formatters.distance(meters: focus?.cumulativeMeters ?? day.stats.meters)
                )
                StatBlock(
                    label: "ACTIVE TIME",
                    value: Formatters.activeTime(
                        focus == nil ? day.stats.activeSeconds : day.activeSeconds(upTo: focus)
                    )
                )
                StatBlock(label: "FLIGHTS", value: Formatters.flights(day.stats.flights))
                StatBlock(label: "CALORIES", value: Formatters.calories(day.stats.calories))
            }
        }
    }
}

private struct CompactStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Palette.inkMuted)
            Text(value)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Palette.ink)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StatBlock: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Palette.inkMuted)
            Text(value)
                .font(.system(size: 28, weight: .regular, design: .rounded))
                .foregroundStyle(Palette.ink)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

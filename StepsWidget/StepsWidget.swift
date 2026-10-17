import Charts
import SwiftUI
import UIKit
import WidgetKit

private struct StepSample: Identifiable {
    let id: Int
    let date: Date
    let steps: Int
}

private struct WidgetFriend: Identifiable {
    let id: Int
    var name: String
    var colorIndex: Int
    var points: [StepSample]

    var steps: Int { points.last?.steps ?? 0 }

    static func color(_ index: Int) -> Color {
        let colors = [
            Color(red: 0.35, green: 0.78, blue: 1),
            Color(red: 1, green: 0.62, blue: 0.28),
            Color(red: 0.78, green: 0.56, blue: 1),
            Color(red: 0.45, green: 0.9, blue: 0.55),
            Color(red: 1, green: 0.45, blue: 0.62)
        ]
        return colors[index % colors.count]
    }
}

private struct StepsEntry: TimelineEntry {
    var date: Date
    var steps: Int
    var points: [StepSample]
    var average: [StepSample]
    var friends: [WidgetFriend] = []
    var goal: Int = 20_000
    var userName: String = ""
    var needsHealthAccess: Bool

    var dayStart: Date {
        Calendar.current.startOfDay(for: date)
    }

    var dayEnd: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? date
    }
}

private struct StepsProvider: TimelineProvider {
    func placeholder(in context: Context) -> StepsEntry {
        StepsEntry.preview
    }

    func getSnapshot(in context: Context, completion: @escaping (StepsEntry) -> Void) {
        if context.isPreview {
            completion(.preview)
            return
        }
        Task {
            completion(await StepsLoader.load())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StepsEntry>) -> Void) {
        Task {
            let base = await StepsLoader.load()
            let now = Date()
            let entries = (0..<60).map { minute in
                var entry = base
                entry.date = now.addingTimeInterval(Double(minute) * 60)
                return entry
            }
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(60 * 60))))
        }
    }
}

struct StepsChartWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: StepsChartWidget.kind, provider: StepsProvider()) { entry in
            StepsChartWidgetView(entry: entry)
        }
        .configurationDisplayName("Steps")
        .description("Today’s steps, with friends behind your line.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge, .systemExtraLarge,
            .accessoryCircular, .accessoryInline
        ])
        .contentMarginsDisabled()
    }

    static let kind = "StepsChart"
}

private struct StepsChartWidgetView: View {
    var entry: StepsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            inlineLabel
                .containerBackground(.clear, for: .widget)
        case .accessoryCircular:
            circularGauge
                .containerBackground(for: .widget) {
                    AccessoryWidgetBackground()
                }
        default:
            homeGraph
                .containerBackground(Color.black, for: .widget)
        }
    }

    private var inlineLabel: some View {
        Text(entry.needsHealthAccess ? "Open Steps" : "\(entry.steps.formatted(.number.grouping(.automatic))) steps")
    }

    private var circularGauge: some View {
        Gauge(value: min(Double(entry.steps), Double(entry.goal)), in: 0...Double(entry.goal)) {
            Text("Steps")
        } currentValueLabel: {
            Text(compactCount)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .gaugeStyle(.accessoryCircularCapacity)
    }

    private var compactCount: String {
        if entry.needsHealthAccess { return "—" }
        if entry.steps >= 1_000 {
            return entry.steps.formatted(.number.notation(.compactName).precision(.fractionLength(entry.steps >= 10_000 ? 1 : 0)))
        }
        return entry.steps.formatted()
    }

    private var homeGraph: some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height * 1.25
            let pad = max(10, min(geo.size.width, geo.size.height) * 0.07)
            Group {
                if wide {
                    HStack(alignment: .center, spacing: pad) {
                        summary(in: geo.size, stacked: false)
                            .frame(width: min(geo.size.width * 0.36, 180))
                        graph(in: geo.size)
                    }
                } else {
                    VStack(alignment: .leading, spacing: pad * 0.45) {
                        summary(in: geo.size, stacked: true)
                        graph(in: geo.size)
                    }
                }
            }
            .padding(pad)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func summary(in size: CGSize, stacked: Bool) -> some View {
        let numberSize = min(stacked ? 44 : 36, size.height * (stacked ? 0.2 : 0.28))
        VStack(alignment: stacked ? .leading : .center, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(entry.steps.formatted(.number.grouping(.automatic)))
                    .font(.system(size: max(22, numberSize), weight: .thin, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.35)
                    .lineLimit(1)
                Text("steps")
                    .font(.system(size: max(12, numberSize * 0.34), weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(1)
                    .fixedSize()
            }
            if entry.needsHealthAccess {
                Text("Open Steps")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, alignment: stacked ? .leading : .center)
    }

    private func graph(in size: CGSize) -> some View {
        let showCeiling = size.height > 120
        let now = min(max(entry.date, entry.dayStart), entry.dayEnd.addingTimeInterval(-60))
        return Chart {
            ForEach(Array(entry.friends.enumerated()), id: \.element.id) { index, friend in
                ForEach(friend.points) { sample in
                    LineMark(
                        x: .value("Time", sample.date),
                        y: .value("Steps", sample.steps),
                        series: .value("Series", "Friend-\(index)")
                    )
                    .foregroundStyle(by: .value("Series", "Friend-\(index)"))
                    .interpolationMethod(.stepEnd)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
            }
            ForEach(entry.average) { sample in
                LineMark(
                    x: .value("Time", sample.date),
                    y: .value("Average", sample.steps),
                    series: .value("Series", "Average")
                )
                .foregroundStyle(by: .value("Series", "Average"))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(entry.points) { sample in
                LineMark(
                    x: .value("Time", sample.date),
                    y: .value("Steps", sample.steps),
                    series: .value("Series", "Today")
                )
                .foregroundStyle(by: .value("Series", "Today"))
                .interpolationMethod(.stepEnd)
                .lineStyle(StrokeStyle(lineWidth: max(2, size.width / 140), lineCap: .round, lineJoin: .round))
            }
            RuleMark(x: .value("Now", now))
                .foregroundStyle(Color.white.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 1.25))
        }
        .chartXScale(domain: entry.dayStart...entry.dayEnd)
        .chartYScale(domain: 0...goalCeiling)
        .chartLegend(.hidden)
        .chartForegroundStyleScale([
            "Today": Color.white,
            "Average": Color.white.opacity(0.32),
            "Friend-0": WidgetFriend.color(0),
            "Friend-1": WidgetFriend.color(1),
            "Friend-2": WidgetFriend.color(2),
            "Friend-3": WidgetFriend.color(3),
            "Friend-4": WidgetFriend.color(4)
        ])
        .chartXAxis {
            AxisMarks(values: [now]) { value in
                AxisValueLabel(anchor: .top) {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(.dateTime.hour().minute()))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.7))
                    }
                }
            }
        }
        .chartYAxis {
            if showCeiling {
                AxisMarks(position: .trailing, values: goalMarks) { value in
                    if value.as(Int.self) == entry.goal {
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6, dash: [4, 4]))
                            .foregroundStyle(Color.white.opacity(0.2))
                    }
                    AxisValueLabel {
                        if let mark = value.as(Int.self) {
                            Text(WidgetGoal.axisMark(mark))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.45))
                        }
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot.background(Color.clear)
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                if let plotAnchor = proxy.plotFrame {
                    let plot = geo[plotAnchor]
                    let fontSize: CGFloat = size.width < 180 ? 10 : 12
                    let trailing = geo.size.width - 2
                    ForEach(Array(entry.friends.enumerated()), id: \.element.id) { index, friend in
                        if let sample = friend.points.last, !friend.name.isEmpty,
                           let plotPoint = proxy.position(for: (x: sample.date, y: sample.steps)) {
                            let x = plot.minX + plotPoint.x
                            let y = plot.minY + plotPoint.y
                            let placed = FriendPlotLabel.placement(name: friend.name, fontSize: fontSize, x: x, leading: plot.minX, trailing: trailing)
                            FriendPlotLabel(
                                name: friend.name,
                                color: WidgetFriend.color(index),
                                onRight: placed.onRight,
                                width: placed.width,
                                fontSize: fontSize
                            )
                            .position(
                                x: placed.onRight ? x + placed.width / 2 : x - placed.width / 2,
                                y: y
                            )
                        }
                    }
                    if !entry.userName.isEmpty, let sample = entry.points.last,
                       let plotPoint = proxy.position(for: (x: sample.date, y: sample.steps)) {
                        let x = plot.minX + plotPoint.x
                        let y = plot.minY + plotPoint.y
                        let placed = FriendPlotLabel.placement(name: entry.userName, fontSize: fontSize, x: x, leading: plot.minX, trailing: trailing)
                        FriendPlotLabel(
                            name: entry.userName,
                            color: .white,
                            onRight: placed.onRight,
                            width: placed.width,
                            fontSize: fontSize,
                            shadowed: true
                        )
                        .zIndex(1)
                        .position(
                            x: placed.onRight ? x + placed.width / 2 : x - placed.width / 2,
                            y: y
                        )
                    }
                }
            }
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var goalMarks: [Int] {
        let quarter = max(entry.goal / 4, 1)
        return [0, quarter, quarter * 2, quarter * 3, entry.goal]
    }

    private var goalCeiling: Double {
        let friendPeak = entry.friends.flatMap(\.points).map(\.steps).max() ?? 0
        let mine = entry.points.map(\.steps).max() ?? entry.steps
        let typical = entry.average.map(\.steps).max() ?? 0
        let peak = max(entry.goal, mine, friendPeak, typical)
        if peak <= entry.goal { return Double(entry.goal) }
        return Double(peak) * 1.08
    }

}

private struct FriendPlotLabel: View {
    var name: String
    var color: Color
    var onRight: Bool
    var width: CGFloat
    var fontSize: CGFloat = 12
    var shadowed: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if onRight {
                dash
                nameText
            } else {
                nameText
                dash
            }
        }
        .frame(width: width, alignment: onRight ? .leading : .trailing)
        .shadow(color: shadowed ? .black.opacity(0.95) : .clear, radius: shadowed ? 2 : 0)
        .shadow(color: shadowed ? .black.opacity(0.85) : .clear, radius: shadowed ? 5 : 0)
    }

    private var dash: some View {
        Capsule()
            .fill(color)
            .frame(width: 12, height: 2)
    }

    private var nameText: some View {
        Text(name)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    static func placement(name: String, fontSize: CGFloat, x: CGFloat, leading: CGFloat, trailing: CGFloat) -> (onRight: Bool, width: CGFloat) {
        let natural = naturalWidth(name: name, fontSize: fontSize)
        if natural <= trailing - x {
            return (true, natural)
        }
        let left = max(x - leading, 28)
        return (false, min(natural, left))
    }

    static func naturalWidth(name: String, fontSize: CGFloat) -> CGFloat {
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let text = ceil((name as NSString).size(withAttributes: [.font: font]).width)
        return text + 18
    }

    static func width(name: String, fontSize: CGFloat, room: CGFloat) -> CGFloat {
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let text = ceil((name as NSString).size(withAttributes: [.font: font]).width)
        return min(text + 18, max(room - 6, 28))
    }
}

@main
struct StepsWidgetBundle: WidgetBundle {
    var body: some Widget {
        StepsChartWidget()
    }
}

private enum AverageDay {
    static func steps(at date: Date, start: Date) -> Int {
        let hour = date.timeIntervalSince(start) / 3600
        let steps: Double
        switch hour {
        case ..<6:
            steps = 80 * hour
        case 6..<9:
            steps = 480 + (hour - 6) * 720
        case 9..<12:
            steps = 2_640 + (hour - 9) * 620
        case 12..<18:
            steps = 4_500 + (hour - 12) * 1_080
        default:
            steps = 10_980 + (hour - 18) * 1_420
        }
        return Int(max(0, steps).rounded())
    }

    static func curve(start: Date) -> [StepSample] {
        (0...48).map { index in
            let date = start.addingTimeInterval(Double(index) * 30 * 60)
            return StepSample(id: index, date: date, steps: steps(at: date, start: start))
        }
    }
}

private enum StepsLoader {
    static func load() async -> StepsEntry {
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        if let published = WidgetSnapshot.load(today: start) {
            CurveCache.save(dayStart: start, steps: published.steps, points: published.points)
            let friends = WidgetFriends.load(today: start)
            return entry(now: now, start: start, steps: published.steps, points: published.points, friends: friends, goal: WidgetGoal.load(), userName: WidgetGoal.name(), average: WidgetAverage.load(today: start))
        }
        if let cached = CurveCache.load(today: start) {
            return entry(now: now, start: start, steps: cached.steps, points: cached.points, goal: WidgetGoal.load(), userName: WidgetGoal.name(), average: WidgetAverage.load(today: start))
        }
        return StepsEntry(
            date: now,
            steps: 0,
            points: [StepSample(id: 0, date: start, steps: 0), StepSample(id: 1, date: now, steps: 0)],
            average: WidgetAverage.load(today: start),
            goal: WidgetGoal.load(),
            userName: WidgetGoal.name(),
            needsHealthAccess: true
        )
    }

    private static func entry(
        now: Date,
        start: Date,
        steps: Int,
        points: [StepSample],
        friends: [WidgetFriend] = [],
        goal: Int = 20_000,
        userName: String = "",
        average: [StepSample] = []
    ) -> StepsEntry {
        StepsEntry(
            date: now,
            steps: steps,
            points: points,
            average: average,
            friends: friends,
            goal: goal,
            userName: userName,
            needsHealthAccess: false
        )
    }

}

private struct WidgetSnapshot: Codable {
    static let suite = "group.com.bryandebourbon.steps"
    static let key = "steps.widget.published"
    static let averageKey = "steps.widget.average"

    var dayStart: Date
    var steps: Int
    var offsets: [TimeInterval]
    var stepsSeries: [Int]

    var points: [StepSample] {
        zip(offsets, stepsSeries).enumerated().map { index, pair in
            StepSample(id: index, date: dayStart.addingTimeInterval(pair.0), steps: pair.1)
        }
    }

    static func load(today: Date) -> WidgetSnapshot? {
        guard let defaults = UserDefaults(suiteName: suite),
              let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
              Calendar.current.isDate(stored.dayStart, inSameDayAs: today),
              stored.offsets.count == stored.stepsSeries.count else { return nil }
        return stored
    }
}

private enum WidgetGoal {
    static func load() -> Int {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suite),
              defaults.object(forKey: "steps.goal") != nil else { return 20_000 }
        return min(max(defaults.integer(forKey: "steps.goal"), 500), 200_000)
    }

    static func name() -> String {
        UserDefaults(suiteName: WidgetSnapshot.suite)?.string(forKey: "steps.displayName") ?? ""
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

private enum WidgetAverage {
    private struct Stored: Codable {
        var dayStart: Date
        var offsets: [TimeInterval]
        var steps: [Int]
    }

    static func load(today: Date) -> [StepSample] {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suite),
              let data = defaults.data(forKey: WidgetSnapshot.averageKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              Calendar.current.isDate(stored.dayStart, inSameDayAs: today),
              stored.offsets.count == stored.steps.count else { return [] }
        return zip(stored.offsets, stored.steps).enumerated().map { index, pair in
            StepSample(id: index, date: today.addingTimeInterval(pair.0), steps: pair.1)
        }
    }
}

private enum WidgetFriends {
    private struct Stored: Codable {
        var name: String
        var colorIndex: Int
        var offsets: [TimeInterval]
        var steps: [Int]
    }

    static func load(today: Date) -> [WidgetFriend] {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suite) else { return [] }
        if defaults.object(forKey: "steps.widget.showFriends") != nil,
           defaults.bool(forKey: "steps.widget.showFriends") == false {
            return []
        }
        guard let data = defaults.data(forKey: "steps.widget.friends"),
              let stored = try? JSONDecoder().decode([Stored].self, from: data) else { return [] }
        return stored.enumerated().map { offset, friend in
            let points = zip(friend.offsets, friend.steps).enumerated().map { index, pair in
                StepSample(id: index, date: today.addingTimeInterval(pair.0), steps: pair.1)
            }
            return WidgetFriend(id: offset, name: friend.name, colorIndex: offset, points: points)
        }
    }
}

private enum CurveCache {
    private struct Stored: Codable {
        var dayStart: Date
        var steps: Int
        var offsets: [TimeInterval]
        var stepsSeries: [Int]
    }

    static func save(dayStart: Date, steps: Int, points: [StepSample]) {
        let stored = Stored(
            dayStart: dayStart,
            steps: steps,
            offsets: points.map { $0.date.timeIntervalSince(dayStart) },
            stepsSeries: points.map(\.steps)
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: "steps.widget.curve")
    }

    static func load(today: Date) -> (steps: Int, points: [StepSample])? {
        guard let data = UserDefaults.standard.data(forKey: "steps.widget.curve"),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              Calendar.current.isDate(stored.dayStart, inSameDayAs: today),
              stored.offsets.count == stored.stepsSeries.count else { return nil }
        let points = zip(stored.offsets, stored.stepsSeries).enumerated().map { index, pair in
            StepSample(id: index, date: today.addingTimeInterval(pair.0), steps: pair.1)
        }
        return (stored.steps, points)
    }
}

private extension StepsEntry {
    static var preview: StepsEntry {
        let start = Calendar.current.startOfDay(for: Date())
        let now = Date()
        let elapsed = now.timeIntervalSince(start)
        var points: [StepSample] = []
        let count = 24
        for index in 0...count {
            let fraction = Double(index) / Double(count)
            let date = start.addingTimeInterval(elapsed * fraction)
            let steps = Int((10_600 * fraction * fraction).rounded())
            points.append(StepSample(id: index, date: date, steps: steps))
        }
        return StepsEntry(
            date: now,
            steps: points.last?.steps ?? 0,
            points: points,
            average: AverageDay.curve(start: start),
            needsHealthAccess: false
        )
    }
}

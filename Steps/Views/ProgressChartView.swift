import SwiftUI
import Charts
import UIKit
import CoreHaptics

struct ProgressChartView: View {
    let day: WalkDay
    let scrubDate: Date?
    var celebrating: Bool = false
    var showCongratulations: Bool = false
    var burstID: Int = 0
    var friends: [FriendCurve] = []
    var goal: Int = 20_000
    var userName: String = ""
    var onBegin: (Date) -> Void
    var onChange: (Date) -> Void
    var onEnd: () -> Void

    @State private var lastTickIndex: Int?
    @State private var haptics = ChartHapticPlayer()
    @State private var banner: TenKBannerPlacement?

    private var focus: TrackPoint? {
        if let scrubDate {
            return day.point(nearestTo: scrubDate)
        }
        return day.points.last
    }

    private var averageAtFocus: Int {
        guard let focus else { return day.average.last?.steps ?? 0 }
        return day.averageSteps(at: focus.date)
    }

    private var comparison: (text: String, isBehind: Bool) {
        Formatters.percentVsAverage(
            actual: focus?.cumulativeSteps ?? day.stats.steps,
            average: averageAtFocus
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: comparison.isBehind ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                Text(comparison.text)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(comparison.isBehind ? Palette.behind : Palette.ahead)

            if !friends.isEmpty {
                HStack(spacing: 12) {
                    ForEach(friends) { friend in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Palette.friendColor(friend.colorIndex))
                                .frame(width: 7, height: 7)
                            Text("\(friend.name) \(friend.steps.formatted())")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Palette.friendColor(friend.colorIndex))
                                .lineLimit(1)
                        }
                    }
                }
            }

            chart
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Steps over time compared with your average day")

        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .coordinateSpace(name: "progressChart")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black)
        .onPreferenceChange(TenKBannerKey.self) { banner = $0 }
        .overlay {
            GeometryReader { geo in
                if showCongratulations, let banner {
                    CongratulationsBanner(
                        source: CGPoint(x: banner.sourceX, y: banner.sourceY),
                        restY: banner.restY,
                        width: geo.size.width
                    )
                    .id(burstID)
                    .allowsHitTesting(false)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(friends) { friend in
                ForEach(friend.samples) { sample in
                    LineMark(
                        x: .value("Time", sample.date),
                        y: .value("Steps", sample.steps),
                        series: .value("Series", "Friend-\(friend.id)")
                    )
                    .foregroundStyle(Palette.friendColor(friend.colorIndex))
                    .interpolationMethod(.stepEnd)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
            }

            ForEach(day.average) { sample in
                LineMark(
                    x: .value("Time", sample.date),
                    y: .value("Average steps", sample.steps),
                    series: .value("Series", "Average")
                )
                .foregroundStyle(Palette.average)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }

            ForEach(day.points) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Steps", point.cumulativeSteps),
                    series: .value("Series", "Today")
                )
                .foregroundStyle(Palette.actual)
                .interpolationMethod(.stepEnd)
                .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }

            if let focus {
                RuleMark(x: .value("Scrub", focus.date))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1))

                PointMark(
                    x: .value("Time", focus.date),
                    y: .value("Steps", focus.cumulativeSteps)
                )
                .foregroundStyle(Palette.actual)
                .symbolSize(48)

                PointMark(
                    x: .value("Time", focus.date),
                    y: .value("Average", averageAtFocus)
                )
                .foregroundStyle(Palette.average)
                .symbolSize(36)
            }
        }
        .chartXScale(domain: day.startOfDay...day.endOfDay)
        .chartYScale(domain: 0...goalCeiling)
        .chartXAxis {
            AxisMarks(values: axisTimes) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(axisLabel(for: date))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: goalMarks) { value in
                if value.as(Int.self) == goal {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6, dash: [4, 4]))
                        .foregroundStyle(Color.white.opacity(0.2))
                }
                AxisValueLabel {
                    if let mark = value.as(Int.self) {
                        Text(StepGoal.axisMark(mark))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.45))
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartPlotStyle { plot in
            plot.background(Color.clear)
        }
        .overlay(alignment: .topLeading) {
            if let focus, scrubDate != nil {
                tooltip(for: focus)
                    .padding(.leading, 8)
                    .padding(.top, 4)
                .allowsHitTesting(false)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                ZStack {
                    if celebrating, let point = tenKPlotPoint(proxy: proxy, geo: geo) {
                        TenKMarker()
                            .position(point)
                            .allowsHitTesting(false)
                    }
                    if let plotAnchor = proxy.plotFrame {
                        let plot = geo[plotAnchor]
                        if !userName.isEmpty, let point = day.points.last,
                           let plotPoint = proxy.position(for: (x: point.date, y: point.cumulativeSteps)) {
                            let x = plot.minX + plotPoint.x
                            let y = plot.minY + plotPoint.y
                            let placed = FriendPlotLabel.placement(name: userName, fontSize: 12, x: x, plot: plot)
                            FriendPlotLabel(
                                name: userName,
                                color: .white,
                                onRight: placed.onRight,
                                width: placed.width
                            )
                            .position(
                                x: placed.onRight ? x + placed.width / 2 : x - placed.width / 2,
                                y: y
                            )
                            .allowsHitTesting(false)
                        }
                        ForEach(friends) { friend in
                            if let sample = friend.samples.last, !friend.name.isEmpty,
                               let plotPoint = proxy.position(for: (x: sample.date, y: sample.steps)) {
                                let x = plot.minX + plotPoint.x
                                let y = plot.minY + plotPoint.y
                                let placed = FriendPlotLabel.placement(name: friend.name, fontSize: 12, x: x, plot: plot)
                                FriendPlotLabel(
                                    name: friend.name,
                                    color: Palette.friendColor(friend.colorIndex),
                                    onRight: placed.onRight,
                                    width: placed.width
                                )
                                .position(
                                    x: placed.onRight ? x + placed.width / 2 : x - placed.width / 2,
                                    y: y
                                )
                                .allowsHitTesting(false)
                            }
                        }
                    }
                    ScrubSurface(
                haptics: haptics,
                onPress: { x in
                    guard !day.points.isEmpty, let date = proxy.value(atX: x, as: Date.self) else { return }
                    lastTickIndex = day.point(nearestTo: date)?.id
                    onBegin(date)
                },
                onMove: { x in
                    guard !day.points.isEmpty, let date = proxy.value(atX: x, as: Date.self) else { return false }
                    onChange(date)
                    guard let point = day.point(nearestTo: date) else { return false }
                    if lastTickIndex != point.id {
                        lastTickIndex = point.id
                        return true
                    }
                    return false
                },
                onEnd: {
                    lastTickIndex = nil
                    onEnd()
                }
                    )
                }
                .preference(key: TenKOriginKey.self, value: tenKOrigin(proxy: proxy, geo: geo))
                .preference(key: TenKBannerKey.self, value: bannerCenter(proxy: proxy, geo: geo))
            }
        }
        .onAppear {
            haptics.start()
        }
    }

    private func tenKPlotPoint(proxy: ChartProxy, geo: GeometryProxy) -> CGPoint? {
        guard let crossing = day.crossing(of: TenKCelebration.threshold),
              let plotAnchor = proxy.plotFrame,
              let plotPoint = proxy.position(for: (x: crossing.date, y: crossing.steps))
        else { return nil }
        let plot = geo[plotAnchor]
        return CGPoint(x: plot.minX + plotPoint.x, y: plot.minY + plotPoint.y)
    }

    private func tenKOrigin(proxy: ChartProxy, geo: GeometryProxy) -> CGPoint? {
        guard let local = tenKPlotPoint(proxy: proxy, geo: geo) else { return nil }
        let chart = geo.frame(in: .named("stepsScreen"))
        return CGPoint(x: chart.minX + local.x, y: chart.minY + local.y)
    }

    /// The 10k mark, and the resting spot halfway up to the vs-average line.
    private func bannerCenter(proxy: ChartProxy, geo: GeometryProxy) -> TenKBannerPlacement? {
        guard let local = tenKPlotPoint(proxy: proxy, geo: geo) else { return nil }
        let chart = geo.frame(in: .named("progressChart"))
        return TenKBannerPlacement(
            sourceX: chart.minX + local.x,
            sourceY: chart.minY + local.y,
            restY: chart.minY + local.y / 2
        )
    }

    private var goalMarks: [Int] {
        let quarter = max(goal / 4, 1)
        return [0, quarter, quarter * 2, quarter * 3, goal]
    }

    /// The top of the chart is the goal, unless someone has already walked past it.
    private var goalCeiling: Double {
        let mine = day.points.map(\.cumulativeSteps).max() ?? day.stats.steps
        let theirs = friends.flatMap(\.samples).map(\.steps).max() ?? 0
        let typical = day.average.map(\.steps).max() ?? 0
        let peak = max(goal, mine, theirs, typical)
        if peak <= goal { return Double(goal) }
        return Double(peak) * 1.08
    }

    private var axisTimes: [Date] {
        let start = day.startOfDay
        let end = day.endOfDay
        let middle = focus?.date ?? start.addingTimeInterval(18 * 3600)
        return [start, middle, end]
    }

    private func axisLabel(for date: Date) -> String {
        if Calendar.current.component(.hour, from: date) == 0
            && Calendar.current.component(.minute, from: date) == 0 {
            return "12 AM"
        }
        return Formatters.time.string(from: date)
    }

    @ViewBuilder
    private func tooltip(for point: TrackPoint) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Formatters.time.string(from: point.date))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.7))
            Text("\(Formatters.steps(point.cumulativeSteps)) steps")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text(Formatters.distance(meters: point.cumulativeMeters))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.7))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial.opacity(0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

}

private struct TenKBannerPlacement: Equatable {
    var sourceX: CGFloat
    var sourceY: CGFloat
    var restY: CGFloat
}

private struct TenKBannerKey: PreferenceKey {
    static var defaultValue: TenKBannerPlacement? = nil
    static func reduce(value: inout TenKBannerPlacement?, nextValue: () -> TenKBannerPlacement?) {
        value = nextValue() ?? value
    }
}

private struct CongratulationsBanner: View {
    var source: CGPoint
    var restY: CGFloat
    var width: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false

    var body: some View {
        CongratulationsShimmer()
            .frame(width: width)
            .scaleEffect(arrived || reduceMotion ? 1 : 0.04, anchor: .center)
            .position(
                x: arrived || reduceMotion ? width / 2 : source.x,
                y: arrived || reduceMotion ? restY : source.y
            )
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.spring(response: 0.48, dampingFraction: 0.78)) {
                    arrived = true
                }
            }
    }
}

private struct CongratulationsShimmer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let font = Font.system(size: 80, weight: .bold, design: .rounded)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120.0, paused: reduceMotion)) { timeline in
            let band = shimmerBand(at: timeline.date)
            Text("Congratulations")
                .font(font)
                .minimumScaleFactor(0.15)
                .lineLimit(1)
                .foregroundStyle(
                    LinearGradient(
                        stops: shimmerStops(band: band),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
        .padding(.horizontal, 4)
    }

    private func shimmerBand(at date: Date) -> CGFloat {
        guard !reduceMotion else { return 0.5 }
        let oneWay = 0.85
        let elapsed = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: oneWay * 2) / oneWay
        let progress = elapsed <= 1 ? elapsed : 2 - elapsed
        return 0.08 + 0.84 * progress
    }

    private func shimmerStops(band: CGFloat) -> [Gradient.Stop] {
        let center = min(max(band, 0.04), 0.96)
        let start = max(0.02, center - 0.1)
        let end = min(0.98, center + 0.1)
        return [
            .init(color: Color.white.opacity(0.5), location: 0),
            .init(color: Color.white.opacity(0.5), location: start),
            .init(color: .white, location: center),
            .init(color: Color.white.opacity(0.5), location: end),
            .init(color: Color.white.opacity(0.5), location: 1)
        ]
    }
}

private struct TenKMarker: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                .frame(width: 18, height: 18)
                .scaleEffect(pulse ? 2.1 : 0.55)
                .opacity(pulse ? 0 : 0.95)
            Circle()
                .fill(Color.white)
                .frame(width: 7, height: 7)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

private struct FriendPlotLabel: View {
    var name: String
    var color: Color
    var onRight: Bool
    var width: CGFloat
    var fontSize: CGFloat = 12

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

    static func placement(name: String, fontSize: CGFloat, x: CGFloat, plot: CGRect) -> (onRight: Bool, width: CGFloat) {
        let natural = naturalWidth(name: name, fontSize: fontSize)
        let right = plot.maxX - x - 8
        if natural <= right {
            return (true, natural)
        }
        let left = max(x - plot.minX - 8, 28)
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

private struct ScrubSurface: UIViewRepresentable {
    var haptics: ChartHapticPlayer
    var onPress: (CGFloat) -> Void
    var onMove: (CGFloat) -> Bool
    var onEnd: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(haptics: haptics, onPress: onPress, onMove: onMove, onEnd: onEnd)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = false
        let press = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:))
        )
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        press.cancelsTouchesInView = false
        view.addGestureRecognizer(press)
        context.coordinator.haptics.start()
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.haptics = haptics
        context.coordinator.onPress = onPress
        context.coordinator.onMove = onMove
        context.coordinator.onEnd = onEnd
    }

    final class Coordinator: NSObject {
        var haptics: ChartHapticPlayer
        var onPress: (CGFloat) -> Void
        var onMove: (CGFloat) -> Bool
        var onEnd: () -> Void
        private let impact = UIImpactFeedbackGenerator(style: .heavy)
        private let selection = UISelectionFeedbackGenerator()

        init(
            haptics: ChartHapticPlayer,
            onPress: @escaping (CGFloat) -> Void,
            onMove: @escaping (CGFloat) -> Bool,
            onEnd: @escaping () -> Void
        ) {
            self.haptics = haptics
            self.onPress = onPress
            self.onMove = onMove
            self.onEnd = onEnd
            super.init()
            impact.prepare()
            selection.prepare()
        }

        @objc func handle(_ gesture: UILongPressGestureRecognizer) {
            let x = gesture.location(in: gesture.view).x
            switch gesture.state {
            case .began:
                impact.impactOccurred(intensity: 1)
                impact.prepare()
                haptics.press()
                onPress(x)
            case .changed:
                if onMove(x) {
                    selection.selectionChanged()
                    selection.prepare()
                    haptics.tick()
                }
            case .ended, .cancelled, .failed:
                onEnd()
            default:
                break
            }
        }
    }
}

final class ChartHapticPlayer {
    private var engine: CHHapticEngine?
    private var pressPlayer: CHHapticPatternPlayer?
    private var tickPlayer: CHHapticPatternPlayer?

    func start() {
        guard engine == nil else {
            try? engine?.start()
            return
        }
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = false
            engine.playsHapticsOnly = true
            engine.resetHandler = { [weak self] in
                DispatchQueue.main.async { self?.rebuildPlayers() }
            }
            engine.stoppedHandler = { [weak self] _ in
                DispatchQueue.main.async { self?.rebuildPlayers() }
            }
            try engine.start()
            self.engine = engine
            rebuildPlayers()
        } catch {
            engine = nil
        }
    }

    func press() {
        play(pressPlayer)
    }

    func tick() {
        play(tickPlayer)
    }

    private func play(_ player: CHHapticPatternPlayer?) {
        guard let engine, let player else { return }
        try? engine.start()
        try? player.start(atTime: CHHapticTimeImmediate)
    }

    private func rebuildPlayers() {
        guard let engine else { return }
        try? engine.start()
        pressPlayer = try? engine.makePlayer(with: Self.transient(intensity: 1, sharpness: 0.3))
        tickPlayer = try? engine.makePlayer(with: Self.transient(intensity: 0.85, sharpness: 1))
    }

    private static func transient(intensity: Float, sharpness: Float) throws -> CHHapticPattern {
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            ],
            relativeTime: 0
        )
        return try CHHapticPattern(events: [event], parameters: [])
    }
}

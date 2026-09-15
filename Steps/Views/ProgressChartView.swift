import SwiftUI
import Charts
import UIKit

struct ProgressChartView: View {
    let day: WalkDay
    let scrubDate: Date?
    var onBegin: (Date) -> Void
    var onChange: (Date) -> Void
    var onEnd: () -> Void

    @State private var lastTickIndex: Int?
    @State private var haptics = ChartHapticEngine()

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

            chart
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Steps over time compared with your average day")

            if let focus {
                Text("By \(Formatters.time.string(from: focus.date)), you’ve usually walked about \(Formatters.steps(averageAtFocus)) steps.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.card)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 22,
                bottomTrailingRadius: 22,
                topTrailingRadius: 0,
                style: .continuous
            )
        )
    }

    private var chart: some View {
        Chart {
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
        .chartYScale(domain: 0...20_000)
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
            AxisMarks(position: .trailing, values: [20_000]) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6, dash: [4, 4]))
                    .foregroundStyle(Color.white.opacity(0.2))
                AxisValueLabel {
                    Text("20K")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.45))
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
            GeometryReader { _ in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .highPriorityGesture(scrubGesture(proxy: proxy))
                    .background(
                        HapticHost(engine: haptics)
                            .frame(width: 1, height: 1)
                            .allowsHitTesting(false)
                    )
            }
        }
        .onAppear {
            haptics.prepare()
        }
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

    private func scrubGesture(proxy: ChartProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !day.points.isEmpty else { return }
                guard let date = proxy.value(atX: value.location.x, as: Date.self) else { return }
                if scrubDate == nil {
                    haptics.prepare()
                    haptics.start()
                    lastTickIndex = nil
                    onBegin(date)
                    tickIfNeeded(for: date)
                } else {
                    onChange(date)
                    tickIfNeeded(for: date)
                }
            }
            .onEnded { _ in
                lastTickIndex = nil
                haptics.prepare()
                onEnd()
            }
    }

    private func tickIfNeeded(for date: Date) {
        guard let point = day.point(nearestTo: date) else { return }
        if lastTickIndex != point.id {
            lastTickIndex = point.id
            haptics.tick()
        }
    }
}

@MainActor
final class ChartHapticEngine {
    private var selection = UISelectionFeedbackGenerator()
    private var impact = UIImpactFeedbackGenerator(style: .medium)
    private weak var view: UIView?

    func attach(to view: UIView) {
        if self.view === view { return }
        self.view = view
        if #available(iOS 17.5, *) {
            selection = UISelectionFeedbackGenerator(view: view)
            impact = UIImpactFeedbackGenerator(style: .medium, view: view)
        } else {
            selection = UISelectionFeedbackGenerator()
            impact = UIImpactFeedbackGenerator(style: .medium)
        }
        prepare()
    }

    func prepare() {
        selection.prepare()
        impact.prepare()
    }

    func start() {
        prepare()
        impact.impactOccurred(intensity: 0.9)
        selection.prepare()
    }

    func tick() {
        selection.selectionChanged()
        selection.prepare()
    }
}

private struct HapticHost: UIViewRepresentable {
    let engine: ChartHapticEngine

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        engine.attach(to: view)
        engine.prepare()
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        engine.attach(to: uiView)
        engine.prepare()
    }
}

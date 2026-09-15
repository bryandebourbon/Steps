import SwiftUI

struct TodayScreen: View {
    @Environment(WalkStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Palette.skyTop, Palette.skyBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            switch store.loadState {
            case .loading:
                LoadingStateView()
            case .empty:
                EmptyStateView(onShowSample: store.showSampleDay)
            case .failed(let message):
                ErrorStateView(
                    message: message,
                    onRetry: { Task { await store.retry() } },
                    onShowSample: store.showSampleDay
                )
            case .ready:
                if let day = store.day {
                    readyContent(day)
                } else {
                    EmptyStateView(onShowSample: store.showSampleDay)
                }
            }
        }
        .task {
            await store.load()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                store.becameActive()
            case .background, .inactive:
                store.flushToDisk()
            default:
                break
            }
        }
    }

    private func readyContent(_ day: WalkDay) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                header(for: day)
                HeroStatsView(
                    day: day,
                    focus: store.isScrubbing ? store.displayPoint : nil,
                    compact: true
                )
                if store.usingSample {
                    Button("Use live walk", action: store.useLiveWalk)
                        .buttonStyle(.borderedProminent)
                        .tint(.white)
                        .foregroundStyle(Palette.skyBottom)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 10)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, alignment: .leading)

            GeometryReader { geo in
                let pane = geo.size.height / 2
                VStack(spacing: 0) {
                    WalkMapView(day: day, focus: store.displayPoint)
                        .frame(height: pane)
                        .frame(maxWidth: .infinity)
                        .clipped()

                    ProgressChartView(
                        day: day,
                        scrubDate: store.scrubDate,
                        onBegin: store.beginScrub(at:),
                        onChange: store.updateScrub(at:),
                        onEnd: store.endScrub
                    )
                    .frame(height: pane)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func header(for day: WalkDay) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Formatters.dayHeader.string(from: day.date).uppercased())
                .font(.system(size: 13, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(Palette.inkMuted)
            Text(day.source == .sample ? "Sample day · press and hold the chart to scrub" : "Live walk · press and hold the chart to scrub")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.ink.opacity(0.82))
        }
    }
}

#Preview("Ready") {
    let store = WalkStore()
    store.showSampleDay()
    return TodayScreen()
        .environment(store)
}

#Preview("Loading") {
    TodayScreen()
        .environment(WalkStore())
}

#Preview("Empty") {
    let store = WalkStore()
    store.loadState = .empty
    return TodayScreen()
        .environment(store)
}

#Preview("Error") {
    let store = WalkStore()
    store.loadState = .failed("Check Location and Motion permissions, then try again.")
    return TodayScreen()
        .environment(store)
}

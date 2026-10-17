import SwiftUI
import UIKit

struct TodayScreen: View {
    @Environment(WalkStore.self) private var store
    @Environment(FriendStore.self) private var friends
    @Environment(\.scenePhase) private var scenePhase
    @State private var showFriends = false
    @State private var showGoal = false
    @State private var goal = StepGoal.load()
    @State private var showTenKConfetti = false
    @State private var showCongratulations = false
    @State private var confettiID = 0
    @State private var tenKOrigin: CGPoint?
    @State private var congratsTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black
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

            if showTenKConfetti, let tenKOrigin {
                TenKConfetti(origin: tenKOrigin) {
                    showTenKConfetti = false
                }
                .id(confettiID)
            }
        }
        .coordinateSpace(name: "stepsScreen")
        .onPreferenceChange(TenKOriginKey.self) {
            tenKOrigin = $0
            celebrateTenKIfNeeded()
        }
        .task {
            await friends.ensureIdentity()
            await friends.fetchThenUpdateWidget()
            friends.start(day: store.day)
            celebrateTenKIfNeeded()
            await store.load()
            celebrateTenKIfNeeded()
            if let day = store.day { friends.note(day) }
        }
        .onChange(of: store.day?.stats.steps) { _, _ in
            celebrateTenKIfNeeded()
            if let day = store.day { friends.note(day) }
        }
        .onChange(of: store.usingSample) { _, _ in
            celebrateTenKIfNeeded()
        }
        .onChange(of: scrubSteps) { previous, current in
            guard let previous, let current else { return }
            if previous < TenKCelebration.threshold && current >= TenKCelebration.threshold {
                playConfetti()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task {
                    await friends.ensureIdentity()
                    await friends.fetchThenUpdateWidget()
                }
                store.becameActive()
                celebrateTenKIfNeeded()
            case .background:
                store.flushToDisk()
                if let day = store.day { friends.publishNow(day) }
            case .inactive:
                store.flushToDisk()
            default:
                break
            }
        }
    }

    private func celebrateTenKIfNeeded() {
        guard scenePhase == .active else { return }
        guard !showTenKConfetti else { return }
        guard tenKOrigin != nil else { return }
        guard case .ready = store.loadState, let day = store.day else { return }
        guard TenKCelebration.shouldCelebrate(steps: day.stats.steps, day: day.date, isSample: store.usingSample) else { return }
        TenKCelebration.markCelebrated(day.date)
        playConfetti()
    }

    private var scrubSteps: Int? {
        guard store.isScrubbing else { return nil }
        return store.displayPoint?.cumulativeSteps
    }

    private func playConfetti() {
        confettiID += 1
        showTenKConfetti = true
        showCongratulations = true
        let id = confettiID
        congratsTask?.cancel()
        congratsTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, confettiID == id else { return }
            showCongratulations = false
        }
    }

    private func readyContent(_ day: WalkDay) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                header(for: day)
                if store.usingSample {
                    Button("Use live steps", action: store.useLiveWalk)
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)

            ProgressChartView(
                day: day,
                scrubDate: store.scrubDate,
                celebrating: showTenKConfetti,
                showCongratulations: showCongratulations,
                burstID: confettiID,
                friends: store.usingSample ? [] : friends.friends,
                goal: goal,
                userName: friends.displayName,
                onBegin: store.beginScrub(at:),
                onChange: store.updateScrub(at:),
                onEnd: store.endScrub
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(isPresented: $showFriends) {
                FriendsSheet()
            }
            .onChange(of: showFriends) { _, show in
                guard show else { return }
                if let day = store.day { friends.publishNow(day) }
                Task { await friends.ensureIdentity() }
            }
            .sheet(isPresented: $showGoal) {
                GoalSheet(goal: goal) { value in
                    goal = StepGoal.save(value)
                }
            }

            HeroStatsView(
                steps: store.isScrubbing
                    ? (store.displayPoint?.cumulativeSteps ?? day.stats.steps)
                    : day.stats.steps
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    private func header(for day: WalkDay) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Formatters.dayHeader.string(from: day.date).uppercased())
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(Color.white.opacity(0.55))
                Text(day.source == .sample ? "Sample day · hold the chart to scrub" : "Hold the chart to scrub")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                Button {
                    showGoal = true
                } label: {
                    Image(systemName: "target")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .accessibilityLabel("Step goal")
                Button {
                    showFriends = true
                    if let day = store.day { friends.publishNow(day) }
                } label: {
                    Image(systemName: "person.2")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .accessibilityLabel("Friends")
            }
        }
    }
}

private struct GoalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    var onSave: (Int) -> Void

    init(goal: Int, onSave: @escaping (Int) -> Void) {
        _text = State(initialValue: String(goal))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                GoalField(text: $text)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                Text("steps a day")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationTitle("Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(.white)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if let value = Int(text), value > 0 {
                            onSave(value)
                        }
                        dismiss()
                    }
                    .tint(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium])
    }
}

private struct GoalField: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.keyboardType = .numberPad
        field.textAlignment = .center
        field.font = .systemFont(ofSize: 48, weight: .thin)
        field.textColor = .white
        field.tintColor = .white
        field.delegate = context.coordinator
        field.text = text
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            field.becomeFirstResponder()
            DispatchQueue.main.async {
                field.selectAll(nil)
            }
        }
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        if field.text != text {
            field.text = text
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        @objc func changed(_ field: UITextField) {
            let digits = String((field.text ?? "").filter(\.isNumber).prefix(6))
            if field.text != digits {
                field.text = digits
            }
            text.wrappedValue = digits
        }
    }
}

#Preview("Ready") {
    let store = WalkStore()
    store.showSampleDay()
    return TodayScreen()
        .environment(store)
        .environment(FriendStore())
}

#Preview("Loading") {
    TodayScreen()
        .environment(WalkStore())
        .environment(FriendStore())
}

#Preview("Empty") {
    let store = WalkStore()
    store.loadState = .empty
    return TodayScreen()
        .environment(store)
        .environment(FriendStore())
}

#Preview("Error") {
    let store = WalkStore()
    store.loadState = .failed("Check Motion and Health permissions, then try again.")
    return TodayScreen()
        .environment(store)
        .environment(FriendStore())
}

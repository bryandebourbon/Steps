import SwiftUI

struct HeroStatsView: View {
    let steps: Int

    var body: some View {
        VStack(spacing: 2) {
            Text(Formatters.steps(steps))
                .font(.system(size: 92, weight: .thin, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .contentTransition(.numericText())
            Text("STEPS")
                .font(.system(size: 14, weight: .semibold))
                .tracking(2.4)
                .foregroundStyle(Color.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
        .animation(.snappy(duration: 0.15), value: steps)
    }
}

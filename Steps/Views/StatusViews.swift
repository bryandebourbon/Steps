import SwiftUI

struct LoadingStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.white)
                .scaleEffect(1.2)
            Text("Loading today’s steps…")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Palette.ink)
            Text("Reading your step count and the usual pace for this time of day.")
                .font(.system(size: 15))
                .foregroundStyle(Palette.inkMuted)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyStateView: View {
    var onShowSample: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "figure.walk")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(Palette.ink)
            Text("No steps yet today")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Text("When you start walking, the chart fills in and the count updates.")
                .font(.system(size: 16))
                .foregroundStyle(Palette.inkMuted)
                .multilineTextAlignment(.center)
            Button("Show a sample day", action: onShowSample)
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .padding(.top, 6)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorStateView: View {
    let message: String
    var onRetry: () -> Void
    var onShowSample: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(Palette.behind)
            Text("Today’s walk couldn’t be loaded")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.system(size: 16))
                .foregroundStyle(Palette.inkMuted)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Try again", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                Button("Show a sample day", action: onShowSample)
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
            .padding(.top, 6)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

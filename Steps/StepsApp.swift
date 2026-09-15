import SwiftUI

@main
struct StepsApp: App {
    @State private var store = WalkStore()

    var body: some Scene {
        WindowGroup {
            TodayScreen()
                .environment(store)
                .preferredColorScheme(.dark)
        }
    }
}

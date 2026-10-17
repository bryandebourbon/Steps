import SwiftUI
import UIKit

@main
struct StepsApp: App {
    @UIApplicationDelegateAdaptor(StepsAppDelegate.self) private var delegate
    @State private var store = WalkStore()
    @State private var friends = FriendStore.shared

    var body: some Scene {
        WindowGroup {
            TodayScreen()
                .environment(store)
                .environment(friends)
                .preferredColorScheme(.dark)
        }
    }
}

final class StepsAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        await FriendStore.shared.refresh()
        return .newData
    }
}

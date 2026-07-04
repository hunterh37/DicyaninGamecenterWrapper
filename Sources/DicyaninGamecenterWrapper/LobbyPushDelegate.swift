import SwiftUI

#if os(visionOS) || os(iOS)
import UIKit

// Registers for remote notifications so CloudKit CKQuerySubscription pushes
// wake the app and refresh the global lobby list.
public final class LobbyPushDelegate: NSObject, UIApplicationDelegate {

    public override init() {
        super.init()
    }

    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    public func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            GameCenterService.shared.handleLobbyPush()
            completionHandler(.newData)
        }
    }
}
#endif

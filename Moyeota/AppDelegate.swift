import FirebaseMessaging
import MoyeotaDomain
import os
import UIKit
import UserNotifications

private let logger = Logger(subsystem: "com.moyeota.app", category: "MoyeotaFcm")

/// 앱 프로세스·푸시 콜백의 입구. 원본에서 `Application.onCreate` 와 FCM 서비스가 맡던 시점을 iOS 콜백으로 받는다.
final class AppDelegate: NSObject, UIApplicationDelegate {
    private let notificationCenterDelegate = NotificationCenterDelegate()

    func application(
        _ application: UIApplication,
        willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        _ = MoyeotaApplication.shared
        // 실행이 끝나기 전에 꽂아야 한다. 늦으면 콜드 스타트의 알림 탭이 이 대리자로 오지 않아 사라진다.
        UNUserNotificationCenter.current().delegate = notificationCenterDelegate
        return true
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 앱 시작마다 등록한다. 권한과 무관하다 — 침묵 푸시는 알림 권한 없이도 받는다.
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MoyeotaApplication.shared.onApnsTokenAvailable(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        // 알림은 부가 기능이라 진입을 막지 않는다. 재시도는 다음 앱 시작이 맡는다.
        let failure = error as NSError
        logger.warning("APNs 등록 실패: \(failure.domain, privacy: .public) \(failure.code, privacy: .public)")
    }

    /// 침묵 푸시 수신. 원본의 데이터 전용 메시지 자리다 — 앱이 전면이든 백그라운드든 여기서 직접 그린다.
    ///
    /// 표시 푸시(`aps.alert`)에 `content-available` 까지 실려 와도 여기로 온다. `handleBackgroundMessage` 가 그런
    /// 메시지는 그리지 않고 지나가므로 두 장이 뜨지 않는다.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        if FirebaseRuntime.isConfigured {
            // 스위즐링을 껐으므로(Info.plist `FirebaseAppDelegateProxyEnabled`) 수신 통계는 직접 알린다.
            Messaging.messaging().appDidReceiveMessage(userInfo)
        }
        let message = RemoteMessage(userInfo: userInfo)
        Task {
            let shown = await handleBackgroundMessage(message)
            completionHandler(shown ? .newData : .noData)
        }
    }
}

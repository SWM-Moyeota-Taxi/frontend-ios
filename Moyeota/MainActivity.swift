import AppNavigation
import MoyeotaDesignSystem
import PresentationCore
import SwiftUI
import UserNotifications

/// 앱의 뿌리 화면. 원본 `MainActivity` 의 자리다.
///
/// 시스템 바는 라이트 고정이다. `MoyeotaTheme` 이 라이트 고정이라 기기 설정과 무관하게 **항상 흰 배경**을 그리는데,
/// 기기를 따라가면 다크 모드 기기에서 흰 배경 + 흰 상태 표시줄 글자가 되어 시계·배터리가 보이지 않는다.
/// `Info.plist` 의 `UIUserInterfaceStyle=Light` 와 같은 값을 뷰 쪽에도 건다.
struct MainActivity: View {
    private let container = MoyeotaApplication.shared.appContainer
    private let pendingChatRoom = MoyeotaApplication.shared.pendingChatRoom

    var body: some View {
        MoyeotaTheme {
            MainNavGraph(
                authRepository: container.authRepository,
                appConfigRepository: container.appConfigRepository,
                rideRepository: container.rideRepository,
                placeRepository: container.placeRepository,
                chatRepository: container.chatRepository,
                dispatchRepository: container.dispatchRepository,
                activePartyRepository: container.activePartyRepository,
                rideRecordRepository: container.rideRecordRepository,
                pendingChatRoomId: pendingChatRoom.roomId,
                onPendingChatRoomHandled: { pendingChatRoom.roomId = nil },
                installedVersionCode: appVersionCode()
            )
        }
        .preferredColorScheme(.light)
        .task { await requestNotificationPermissionIfNeeded() }
    }

    /// 거부해도 재요청하지 않는다. 알림은 부가 기능이라 진입을 막지 않는다.
    ///
    /// 아직 묻지 않았을 때만 묻는다. iOS 는 답을 받은 뒤에는 다시 띄우지 않지만, 정책을 시스템 동작에 기대지 않고 코드로 둔다.
    private func requestNotificationPermissionIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }
}

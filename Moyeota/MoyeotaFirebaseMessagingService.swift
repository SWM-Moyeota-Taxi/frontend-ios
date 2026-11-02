import FirebaseMessaging
import Foundation
import MoyeotaDomain
import os
import PresentationCore
import UserNotifications

private let logger = Logger(subsystem: "com.moyeota.app", category: "MoyeotaFcm")

private let KEY_TYPE = "type"
private let KEY_PARTY_ID = "partyId"

/// 서버 `FcmPassengerNotifier.notifyDriverArrived` 가 싣는 값. 문자열이 계약이다.
private let TYPE_DRIVER_ARRIVED = "DRIVER_ARRIVED"

/// 서버 `FcmChatNotifier.notifyNewMessage` 가 싣는 값들.
private let TYPE_CHAT_MESSAGE = "CHAT_MESSAGE"
private let KEY_CHAT_ROOM_ID = "chatRoomId"
private let KEY_SENDER_NICKNAME = "senderNickname"
private let KEY_PREVIEW = "preview"

private let DEFAULT_NOTIFICATION_ID: Int32 = 1001

/// 채팅 알림 id 는 방 id 에 오프셋을 더해 만든다 — 파티 알림(partyId.hashCode)과 겹치지 않게.
private let CHAT_NOTIFICATION_ID_BASE: Int64 = 200_000

private func chatNotificationId(_ roomId: Int64) -> Int32 {
    Int32(truncatingIfNeeded: CHAT_NOTIFICATION_ID_BASE + roomId % 100_000)
}

/// Java `String.hashCode()`. 서버가 `apns-collapse-id` 로 같은 id 를 만들 수 있어야 해서 Swift 해시를 쓰지 않는다
/// (Swift 해시는 실행마다 바뀐다).
private func javaHashCode(_ value: String) -> Int32 {
    value.utf16.reduce(Int32(0)) { hash, unit in hash &* 31 &+ Int32(unit) }
}

// 문구는 원본 res/values/strings.xml 그대로다. 서버는 type/partyId 만 보내고 문구를 싣지 않으므로 표시 문구는 앱이 갖는다.
private let APP_NAME = "모여타"
private let NOTIFICATION_DRIVER_ARRIVED_TITLE = "기사님이 도착했어요"
private let NOTIFICATION_DRIVER_ARRIVED_BODY = "탑승 장소에서 기사님이 기다리고 계세요."
private let NOTIFICATION_CHAT_UNKNOWN_SENDER = "동승자"
private let NOTIFICATION_CHAT_EMPTY_PREVIEW = "새 메시지가 도착했어요"

/// 원본 `RemoteMessage` 의 자리. APNs 가 건네는 `userInfo` 에서 값만 꺼낸 것이다.
///
/// ### 두 가지 모양을 함께 받는다
/// 서버가 FCM 으로 보낸 data 키는 `userInfo` 의 **최상위**에 그대로 온다(`aps` 와 나란히).
/// - **침묵 푸시**: `aps` 에 `content-available: 1` 만. 시스템이 그리지 않으므로 앱이 깨어나 직접 그린다.
/// - **표시 푸시**: `aps.alert` 가 있다. 시스템이 그리므로 앱이 또 그리면 두 장이 된다.
///
/// 어느 쪽이든 data 키는 같으므로 전경 억제·탭 이동은 모양과 무관하게 같은 규칙을 탄다.
/// 앱이 만든 지역 알림도 같은 키를 `userInfo` 에 실어 같은 코드로 읽는다.
struct RemoteMessage: Sendable {
    let data: [String: String]
    /// `aps.alert` 가 있는가. 있으면 시스템이 이미 그렸거나 그릴 메시지다.
    let hasSystemAlert: Bool

    init(userInfo: [AnyHashable: Any]) {
        var data: [String: String] = [:]
        for (key, value) in userInfo {
            guard let key = key as? String, key != "aps" else { continue }
            // FCM 의 data 값은 항상 문자열이다. APNs 로 직접 보낸 숫자도 같게 읽는다.
            if let value = value as? String {
                data[key] = value
            } else if let value = value as? NSNumber {
                data[key] = value.stringValue
            }
        }
        self.data = data
        hasSystemAlert = (userInfo["aps"] as? [AnyHashable: Any])?["alert"] != nil
    }
}

/// `show` 에 넘길 내용. 원본 `show` 의 인자 자리다.
struct NotificationPlan: Sendable, Equatable {
    /// 같은 값이면 쌓이지 않고 갱신된다. 원본 `notificationId`.
    let notificationId: Int32
    /// 알림 묶음. 원본은 묶음 없이 id 로만 나누지만 iOS 는 묶어 두어야 방 단위로 접힌다.
    let threadIdentifier: String
    let title: String
    let body: String
    /// 탭했을 때 다시 읽는 값. 원본 인텐트 extra 의 자리다.
    let userInfo: [String: String]
}

/// 원본 `onMessageReceived` 의 분기. 표시할 내용을 정하거나 nil(표시 생략)을 돌려준다.
func notificationPlan(
    for message: RemoteMessage,
    visibleRoomId: Int64?,
    now: () -> Date = Date.init
) -> NotificationPlan? {
    let type = message.data[KEY_TYPE]
    switch type {
    case TYPE_DRIVER_ARRIVED:
        return driverArrivedPlan(partyId: message.data[KEY_PARTY_ID])
    case TYPE_CHAT_MESSAGE:
        return chatMessagePlan(data: message.data, visibleRoomId: visibleRoomId)
    default:
        logger.debug("처리 대상이 아닌 메시지 type=\(type ?? "nil", privacy: .public)")
        return genericPlan(message, now: now)
    }
}

/// 기사 도착 알림. 서버는 `{type:"DRIVER_ARRIVED", partyId:"N"}` 만 보내고 문구를 싣지 않으므로
/// **표시 문구는 전적으로 앱이 정한다** — 서버가 새 키를 추가하기 전까지 여기가 유일한 출처다.
private func driverArrivedPlan(partyId: String?) -> NotificationPlan {
    var userInfo = [KEY_TYPE: TYPE_DRIVER_ARRIVED]
    // 지금은 실어만 둔다 — 해당 파티 화면으로 보내는 딥링크는 후속 작업이다.
    // 탭 처리는 이 값을 아직 읽지 않으므로 탭하면 앱만 열린다.
    if let partyId { userInfo[KEY_PARTY_ID] = partyId }
    return NotificationPlan(
        // 같은 파티의 도착 알림이 두 번 오면 쌓이지 않고 갱신되도록 파티 단위로 id 를 나눈다.
        // partyId 가 없는 비정상 메시지는 하나로 합쳐도 무방하다.
        notificationId: partyId.map(javaHashCode) ?? DEFAULT_NOTIFICATION_ID,
        threadIdentifier: "party-\(partyId ?? "")",
        title: NOTIFICATION_DRIVER_ARRIVED_TITLE,
        body: NOTIFICATION_DRIVER_ARRIVED_BODY,
        userInfo: userInfo
    )
}

/// 새 채팅 메시지 알림. 서버 `FcmChatNotifier` 가 싣는 데이터:
/// `{type:"CHAT_MESSAGE", chatRoomId, messageId, seq, senderPublicId, senderNickname, preview}`.
/// 서버가 이미 나(발신자)·나간 사람·음소거한 사람은 수신자에서 뺀다 — 여기서 다시 거를 건 하나뿐이다:
/// **지금 그 방을 보고 있으면** 띄우지 않는다(`ChatForeground`). 폴링이 곧 화면에 그리므로 알림은 중복이다.
///
/// 알림 id 는 **방 단위**다 — 같은 방의 연속 메시지는 쌓이지 않고 최신 한 장으로 갱신된다(카카오톡식).
/// 탭하면 `readPendingChatRoom` 이 `chatRoomId` 를 읽어 그 채팅방을 연다.
private func chatMessagePlan(data: [String: String], visibleRoomId: Int64?) -> NotificationPlan? {
    guard let roomId = data[KEY_CHAT_ROOM_ID].flatMap({ Int64($0) }) else {
        logger.warning("chatRoomId 없는 채팅 알림 — 표시 생략")
        return nil
    }
    if visibleRoomId == roomId {
        logger.debug("보고 있는 방의 메시지 — 알림 생략 roomId=\(roomId, privacy: .public)")
        return nil
    }
    let sender = data[KEY_SENDER_NICKNAME].flatMap { $0.isBlank ? nil : $0 } ?? NOTIFICATION_CHAT_UNKNOWN_SENDER
    let preview = data[KEY_PREVIEW].flatMap { $0.isBlank ? nil : $0 } ?? NOTIFICATION_CHAT_EMPTY_PREVIEW
    return NotificationPlan(
        notificationId: chatNotificationId(roomId),
        threadIdentifier: "chat-\(roomId)",
        title: sender,
        body: preview,
        userInfo: [KEY_TYPE: TYPE_CHAT_MESSAGE, KEY_CHAT_ROOM_ID: String(roomId)]
    )
}

/// 앞으로 서버가 다른 type 을 보낼 때를 위한 폴백. 원본은 notification 페이로드도 여기서 읽지만, iOS 에서 그런 메시지는
/// 시스템이 그려 이 경로를 타지 않는다(`handleBackgroundMessage`).
/// 표시할 문구를 만들 수 없으면 조용히 버린다 — 빈 알림을 띄우는 것보다 낫다.
private func genericPlan(_ message: RemoteMessage, now: () -> Date) -> NotificationPlan? {
    let title = message.data["title"] ?? APP_NAME
    guard let body = message.data["body"] else { return nil }
    return NotificationPlan(
        notificationId: Int32(truncatingIfNeeded: Int64(now().timeIntervalSince1970 * 1000)),
        threadIdentifier: "",
        title: title,
        body: body,
        userInfo: message.data[KEY_TYPE].map { [KEY_TYPE: $0] } ?? [:]
    )
}

/// 침묵 푸시 → 앱이 직접 그린다. 원본 `onMessageReceived` 의 자리다.
/// 시스템에 맡기고 끝낼 메시지(`aps.alert` 있음)는 여기서 그리지 않는다 — 그리면 같은 알림이 두 장이 된다.
///
/// - Returns: 알림을 하나 그렸는가.
func handleBackgroundMessage(_ message: RemoteMessage) async -> Bool {
    guard !message.hasSystemAlert else { return false }
    guard let plan = notificationPlan(for: message, visibleRoomId: ChatForeground.visibleRoomId) else { return false }
    return await show(plan)
}

private func show(_ plan: NotificationPlan) async -> Bool {
    let center = UNUserNotificationCenter.current()
    // 권한이 없으면 등록해도 아무것도 뜨지 않는다. 미리 걸러낸다.
    switch await center.notificationSettings().authorizationStatus {
    case .authorized, .provisional, .ephemeral:
        break
    default:
        logger.debug("알림 권한 미허용 상태로 표시 생략")
        return false
    }
    let content = UNMutableNotificationContent()
    content.title = plan.title
    content.body = plan.body
    content.sound = .default
    content.threadIdentifier = plan.threadIdentifier
    content.userInfo = plan.userInfo
    let request = UNNotificationRequest(identifier: String(plan.notificationId), content: content, trigger: nil)
    do {
        try await center.add(request)
        return true
    } catch {
        logger.warning("알림 표시 실패: \(String(reflecting: type(of: error)), privacy: .public)")
        return false
    }
}

/// 앱이 전면일 때 올라온 알림을 어떻게 보일지.
///
/// 침묵 푸시로 앱이 만든 지역 알림도, 시스템이 건넨 표시 푸시도 여기로 온다. 표시 푸시는 받는 시점 분기가 여기뿐이라
/// 같은 전경 억제를 다시 건다.
func presentationOptions(for message: RemoteMessage, visibleRoomId: Int64?) -> UNNotificationPresentationOptions {
    if message.data[KEY_TYPE] == TYPE_CHAT_MESSAGE {
        guard let roomId = message.data[KEY_CHAT_ROOM_ID].flatMap({ Int64($0) }) else { return [] }
        if visibleRoomId == roomId { return [] }
    }
    return [.banner, .list, .sound]
}

/// 알림 탭으로 열 채팅방. 원본 `MainActivity.readPendingChatRoom` 의 규칙이다 — `roomId > 0` 만 받는다.
/// 한 번의 탭은 한 번만 도착하므로 원본처럼 extra 를 지울 곳이 없고, 소비는 `MainNavGraph` 가 알린다.
func readPendingChatRoom(_ message: RemoteMessage) -> Int64? {
    // 원본 extra 는 채팅 알림만 싣는다. 도착 알림은 탭해도 앱만 열린다.
    guard message.data[KEY_TYPE] == TYPE_CHAT_MESSAGE else { return nil }
    guard let roomId = message.data[KEY_CHAT_ROOM_ID].flatMap({ Int64($0) }), roomId > 0 else { return nil }
    return roomId
}

/// FCM 토큰 회전 수신. 원본 `MoyeotaFirebaseMessagingService` 의 토큰 쪽 자리다.
final class MoyeotaFirebaseMessagingService: NSObject, MessagingDelegate, Sendable {

    /// 토큰 회전을 앱 차원의 등록 창구로 넘긴다.
    ///
    /// 서버 등록은 Bearer 를 요구하는데 이 콜백은 로그인 여부와 무관한 시점에 온다
    /// — 미로그인이면 `FcmTokenRegistrar` 가 보류해 두었다가 다음 로그인 직후 이어서 등록한다.
    /// 여기서 로그인 상태를 따질 필요가 없는 이유다.
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken, !fcmToken.isBlank else { return }
        Task { @MainActor in MoyeotaApplication.shared.onFcmTokenAvailable(fcmToken) }
    }
}

/// 전면 표시·탭 수신.
///
/// **`AppDelegate` 와 나눈 이유:** `UIApplicationDelegate` 는 메인 액터라 그대로 채택하면 이 메서드들도 메인 액터가 되는데,
/// 알림 센터는 이 콜백을 메인 큐에서 부른다고 보장하지 않는다. 보장되지 않은 격리는 실행 중 큐 검사로 앱을 죽인다.
/// 여기서는 격리 없이 받고 필요한 값만 메인 액터로 넘긴다(`ChatForeground` 는 잠금이라 어느 스레드에서 읽어도 된다).
final class NotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let message = RemoteMessage(userInfo: notification.request.content.userInfo)
        completionHandler(presentationOptions(for: message, visibleRoomId: ChatForeground.visibleRoomId))
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let message = RemoteMessage(userInfo: response.notification.request.content.userInfo)
        guard let roomId = readPendingChatRoom(message) else { return }
        logger.debug("채팅 알림 탭 — 보류 등록 roomId=\(roomId, privacy: .public)")
        // 콜드 스타트 탭은 뷰가 만들어지기 전에 올 수 있다. 값은 프로세스가 들고 있어 첫 화면이 이어 받는다.
        Task { @MainActor in MoyeotaApplication.shared.pendingChatRoom.roomId = roomId }
    }
}

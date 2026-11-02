import os

/// 지금 **화면에 떠 있는** 채팅방 id. 없으면 nil.
///
/// 푸시 수신 쪽(앱 타깃)이 「이 방을 보고 있는 중이면 알림을 띄우지 않는다」를 판단하는 데 쓴다 —
/// 대화를 보고 있는데 같은 메시지가 상단 알림으로도 뜨면 두 번 알리는 셈이다. 폴링(3초)이 새 메시지를
/// 곧 화면에 그리므로 알림 없이도 놓치지 않는다.
///
/// `ChatRoomRoute` 가 화면이 시작될 때 적고 멈출 때 지운다. 프로세스 전역 단일 값이라 방을 옮기면 덮어쓴다.
/// 푸시 콜백 스레드에서 읽으므로 잠금으로 지킨다(원본 `@Volatile`).
public enum ChatForeground {
    private static let storage = OSAllocatedUnfairLock<Int64?>(initialState: nil)

    public static var visibleRoomId: Int64? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

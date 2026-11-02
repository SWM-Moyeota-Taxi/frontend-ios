import MoyeotaDesignSystem
import MoyeotaDomain
import PresentationCore
import SwiftUI

private let CanvasBg = Color(argb: 0xFFF5F7FA)
private let GrayMute = Color(argb: 0xFF8A93A0)
private let GrayAsh = Color(argb: 0xFF9AA1AC)

let ChatListScrollKey = "chat.list"

/// 24 · 채팅 목록 — 내가 속한 채팅방(GET /chat-rooms/me)
///
/// 이동:
/// - 방 행 탭 → 24 채팅방 (onRoomClick)
/// - 하단탭 → 14/17/35 (onTabSelect)
///
/// 제목은 **참여자 닉네임**(`ChatRoomListItem.peerTitle` · `chatRoomPeerTitle`), 부제는 **마지막 메시지**
/// (없으면 경로 — `chatRoomSubtitle`), 우측에 마지막 메시지 시각과 안읽음 점.
/// 정렬은 Route 가 이미 마친 상태로 넘어온다(`chatRoomSortKey` — 마지막 활동 시각 내림차순).
public struct ChatListScreen: View {
    private let rooms: [ChatRoomListItem]
    private let onRoomClick: (MyChatRoom) -> Void
    private let onTabSelect: (MoyeotaTab) -> Void

    public init(
        rooms: [ChatRoomListItem] = [],
        onRoomClick: @escaping (MyChatRoom) -> Void = { _ in },
        onTabSelect: @escaping (MoyeotaTab) -> Void = { _ in }
    ) {
        self.rooms = rooms
        self.onRoomClick = onRoomClick
        self.onTabSelect = onTabSelect
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                StatusBarSpacer()
                Text("채팅")
                    .moyeotaText(bodyLargeText(18, .bold), color: MoyeotaColor.InkPrimary)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MoyeotaColor.SurfaceCanvas)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer().frame(height: 16)
                    if rooms.isEmpty {
                        Text("아직 참여 중인 채팅방이 없어요. 동승에 합류하면 채팅방이 열려요")
                            .moyeotaText(bodyLargeText(13, .medium), color: GrayAsh)
                            .padding(.vertical, 24)
                    } else {
                        roomCard
                    }
                    Spacer().frame(height: 16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                // 원본 `rememberScrollState` 는 저장 상태라 탭을 다녀와도 읽던 자리가 남는다
                .savedScrollOffset(ChatListScrollKey)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            MoyeotaBottomBar(selected: .chat, onSelect: onTabSelect)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CanvasBg)
    }

    private var roomCard: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .circular)
        return VStack(spacing: 0) {
            ForEach(Array(rooms.enumerated()), id: \.offset) { index, item in
                ChatRoomRow(item: item, onClick: { onRoomClick(item.room) })
                if index != rooms.count - 1 {
                    HorizontalDivider(color: MoyeotaColor.Hairline)
                        .padding(.leading, 66)
                        .padding(.trailing, 20)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(MoyeotaColor.SurfaceCanvas)
        .clipShape(shape)
        .moyeotaShadow(elevation: 4, shape: shape, spotColor: Color(argb: 0x1A1B2A4A))
    }
}

/// 목록 부제 — **마지막 메시지 미리보기**가 있으면 그것, 없으면 경로(+종료 여부).
/// 위치 공유 메시지는 본문이 좌표라 사람 말로 바꾼다. 삭제된 메시지는 서버가 이미 「삭제된 메시지입니다」로 준다.
func chatRoomSubtitle(item: ChatRoomListItem) -> String {
    let room = item.room.room
    if let last = item.room.membership.lastMessage {
        let preview: String
        switch last.type {
        case .location: preview = "📍 위치를 공유했어요"
        case .text: preview = last.content
        }
        return room.status == .active ? preview : "종료 · \(preview)"
    }
    let routeLabel = "\(room.departure) → \(room.destination)"
    // 참여자를 못 받은 방은 제목이 경로라, 부제까지 경로면 같은 문장이 두 번이다 — 방 상태를 쓴다
    if item.peerTitle == nil {
        return room.status == .active ? "진행 중" : "종료된 방"
    }
    return room.status == .active ? routeLabel : "종료 · \(routeLabel)"
}

private struct ChatRoomRow: View {
    let item: ChatRoomListItem
    let onClick: () -> Void

    var body: some View {
        let room = item.room.room
        let membership = item.room.membership
        let title = item.peerTitle ?? "\(room.departure) → \(room.destination)"
        let subtitle = chatRoomSubtitle(item: item)
        let timeLabel = membership.lastMessage?.createdAt.toListTimeLabel()
        let unread = membership.hasUnread
        Button(action: onClick) {
            HStack(alignment: .center, spacing: 0) {
                // 제목이 부르는 사람의 얼굴(`ChatRoomListItem.peerImageUrl`) — 제목과 **같은 멤버 목록**에서
                // 뽑아 Route 가 실어 보낸다. 참여자를 못 받은 방은 제목이 경로로 떨어지고 여기도 회색 원이다.
                AvatarCircle(size: 40, imageUrl: item.peerImageUrl)
                Spacer().frame(width: 10)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .moyeotaText(bodyLargeText(14, .bold), color: MoyeotaColor.InkPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(subtitle)
                        // 안 읽은 방은 미리보기를 진하게 — 배지와 함께 「새 대화」를 두 신호로 알린다
                        .moyeotaText(
                            bodyLargeText(12, unread ? .semibold : .medium),
                            color: unread ? MoyeotaColor.InkPrimary : GrayMute
                        )
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer().frame(width: 8)
                VStack(alignment: .trailing, spacing: 0) {
                    if let timeLabel {
                        Text(timeLabel)
                            .moyeotaText(bodyLargeText(11, .medium), color: GrayAsh)
                            .fixedSize()
                        Spacer().frame(height: 6)
                    }
                    // 안읽음 배지 — 서버가 개수를 주면 숫자(99+ 상한), 개수 없는 구버전 응답이면 점
                    if unread {
                        UnreadBadge(count: membership.unreadCount)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressOverlayStyle(shape: Rectangle()))
    }
}

/// 안읽음 개수 표기 — 두 자리까지 그대로, 그 위는 「99+」(배지가 행 높이를 넘지 않게). nil 은 개수 모름(점)
func unreadBadgeLabel(count: Int?) -> String? {
    guard let count, count > 0 else { return nil }
    return count > 99 ? "99+" : String(count)
}

private struct UnreadBadge: View {
    let count: Int?

    var body: some View {
        if let label = unreadBadgeLabel(count: count) {
            Text(label)
                .moyeotaText(bodyLargeText(11, .bold), color: MoyeotaColor.SurfaceCanvas)
                .fixedSize()
                .padding(.horizontal, 6)
                .frame(minWidth: 20, minHeight: 20)
                .background(MoyeotaColor.Primary500, in: Capsule(style: .circular))
        } else {
            Circle()
                .fill(MoyeotaColor.Primary500)
                .frame(width: 8, height: 8)
        }
    }
}

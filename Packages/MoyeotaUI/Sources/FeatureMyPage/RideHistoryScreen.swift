import MoyeotaDesignSystem
import MoyeotaDomain
import PresentationCore
import SwiftUI

/// 34 · 지난 탑승 기록 [S22 재도입]
///
/// 진입: 35 마이페이지 「지난 탑승 기록」 행.
///
/// 서버: `GET /api/v1/users/me/parties` — **하차까지 끝난 탑승만** 온다. 커서 페이징이고
/// `hasNext` 가 true 일 때만 `nextCursor` 로 다음 페이지를 받는다.
///
/// ```
/// ← 지난 탑승 기록
///   10월 31일 오후 4:15
///   강남역 → 판교역
///   (아바타들)  나 포함 1명
///   1인 16,500원 · 총 16,500원     ← 요금이 없는 기록은 이 줄이 없다
/// ```
///
/// ### 그리지 않는 것과 그 이유
/// - **상태 칩** — 서버가 상태를 주지 않는다. 이 목록은 전부 하차 완료라 상태 개념 자체가 없다.
/// - **방장 표시** — 응답 멤버에 `host` 필드가 없다(방 상세와 다르다).
/// - **평점·매너 점수** — 평가 API 가 없다. 지어낸 4.9 를 그리지 않는다.
/// - **「예정」 탭** — 예약 개념이 서버에 없다. 예전 34 가 이것 때문에 삭제됐다.
/// - **요금이 없는 기록의 요금 줄** — 1차 모드(기사 없이 합승 종료)로 끝난 방은 요금이 nil 이다.
///   0원으로 그리면 「공짜로 탔다」는 거짓말이 된다. 판정은 `RideRecord.toHistoryItem`.
///
/// ### 색은 토큰만 쓴다
/// 삭제됐던 `MyRidesScreen` 을 참고했지만 그 파일이 들고 있던 파일-로컬 그레이 5개
/// (`CanvasBg`·`GraySlate`·`GrayMute`·`GrayAsh`·`CardShadow`)는 **가져오지 않았다** — 토큰 밖의
/// 색이라 테마가 바뀌면 이 화면만 남는다. 더미 데이터와 「예정」 탭도 가져오지 않았다.
///
/// - Parameter loading: 첫 페이지를 받는 중. 목록이 비어 있을 때만 전체 스피너를 그린다.
/// - Parameter loadingMore: 다음 페이지를 받는 중. 목록 맨 아래 스피너다.
/// - Parameter hasNext: true 면 끝까지 스크롤했을 때 `onLoadMore` 를 부른다.
/// - Parameter failed: 불러오기가 실패했는가. 문구는 하나다 — 사용자가 할 일은 「다시 시도」뿐이다.
public struct RideHistoryScreen: View {
    private let records: [RideRecord]
    private let loading: Bool
    private let loadingMore: Bool
    private let hasNext: Bool
    private let failed: Bool
    private let onLoadMore: () -> Void
    private let onRetry: () -> Void
    private let onBack: () -> Void

    public init(
        records: [RideRecord] = [],
        loading: Bool = false,
        loadingMore: Bool = false,
        hasNext: Bool = false,
        failed: Bool = false,
        onLoadMore: @escaping () -> Void = {},
        onRetry: @escaping () -> Void = {},
        onBack: @escaping () -> Void = {}
    ) {
        self.records = records
        self.loading = loading
        self.loadingMore = loadingMore
        self.hasNext = hasNext
        self.failed = failed
        self.onLoadMore = onLoadMore
        self.onRetry = onRetry
        self.onBack = onBack
    }

    public var body: some View {
        // 카드가 보이고 사라질 때마다 다시 계산되지 않도록, 그 상태는 아래 `RideHistoryList` 가 든다.
        let items = records.map { $0.toHistoryItem() }

        VStack(spacing: 0) {
            StatusBarSpacer()
            MoyeotaTopBar(title: "지난 탑승 기록", onBack: onBack)

            // 첫 조회가 끝나기 전에는 빈 상태 문구를 그리지 않는다 — 기록이 있는 사용자에게
            // 「아직 탑승 기록이 없어요」가 한 번 스쳐 보인다.
            if loading && items.isEmpty {
                CenteredBox { CircularProgressIndicator() }
            } else if failed && items.isEmpty {
                CenteredBox {
                    VStack(spacing: 0) {
                        Text(RIDE_HISTORY_ERROR_TEXT)
                            .moyeotaText(.BodyMd, color: MoyeotaColor.TextMute)
                            .multilineTextAlignment(.center)
                        Spacer().frame(height: 16)
                        SecondaryButton(text: "다시 시도", onClick: onRetry)
                    }
                }
            } else if items.isEmpty {
                CenteredBox {
                    Text(RIDE_HISTORY_EMPTY_TEXT)
                        .moyeotaText(.BodyMd, color: MoyeotaColor.TextMute)
                        .multilineTextAlignment(.center)
                }
            } else {
                RideHistoryList(
                    items: items,
                    loadingMore: loadingMore,
                    hasNext: hasNext,
                    failed: failed,
                    onLoadMore: onLoadMore
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MoyeotaColor.SurfaceSoft)
    }
}

private struct RideHistoryList: View {
    let items: [RideHistoryItem]
    let loadingMore: Bool
    let hasNext: Bool
    let failed: Bool
    let onLoadMore: () -> Void

    // 지금 보이는 카드. 원본 `listState.layoutInfo.visibleItemsInfo` 자리다 — 새 페이지가 붙으면 마지막 카드가
    // 바뀌므로 「마지막 카드가 보이는가」를 플래그 하나로 들지 않고 id 로 들어 다시 묻는다.
    @State private var visiblePartyIds: Set<Int64> = []

    /// `LaunchedEffect` 의 키 자리.
    private struct LoadMoreKey: Hashable {
        let lastVisible: Bool
        let hasNext: Bool
        let loadingMore: Bool
        let failed: Bool
        let count: Int
    }

    var body: some View {
        let lastVisible = items.last.map { visiblePartyIds.contains($0.partyId) } ?? false
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 12) {
                // partyId 로 키를 준다 — 커서 페이징으로 뒤에 붙는 목록이라 위치 기반 재사용이
                // 일어나면 아바타 이미지가 다른 카드에 남는다(MemberDisplay 주석의 그 사고).
                ForEach(items, id: \.partyId) { item in
                    RideHistoryCard(item: item)
                        .onAppear { visiblePartyIds.insert(item.partyId) }
                        .onDisappear { visiblePartyIds.remove(item.partyId) }
                }

                if loadingMore {
                    CircularProgressIndicator()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }

                // 2페이지 이후의 실패는 위의 `failed && items.isEmpty` 분기에 걸리지 않는다
                // (이미 1페이지를 그리고 있으니 목록이 비어 있지 않다). 그 실패를 여기서 말하지
                // 않으면 사용자는 **왜 기록이 20건에서 멈췄는지 끝까지 알 수 없다.**
                if failed && !items.isEmpty && !loadingMore {
                    VStack(spacing: 0) {
                        Text("기록을 더 불러오지 못했어요")
                            .moyeotaText(.BodySm, color: MoyeotaColor.TextMute)
                        Spacer().frame(height: 12)
                        // 첫 페이지부터 다시 받지 않는다(`onRetry` 는 그쪽이다) — 이미 보고 있던
                        // 기록과 스크롤 위치를 버리게 된다. 끊긴 지점부터 이어 받는다.
                        SecondaryButton(text: "다시 시도", onClick: onLoadMore)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
            }
            .padding(16)
        }
        .scrollBounceBehavior(.basedOnSize)
        // 원본 `LazyColumn` 은 자기 칸에서 잘린다. SwiftUI `ScrollView` 는 안전 영역까지 그린다.
        .clipped()
        // 마지막 카드가 보이면 다음 페이지. hasNext 가 false 면 트리거 자체가 서지 않는다
        // — 그래도 부르면 커서 없이 첫 페이지를 다시 받아 목록이 무한히 중복된다.
        // 키에 failed 가 **반드시** 들어가야 한다 — 빠뜨리면 실패로 loadingMore 가 내려가는 순간
        // 이 효과가 재시작해 같은 요청을 즉시 다시 쏘고, 그게 끝없이 돈다.
        .task(
            id: LoadMoreKey(
                lastVisible: lastVisible,
                hasNext: hasNext,
                loadingMore: loadingMore,
                failed: failed,
                count: items.count
            )
        ) {
            if lastVisible && shouldLoadMore(hasNext: hasNext, loading: loadingMore, failed: failed) {
                onLoadMore()
            }
        }
    }
}

private struct CenteredBox<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 기록 한 장. **눌러도 갈 곳이 없어 탭 동작과 꺾쇠를 두지 않았다** — 끝난 방의 상세
/// (`GET /matching/rooms/{id}`)는 열리지만 그 화면(22)은 진행 중 방을 전제로 쓰여 있다.
/// 갈 곳이 없는데 꺾쇠를 달면 「눌러서 갈 곳이 있다」는 이 앱의 기호 규칙이 거짓이 된다.
private struct RideHistoryCard: View {
    let item: RideHistoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let dateLabel = item.dateLabel {
                Text(dateLabel)
                    .moyeotaText(MoyeotaType.CaptionMd.hangulTrimmed, color: MoyeotaColor.TextMute)
                Spacer().frame(height: 6)
            }
            if let routeLabel = item.routeLabel {
                Text(routeLabel)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .moyeotaText(MoyeotaType.HeadingMd.hangulTrimmed, color: MoyeotaColor.InkPrimary)
                Spacer().frame(height: 10)
            }

            if !item.members.isEmpty || item.memberLabel != nil {
                HStack(spacing: 0) {
                    ForEach(Array(item.members.enumerated()), id: \.offset) { _, member in
                        RideHistoryAvatar(member: member)
                        Spacer().frame(width: 6)
                    }
                    if let memberLabel = item.memberLabel {
                        Text(memberLabel)
                            .moyeotaText(MoyeotaType.BodySm.hangulTrimmed, color: MoyeotaColor.TextBody)
                    }
                }
            }

            // 요금이 없는 기록(1차 모드)은 여기까지 아무것도 그리지 않는다. 「0원」을 쓰지 않는 자리다.
            if let fare = item.fare {
                Spacer().frame(height: 12)
                MoyeotaColor.Hairline.frame(height: 1)
                Spacer().frame(height: 12)
                HStack(spacing: 0) {
                    if let perPersonLabel = fare.perPersonLabel {
                        Text(perPersonLabel)
                            .moyeotaText(MoyeotaType.HeadingMd.hangulTrimmed, color: MoyeotaColor.InkPrimary)
                    }
                    if fare.perPersonLabel != nil && fare.totalLabel != nil {
                        Text(" · ")
                            .moyeotaText(.BodySm, color: MoyeotaColor.TextAsh)
                    }
                    if let totalLabel = fare.totalLabel {
                        Text(totalLabel)
                            .moyeotaText(MoyeotaType.BodySm.hangulTrimmed, color: MoyeotaColor.TextMute)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MoyeotaColor.SurfaceCard, in: RoundedRectangle(cornerRadius: 16, style: .circular))
    }
}

/// 동승자 아바타. 사진이 있으면 사진, 없거나 로드에 실패하면 **닉네임 첫 글자**다
/// (`AvatarCircle` 이 둘을 겹쳐 그리고 성공했을 때만 글자를 가린다).
///
/// `MemberDisplay` 의 아바타를 쓰지 않는다 — 그쪽은 `User` 를 받고 `isMe` 로 색이 갈리는데,
/// 기록의 멤버는 `RideRecordMember` 라 `User` 로 올리려면 없는 필드(`rideCount`·`host`·`badgeId`)를
/// 거짓값으로 채워야 한다. 그래서 디자인시스템의 `AvatarCircle` 을 직접 쓴다.
private struct RideHistoryAvatar: View {
    let member: RideRecordMember

    var body: some View {
        AvatarCircle(
            size: 28,
            label: member.nickname.first.map(String.init),
            imageUrl: member.imageUrl
        )
    }
}

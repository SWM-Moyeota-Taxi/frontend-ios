import MoyeotaDesignSystem
import MoyeotaDomain
import SwiftUI

// 파티 멤버(동승자)를 화면에 그릴 때 쓰는 공용 표기 규칙.
//
// 20 합류 확인 · 21 매칭 대기 · 22 탑승 상세 · 23 동승자 프로필 · 25 배차 현황이 같은 데이터를
// 조금씩 다른 레이아웃으로 보여준다. **문구 규칙만은 한 곳에 둔다** — "탑승 0회"를 한 화면은
// 「첫 탑승」으로, 다른 화면은 「탑승 0회」로 쓰면 같은 사람이 화면마다 달라 보인다.
//
// ### 서버 계약: 「요약 없음」과 「탈퇴」는 **다른 모양으로 온다** ★
//
// | 경우 | 서버가 주는 `members[]` 항목 | 이 파일의 판정 |
// |---|---|---|
// | 유저 요약을 못 찾았다 | publicId·nickname·imageUrl 이 **전부 null** → 매퍼가 `id = ""` · `nickname = "탈퇴한 회원"` 으로 접는다 | `isWithdrawn` (= 빈 id) |
// | 탈퇴했다(**soft delete**) | publicId 는 **그대로** 오고 nickname 만 서버가 `"탈퇴한 사용자"` 로 가린다 | `hasCallableName` 이 false |
//
// 아래가 **한 판정으로 접히지 않는 이유**다: 탈퇴한 사용자는 식별자가 살아 있어 프로필로 들어갈 수
// 있고 서버가 방장으로 지목할 수도 있다 — 못 하는 것은 **이름으로 부르는 것** 하나뿐이다. 그래서
// 탭 차단·아바타는 `isWithdrawn`(식별자 있나)으로, 이름으로 부르는 문구는 `hasCallableName`
// (사람 이름인가)으로 가른다. 두 문자열은 `WithdrawnMemberNames` 한 곳에 모여 있다.
//
// **탈퇴 판정을 `imageUrl == nil` 로 바꾸지 마라.** 2026-10-15 배포(Backend #235)부터 멀쩡한
// 사용자도 기본 이미지의 전체 URL 을 받는다 — 그 둘을 바꾸면 판정이 정확히 뒤집혀 **전원이
// 탈퇴 회원으로 표시된다.** 요약 유무 판정의 출처는 publicId 하나다.

public extension User {
    /// **유저 요약이 없는** 멤버. 프로필로 들어갈 대상이 없다 — 탭을 막아야 한다.
    ///
    /// soft delete 된 사용자는 **여기 걸리지 않는다**(publicId 가 살아 있다). 그쪽을 걸러야 하는 자리는
    /// 이름으로 부르는 문구뿐이고, 그 판정은 `hasCallableName` 이다.
    var isWithdrawn: Bool { id.isBlank }

    /// 이 이름으로 **사람을 부를 수 있는가** — 「…님이」처럼 이름을 문장에 넣는 자리의 판정.
    ///
    /// 걸러야 하는 것이 둘이다. 하나는 서버가 soft delete 로 가린 이름
    /// (`WithdrawnMemberNames.SERVER_DELETED`), 하나는 요약이 없어 **앱이** 채운 자리값
    /// (`WithdrawnMemberNames.NO_SUMMARY`). 둘 다 **공백 검사로는 걸러지지 않는다** — 멀쩡한 문자열이다.
    var hasCallableName: Bool { !nickname.isBlank && !WithdrawnMemberNames.ALL.contains(nickname) }

    /// 목록·프로필에 찍는 이름. 요약이 없는 멤버는 닉네임이 없어 자리값을 쓴다.
    var displayNickname: String {
        isWithdrawn || nickname.isBlank ? WithdrawnMemberNames.NO_SUMMARY : nickname
    }

    /// 탑승 횟수 문구. 0회는 "탑승 0회"(빈 실적처럼 읽힌다)가 아니라 「첫 탑승」으로 쓴다
    /// — 서버 rideCount 는 FINISHED 파티 수라 신규 가입자는 항상 0 이다.
    var rideCountLabel: String { rideCount <= 0 ? "첫 탑승" : "탑승 \(rideCount)회" }

    /// 인증 라벨. 서버 `badgeId` 가 아직 항상 null 이라 대부분 빈 값으로 온다 —
    /// 빈 값에 아무 것도 안 쓰면 "인증된 사람"으로 오해될 여지가 있어 중립 문구를 명시한다.
    var verifiedLabelOrNone: String { verifiedLabel.isBlank ? "인증 정보 없음" : verifiedLabel }

    /// 「방장」 배지를 그릴 행인가 — **내 줄에는 그리지 않는다.**
    ///
    /// 방장 표시는 2026-10-15 에 되살렸다. 예전에 지웠던 것(`_workspace/33_api-integrator_no_host.md`·
    /// `34_compose-builder_no_host.md`)과 **근거가 다르다**: 그때는 서버에 방장 개념이 아예 없어서 앱이
    /// `joinedAt` 최소값으로 **추정**하던 것이었고, 지금 `User.isHost` 에 담긴 값은 서버가 멤버마다
    /// 내려 주는 `MemberInfo.host` 다(Backend #240). 즉 **추정이 아니라 서버 값**이다 — 앱은 입장 순서를
    /// 세지 않는다.
    ///
    /// 그런데 **서버가 `host` 를 빼먹었을 때의 폴백이 한쪽으로만 기울어 있다.** 매퍼가 `host ?? isMe` 로
    /// 접기 때문에(`PartyMappers.toUser` 의 표) 옛 배포를 보고 있으면 **내 줄만** true 가 된다. 그건
    /// 의도된 fail-open 이다 — 방장이 「합승 완료」를 못 보면 방을 끝낼 길이 없어 30분 만료를 기다려야
    /// 하는 쪽이 복구 불가이고, 반대로 틀렸을 때는 서버 403 `NOT_PARTY_HOST` 가 바로잡아 준다.
    ///
    /// **그 폴백을 배지에 그대로 쓰면 안 된다.** 버튼의 거짓은 눌렀을 때 서버가 바로잡지만, 배지의
    /// 거짓은 아무도 바로잡지 않는다 — 비방장이 자기 줄에서 「방장」을 읽고, 심지어 눌렀을 때 받는
    /// 「방장만 합승을 완료할 수 있어요」와 **정면으로 모순**되는 화면이 된다. 사람에 대해 지어낸
    /// 사실을 띄우는 건 원본 저장소가 거짓 문구 19건을 들어내며 금지한 바로 그것이다(`ProductClaimsTest`).
    ///
    /// 그래서 내 줄을 뺀다. `User.isMe` 는 한 명뿐이라 폴백이 만들 수 있는 거짓 true 도 내 줄 하나뿐이고,
    /// 내 줄을 빼면 이 값은 정확히 **「서버가 이 사람을 방장이라고 말했다」** 가 된다. 잃는 것은 「내가
    /// 방장일 때 내 줄에 붙는 배지」 하나인데, 그건 21 대기 화면 하단이 이미 말한다 — 방장에게는
    /// 「합승 완료」 버튼이 보이고, 비방장에게는 방장을 가리키는 안내문이 보인다.
    var showsHostBadge: Bool { isHost && !isMe }

    /// 아바타의 이니셜 — 요약이 없거나 닉네임이 비면 「?」.
    internal var avatarInitial: String {
        isWithdrawn || nickname.isBlank ? "?" : String(nickname.prefix(1))
    }
}

public extension Array where Element == User {
    /// 안내문에서 **이름으로 부를 수 있는** 방장 — 부를 수 없으면 nil.
    ///
    /// 방장을 **고르는** 판정은 `showsHostBadge` 와 같다(배지가 붙은 사람과 안내문이 부르는 사람이
    /// 어긋나면 안 된다). 거기서 **이름을 쓸 수 있는지**만 한 겹 더 본다 — 배지는 그대로 붙이고 이름만
    /// 쓰지 않는다. 서버가 그를 방장이라고 말한 건 사실이고(배지), 그 사실이 방이 왜 안 끝나는지를
    /// 설명해 주기 때문이다.
    ///
    /// nil 이 나오는 경우는 셋이다:
    ///
    /// | 경우 | 모양 | 판정 |
    /// |---|---|---|
    /// | 방장의 유저 요약이 없다 | id 가 빈 값 | `isWithdrawn` |
    /// | 방장이 **탈퇴했다**(soft delete) | id 는 살아 있고 닉네임이 `"탈퇴한 사용자"` | `hasCallableName` false |
    /// | 아무도 방장으로 지목되지 않았다 | 내가 목록에 없는 응답 등 | 고를 행이 없다 |
    ///
    /// 탈퇴한 방장을 이름으로 부르면 **지킬 수 없는 약속**이 된다: 「다 타면 방장 탈퇴한 사용자님이
    /// 「합승 완료」를 눌러…」 — 그 사람은 영원히 누를 수 없고 방은 30분 만료로만 닫힌다. 그때 문구는
    /// 이름 대신 **조건**을 말한다(`finishHostNotice`).
    func hostDisplayNameOrNull() -> String? {
        first { $0.showsHostBadge && !$0.isWithdrawn && $0.hasCallableName }?.nickname
    }
}

/// 멤버 아바타. 서버 프로필 사진을 그리고, **그릴 수 없을 때는 닉네임 첫 글자 이니셜 원**으로 떨어진다.
///
/// 서버는 2026-10-15 배포(Backend #235)부터 제공 이미지 16장을 고르게 하고 `imageUrl` 로 전체 주소를
/// 내려준다. 호출부는 네 곳이다(21 매칭 대기 36dp · 22 탑승 상세 40dp · 23 동승자 프로필 80dp · 20 합류 확인 40dp).
///
/// ### 네 경우에 무엇이 보이는가
///
/// | 경우 | 보이는 것 |
/// |---|---|
/// | `User.imageUrl` 이 nil/빈 값 | 이니셜 원 — **요청 자체를 만들지 않는다** |
/// | 로딩 중 | 이니셜 원 |
/// | 성공 | 사진(이니셜 원을 덮는다) |
/// | 실패(403·타임아웃·디코드 실패) | 이니셜 원 |
///
/// 「성공했을 때만 가린다」는 **로더의 페이드가 꺼져 있어야 성립한다.** 켜져 있으면 이니셜을 지운 뒤 잠깐 빈 원만
/// 남는다. 그래서 `MoyeotaAsyncImage` 가 페이드를 쓰지 않는다.
///
/// 이 앱에서 사진 없음은 **정상 경우**다(유저 요약이 없는 멤버는 publicId·nickname·imageUrl 이 **함께** null 로 온다).
/// 대체 표시가 **멤버마다 다른 글자와 색**이라(`User.isMe` 로 Primary 와 회색이 갈리고 글자 크기가 `size` 에
/// 비례한다) **아래에 깔고 성공했을 때만 가린다.**
///
/// ### 표시 상태의 키가 `User.imageUrl` 인 이유
/// 호출부 넷 중 셋은 멤버 줄이고(20 합류 확인 · 21 매칭 대기 · 22 탑승 상세) 하나는 목록이 아닌
/// 단독 80dp 아바타다(23 동승자 프로필). 멤버가 합류·이탈해 `ride.members` 의 길이나 순서가 바뀌면
/// 같은 위치의 뷰가 **다른 `User`** 를 받을 수 있다. 키가 없으면 **B 의 이니셜이 안 보이고 A 의 사진이 남는다.**
/// `MoyeotaAsyncImage` 가 URL 이 다른 결과를 버리는 건 이 때문이다.
///
/// `MoyeotaDesignSystem` 의 `AvatarCircle` 과 **합치지 않는다.** 하는 일은 같아 보이지만 이쪽은
/// `User.isMe` 로 배경·글자색이 갈리고 글자 크기가 `size` 에 비례하는데, 저쪽은 고정 `CaptionMd` 다 —
/// 합치면 둘 중 하나가 거짓이 된다.
public struct MemberAvatar: View {
    private let user: User
    private let size: CGFloat

    public init(user: User, size: CGFloat = 40) {
        self.user = user
        self.size = size
    }

    public var body: some View {
        MoyeotaAsyncImage(url: user.imageUrl) { image in
            ZStack {
                if image == nil {
                    Text(user.avatarInitial)
                        .moyeotaText(
                            MoyeotaType(fontSize: size * 0.4, fontWeight: .bold),
                            color: user.isMe ? MoyeotaColor.Primary600 : MoyeotaColor.TextMute
                        )
                }
                if let image {
                    // 지름에서 2 를 빼는 이유: 꽉 찬 원형 이미지는 부모의 1pt 헤어라인을 덮는다.
                    // 비정사각 이미지가 원 안에서 레터박스가 되지 않게 채워서 자른다.
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size - 2, height: size - 2)
                        .clipShape(Circle())
                        // 바로 옆에서 닉네임을 읽어 주는 자리들이라 사진은 장식이다 — 중복 낭독을 막는다.
                        .accessibilityHidden(true)
                }
            }
            .frame(width: size, height: size)
            .background(user.isMe ? MoyeotaColor.Primary50 : MoyeotaColor.SurfaceSoft, in: Circle())
            .overlay(Circle().strokeBorder(MoyeotaColor.Hairline, lineWidth: 1))
        }
    }
}

/// 「나」 배지 — 멤버 목록에서 내 줄을 한눈에 찾게 한다(isMe = publicId == 세션 uuid).
public struct MeBadge: View {
    public init() {}

    public var body: some View {
        Text("나")
            .moyeotaText(inheritedBodyLargeType(11, .bold), color: MoyeotaColor.Primary600)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(MoyeotaColor.Primary50, in: Capsule(style: .circular))
    }
}

/// 「방장」 배지 — `showsHostBadge` 인 행에만 붙인다.
///
/// 「나」(`MeBadge`)와 색을 달리한다. 둘은 같은 목록에 함께 뜨지만(내 줄에 「나」, 방장 줄에 「방장」)
/// 뜻이 다르다 — 하나는 신원, 하나는 **역할**이다. 같은 Primary 알약으로 그리면 같은 종류의
/// 표시로 읽힌다.
public struct HostBadge: View {
    public init() {}

    public var body: some View {
        Text("방장")
            .moyeotaText(inheritedBodyLargeType(11, .bold), color: MoyeotaColor.TextMute)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(MoyeotaColor.SurfaceSoft, in: Capsule(style: .circular))
    }
}

import MoyeotaDomain
import Observation
import PresentationCore
import SwiftUI

/// 입력이 멈췄다고 보는 시간. 10 프로필 만들기와 같은 값이다 — 같은 입력에 다른 반응 속도를 주면
/// 사용자는 둘 중 하나가 고장 났다고 느낀다.
private let NICKNAME_DEBOUNCE_MS = 500

/// 서버 설정의 기본 이미지 키(`profile/presets/default.png`)가 URL 끝에 남기는 조각.
/// 프리셋 16장은 `01.png` 부터 `16.png` 라 이 이름과 겹치지 않는다.
private let DEFAULT_IMAGE_PATH_SUFFIX = "/default.png"

/// 36 닉네임 입력의 오류 문구. nil 이면 보여 줄 오류가 없다.
///
/// 문구는 10 프로필 만들기와 **글자 하나까지 같다** — 같은 규칙을 어겼는데 화면마다 다른 말을 하면
/// 사용자는 규칙이 다르다고 읽는다. 형식 문구는 `NicknamePolicy.validate` 가 그대로 돌려준다.
///
/// 두 가지는 오류로 치지 않는다:
/// - **빈 입력** — "아직 안 썼다"이지 틀린 게 아니다(10 과 같은 규칙). 「저장」 이 꺼져 있어 충분하다.
/// - **현재 닉네임 그대로** — 바꿀 게 없다는 뜻이고, 자기 닉네임은 서버에 물으면 당연히 「사용 중」으로
///   돌아온다. 그 응답을 그대로 띄우면 자기 이름이 남의 것처럼 보인다.
func nicknameEditError(
    input: String,
    currentNickname: String?,
    check: NicknameCheckState
) -> String? {
    if input.isEmpty { return nil }
    if let formatError = NicknamePolicy.validate(raw: input) { return formatError }
    if isNicknameUnchanged(input: input, currentNickname: currentNickname) { return nil }
    switch check {
    case .taken: return "이미 사용 중인 닉네임이에요"
    case .invalidFormat: return "닉네임은 한글·영문·숫자 2~10자로 입력해 주세요"
    default: return nil
    }
}

/// 「저장」 을 누를 수 있는가 — 2~10자 규칙을 만족하고, 지금 닉네임과 다르고, 중복이 아니고, 저장 중이 아니다.
///
/// **확인 중(`NicknameCheckState.checking`)이거나 확인에 실패(`NicknameCheckState.unknown`)해도 막지 않는다.**
/// 10 과 같은 판단이다: 확인과 저장 사이에 누가 그 닉네임을 가져갈 수 있으므로 최종 판정은 어차피
/// `PATCH /users/me` 의 409 다. 네트워크가 나쁠 때 버튼이 영영 꺼져 있는 쪽이 더 큰 손해다.
///
/// **이건 「닉네임만의」 판정이다.** 화면의 「저장」 게이트는 `canSaveProfile` 이고, 이 함수는 그 안의
/// 한 조각으로만 쓰인다 — 사진만 바꾼 저장을 여기서 판단하려 들면 `isNicknameUnchanged` 가 영영
/// 막는다(그게 이 화면의 원래 버그였다).
func canSaveNickname(
    input: String,
    currentNickname: String?,
    check: NicknameCheckState,
    saving: Bool = false
) -> Bool {
    if saving { return false }
    if !NicknamePolicy.isValid(raw: input) { return false }
    if isNicknameUnchanged(input: input, currentNickname: currentNickname) { return false }
    return check != .taken && check != .invalidFormat
}

/// 서버가 준 현재 닉네임과 같은 값인가. 앞뒤 공백은 서버 VO 도 strip 하므로 비교에서 무시한다.
///
/// UTF-16 단위로 비교한다. Swift `==` 는 정규화가 다른 두 문자열(`가` NFC·NFD)을 같다고 보는데, 원본은 다르다고 본다.
/// 같다고 보면 자모로 풀린 입력이 「안 건드린 닉네임」이 되어 `canSaveProfile` 의 형식 검사를 건너뛴다.
func isNicknameUnchanged(input: String, currentNickname: String?) -> Bool {
    guard let currentNickname else { return false }
    return input.trim().utf16.elementsEqual(currentNickname.trim().utf16)
}

/// 입력란의 닉네임이 「서버에 보낼 변경」인가.
///
/// **빈 입력은 변경이 아니다.** 닉네임이 없는 계정에는 서버가 마스킹된 실명(`김*윤`)을 표시 이름으로
/// 내려주는데 그 값은 닉네임 규칙에 안 맞아 입력란을 채우지 않는다(QA 113 O1). 그래서 그 사용자의
/// 입력란은 열자마자 비어 있다 — 이걸 "닉네임을 지웠다"로 읽으면 못 쓰는 값(빈 문자열)을 건드린 것이
/// 되어 `canSaveProfile` 이 **사진만 고른 저장까지 막는다.**
func isNicknameEdited(input: String, currentNickname: String?) -> Bool {
    !input.isEmpty && !isNicknameUnchanged(input: input, currentNickname: currentNickname)
}

/// 이 화면에서 사진에 대해 내린 결정. **3상태여야 한다** — `imageKey: String?` 하나로는 표현할 수 없다.
///
/// 서버에서 `imageKey = null` 은 "되돌려라"가 아니라 **"건드리지 마라"** 다(PATCH 는 넘어온 필드만
/// 갱신한다). 기본 이미지로 되돌리는 건 `DELETE /api/v1/users/me/profile-image` 라는 **다른 요청**이고,
/// 기본 키를 imageKey 로 보내면 프리셋 목록 밖이라 400 `USER112` 로 거절된다. 둘을 하나로 접으면
/// 「안 골랐다」와 「기본으로 돌려라」가 같은 값이 되어, 화면을 열고 사진은 손도 안 댄 사용자의
/// 「저장」 이 멀쩡한 사진을 지운다.
public enum ImageIntent: Hashable, Sendable {
    /// 사진은 그대로 둔다 — PATCH 에 imageKey 를 싣지 않고 DELETE 도 보내지 않는다.
    case none

    /// 격자에서 고른 한 장. `key` 는 목록이 준 `ProfileImage.key` 그대로다(URL 을 넣으면 400 `USER112`).
    case pick(key: String)

    /// 기본 이미지로 되돌린다 — PATCH 가 아니라 DELETE 로 나간다. 멱등하다.
    case reset
}

/// 36 의 「저장」 게이트. **닉네임이든 사진이든 하나라도 바뀌면 켠다.**
///
/// `canSaveNickname` 을 그대로 쓰면 안 되는 이유가 이 함수가 있는 이유다 — 그쪽은 프리필된 닉네임을
/// 그대로 둔 경우를 "바꿀 게 없다"로 판정하므로, **사진만 고른 사용자의 「저장」 이 영원히 꺼진다.**
///
/// 단 **닉네임을 건드렸는데 그 값이 못 쓰는 값이면**(형식 위반·중복) 사진만 바뀌었어도 끈다.
/// 서버는 PATCH 를 한 요청으로 받아 하나라도 틀리면 **요청 전체를 거절**한다 — 깨진 닉네임을 같이
/// 실어 보내면 400/409 가 돌아오고 **사진도 안 바뀐다.** 버튼을 켜 두면 사용자는 눌러 보고,
/// 바뀐 게 없는 이유를 닉네임 오류 문구에서 유추해야 한다.
///
/// 「건드렸는가」의 판정은 `isNicknameEdited` 다 — 빈 입력은 건드린 것으로 세지 않는다(그 주석 참조).
///
/// - Parameter imageIntent: `ImageIntent.none` 이 아니면 사진에 변경이 있다. `ImageIntent.reset` 도 변경이다
///   — 서버 호출이 DELETE 로 갈라질 뿐 「저장할 게 있다」는 사실은 같다.
func canSaveProfile(
    nickname: String,
    currentNickname: String?,
    check: NicknameCheckState,
    imageIntent: ImageIntent,
    saving: Bool = false
) -> Bool {
    if saving { return false }
    let nicknameEdited = isNicknameEdited(input: nickname, currentNickname: currentNickname)
    // 건드린 닉네임이 쓸 수 있는 값인지는 닉네임만의 판정에 그대로 맡긴다 — 두 곳에서 따로
    // 판단하면 10 프로필 만들기와 규칙이 갈린다. saving 은 위에서 이미 걸렀다.
    if nicknameEdited && !canSaveNickname(input: nickname, currentNickname: currentNickname, check: check, saving: false) {
        return false
    }
    return nicknameEdited || imageIntent != ImageIntent.none
}

/// 서버가 준 사진이 「아직 아무것도 안 고른」 기본 이미지인가.
///
/// 서버는 imageUrl 을 비워 보내지 않는다 — 고른 적 없는 사용자에게도 기본 이미지의 전체 주소를 준다.
/// 기본 키(`profile/presets/default.png`)는 프리셋 목록 16장 **밖**이라, URL 이 그 파일 이름으로
/// 끝나는 것만으로 「안 고름」이 구분된다.
///
/// **URL 에서 프리셋 키를 역추적하지는 않는다.** 그건 base-url 이 바뀌거나 쿼리스트링이 붙으면 조용히
/// 빗나간다. 여기서 보는 건 파일 이름 하나뿐이고, 틀려도 손해는 「되돌리기」 한 줄이 더 보이거나 덜
/// 보이는 것뿐이다(되돌리기 자체는 멱등하다).
///
/// nil 도 기본으로 본다. imageUrl 이 nil 인 건 조회 실패거나 구버전 서버라는 뜻이고
/// (`UserNameState.resolved` 주석), 그때는 「되돌리기」를 권할 근거가 없다.
///
/// 쿼리스트링과 fragment 는 떼고 본다 — 지금 CDN 은 쿼리를 붙이지 않지만(`max-age` 1년 고정,
/// 리사이즈 파라미터도 없다) 캐시 버스터가 붙는 날 판정이 조용히 뒤집히는 쪽이 나쁘다.
func isDefaultProfileImage(imageUrl: String?) -> Bool {
    guard let imageUrl else { return true }
    return imageUrl.prefix { $0 != "?" }.prefix { $0 != "#" }.hasSuffix(DEFAULT_IMAGE_PATH_SUFFIX)
}

/// 「기본 이미지로 되돌리기」를 보여 줄 것인가.
///
/// 기본 이미지를 쓰는 사람이 아무것도 고르지 않은 상태에서는 **누를 이유가 없다** — 멱등한 DELETE 를
/// 한 번 더 보내는 것뿐이고 사용자에게는 아무 일도 안 일어난 것으로 보인다. 그래서 끈다.
/// 16장 중 하나를 쓰고 있거나(`isDefaultProfileImage` 가 false) 이 화면에서 한 장을 골랐으면 켠다.
///
/// 비활성이 아니라 **감춘다.** 이 앱은 화면 본문에 `TextButton` 을 쓰지 않아 이 자리는 파란 굵은 글씨
/// 한 줄인데, 회색으로 죽은 파란 글씨는 눌러도 안 되는 고장으로 읽힌다.
func canResetProfileImage(usingDefaultImage: Bool, imageIntent: ImageIntent) -> Bool {
    if case .pick = imageIntent { return true }
    return !usingDefaultImage
}

/// `onNicknameChange` 의 입력 정리. 원본 `filter { !isWhitespace() }.take(10)` 와 같게 **UTF-16 단위**로 자른다
/// — 문자소로 세면 자모로 풀린 입력이나 이모지에서 글자 수가 원본·카운터와 어긋난다.
private func normalizedNicknameInput(raw: String) -> String {
    let filtered = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !$0.isKotlinWhitespace }))
    return String(decoding: filtered.utf16.prefix(NicknamePolicy.MAX_LENGTH), as: UTF16.self)
}

/// 36 프로필 수정의 상태·저장.
///
/// 입력값을 화면(`@State`)이 아니라 여기에 두는 이유: 프리필 값이 **서버 조회 결과**로
/// 늦게 도착한다. 화면이 들고 있으면 "아직 못 받은 이름"과 "사용자가 지운 이름"을 구분할 수 없다.
///
/// 원본 `viewModelScope` 는 `Main.immediate` 라 `launch` 의 첫 줄이 호출 자리에서 바로 돈다. `Task` 는 다음 차례에야
/// 돌므로, 첫 중단점 앞의 상태 변경(`saving = true` 등)은 `launch` **앞에** 둔다. 안 그러면 「저장」 을 연달아 눌렀을 때
/// 두 번 모두 게이트를 통과한다.
@MainActor
@Observable
public final class ProfileEditViewModel {

    public struct UiState: Equatable, Sendable {
        public var nickname: String
        /// 서버가 준 현재 표시 이름. nil 이면 아직 못 받았거나 서버에 이름이 없다.
        public var currentNickname: String?
        public var check: NicknameCheckState
        /// 고를 수 있는 프리셋. 조회에 실패하면 **빈 목록으로 남는다** — 화면은 격자만 접고
        /// 닉네임 수정은 그대로 된다. 사용자가 고칠 게 없는 실패에 문구를 띄우지 않는다.
        public var images: [ProfileImage]
        /// 사진 목록 조회가 실패했다. **빈 목록과 다르게** 그려야 한다 — 섞으면 섹션이 통째로
        /// 사라져 「이 앱에는 사진 기능이 없다」로 읽힌다.
        public var imagesLoadFailed: Bool
        /// 이 화면에서 사진에 내린 결정. 「저장」 을 누를 때까지 서버에 나가지 않는다.
        public var imageIntent: ImageIntent
        /// 진입 시점의 사진이 기본 이미지인가. 「되돌리기」를 보일지의 근거다
        /// (`canResetProfileImage`). 기본값 true 는 조회가 끝나기 전에 되돌리기가
        /// 스쳐 보이지 않게 하려는 것이다.
        public var usingDefaultImage: Bool
        public var saving: Bool
        /// 저장 실패 문구. 중복·형식 오류는 필드가 말하므로 여기엔 담지 않는다.
        public var errorMessage: String?
        public var saved: Bool

        public init(
            nickname: String = "",
            currentNickname: String? = nil,
            check: NicknameCheckState = .idle,
            images: [ProfileImage] = [],
            imagesLoadFailed: Bool = false,
            imageIntent: ImageIntent = .none,
            usingDefaultImage: Bool = true,
            saving: Bool = false,
            errorMessage: String? = nil,
            saved: Bool = false
        ) {
            self.nickname = nickname
            self.currentNickname = currentNickname
            self.check = check
            self.images = images
            self.imagesLoadFailed = imagesLoadFailed
            self.imageIntent = imageIntent
            self.usingDefaultImage = usingDefaultImage
            self.saving = saving
            self.errorMessage = errorMessage
            self.saved = saved
        }
    }

    public private(set) var uiState = UiState()

    @ObservationIgnored private let repository: any AuthRepository
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let scope = ViewModelScope()

    // 진행 중인 중복 확인. 다음 타자가 들어오면 취소한다 — 늦게 도착한 옛 응답이 최신 입력을
    // 덮어쓰는 사고를 구조적으로 막는다(10 과 같은 장치).
    @ObservationIgnored private(set) var checkJob: Task<Void, Never>?
    @ObservationIgnored private(set) var imagesJob: Task<Void, Never>?
    /// 테스트가 저장이 끝나기를 기다리는 손잡이다(원본 테스트의 `advanceUntilIdle` 자리).
    @ObservationIgnored private(set) var saveJob: Task<Void, Never>?
    @ObservationIgnored private var seeded = false

    public init(
        repository: any AuthRepository,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.repository = repository
        self.sleep = sleep
        loadImages()
    }

    /// 고를 수 있는 프리셋 목록을 받는다. **실패해도 화면을 막지 않는다** — 격자만 비고 닉네임 수정은
    /// 그대로 된다. 사용자가 할 수 있는 일이 없는 실패에 배너를 띄우면 닉네임을 고치러 들어온
    /// 사람에게 고장만 보여 주는 셈이다.
    ///
    /// 저장이 400 `USER112` 로 거절될 때 다시 불린다(그때는 앱이 가진 목록이 낡았다는 뜻이다).
    /// 그 재조회가 겹칠 수 있어 `imagesJob` 으로 마지막 요청만 살려 둔다.
    private func loadImages() {
        imagesJob?.cancel()
        uiState.imagesLoadFailed = false
        let repository = self.repository
        imagesJob = scope.launch { [weak self] in
            let images: [ProfileImage]?
            do {
                images = try await repository.getProfileImages()
            } catch {
                // 태스크 취소는 실패가 아니다 — 새 요청이 띄운 상태를 옛 요청이 「실패」로 덮으면 안 된다.
                // `isCancellation` 으로 거르지 않는다: 살아 있는 태스크의 `URLError(.cancelled)` 에는 대체한 요청이 없어,
                // 거르면 「프로필 사진」 섹션이 재시도 버튼도 없이 사라진다.
                if Task.isCancelled { return }
                images = nil
            }
            guard !Task.isCancelled, let self else { return }
            // 실패를 그냥 돌아가 버리면 「프로필 사진」 섹션이 **흔적 없이 사라진다** —
            // 바로 그 사진을 바꾸러 들어온 사용자에게 화면이 아무 말도 하지 않고, 기능이 없는 건지
            // 고장인지 구분할 길이 없다. 상태로 남겨 화면이 「다시 시도」를 그리게 한다.
            guard let images else {
                self.uiState.imagesLoadFailed = true
                return
            }
            self.uiState.images = images
            self.uiState.imagesLoadFailed = false
        }
    }

    /// 사진 목록 조회 실패 뒤 사용자가 「다시 시도」를 눌렀을 때.
    public func retryImages() {
        loadImages()
    }

    /// 서버가 준 표시 이름과 사진을 반영한다. **비교 기준(`UiState.currentNickname`)은 올 때마다 갱신**하고,
    /// **입력란은 처음 한 번만** 채운다 — 조회가 두 번 끝나도(탭 복귀, 저장 직후 재조회) 사용자가
    /// 고치던 글자를 되돌리지 않기 위해서다. 기준까지 한 번만 세우면 저장 직후 다시 들어왔을 때
    /// 옛 이름이 기준으로 굳어, 방금 저장한 자기 닉네임이 「이미 사용 중」으로 보인다(QA 113 O2).
    ///
    /// 표시 이름이 닉네임 규칙에 안 맞으면 입력란에 넣지 않는다. 닉네임이 없는 계정에는 서버가
    /// 마스킹된 실명(`김*윤`)을 내려주는데, 그걸 채우면 열자마자 형식 오류가 뜬다(QA 113 O1).
    /// 조회가 늦게 끝난 사이 사용자가 벌써 입력했다면 그 입력은 지킨다.
    ///
    /// `imageUrl` 은 **격자의 선택에 쓰지 않는다** — 지금 쓰는 사진의 key 를 알려 주는 창구가 서버에
    /// 없어서다(상세는 `ProfileEditScreen` 주석). 여기서 쓰는 건 「기본 이미지인가」 하나뿐이고,
    /// 그건 「되돌리기」를 보일지만 정한다. `UiState.imageIntent` 는 건드리지 않는다 —
    /// 사용자가 이미 고른 선택을 뒤늦게 끝난 재조회가 되돌리면 안 된다.
    ///
    /// ### `seeded` 는 **실제로 채웠을 때만** 세운다
    /// 예전에는 첫 호출에서 무조건 세웠다. 그래서 **로그인 직후** 이 화면을 열면 — 그때
    /// `UserNameState` 는 아직 `loading` 이라 `name` 이 nil 이다 — 첫 호출이 아무것도 채우지 못한 채
    /// 시드를 태우고, 뒤이어 이름이 도착해도 입력란이 **영영 빈 채로 남았다.**
    /// 사용자에게는 「닉네임이 없는 계정」으로 보이고, 0/10 짜리 빈 칸에 새 이름을 지어 넣게 된다.
    /// (실기 검증에서 잡혔다 — 로그인 → 마이페이지 → 프로필 수정을 빠르게 밟으면 재현된다.)
    ///
    /// 채우지 못하는 경우(`name` 이 nil 이거나 마스킹된 실명이라 규칙에 안 맞거나, 사용자가 벌써
    /// 입력했거나)에는 시드를 남겨 둔다. 규칙에 안 맞는 이름만 계속 오면 시드는 영영 안 타지만
    /// `prefillable` 이 false 라 아무 일도 일어나지 않으므로 해롭지 않다.
    public func prefill(name: String?, imageUrl: String?) {
        let prefillable = name.map { NicknamePolicy.isValid(raw: $0) } ?? false
        let seedNow = !seeded && prefillable && uiState.nickname.isEmpty
        if seedNow { seeded = true }
        uiState.currentNickname = name
        if seedNow, let name { uiState.nickname = name }
        uiState.usingDefaultImage = isDefaultProfileImage(imageUrl: imageUrl)
    }

    /// 입력 변경. 공백은 규칙상 못 쓰는 문자라 오류로 튕기기보다 조용히 걸러 받는다(10 과 같다).
    /// 형식이 맞고 지금 닉네임과 다를 때에만, 입력이 멈춘 뒤 서버에 중복을 묻는다.
    public func onNicknameChange(raw: String) {
        let value = normalizedNicknameInput(raw: raw)
        checkJob?.cancel()
        // 입력이 바뀌면 직전 확인 결과는 더 이상 이 글자에 대한 답이 아니다 — 함께 비운다.
        uiState.nickname = value
        uiState.check = .idle
        uiState.errorMessage = nil
        let current = uiState.currentNickname
        // 형식이 안 맞으면 물어볼 것도 없고, 내 닉네임을 물으면 「사용 중」이 돌아온다.
        if !NicknamePolicy.isValid(raw: value) || isNicknameUnchanged(input: value, currentNickname: current) {
            return
        }
        let repository = self.repository
        let sleep = self.sleep
        checkJob = scope.launch { [weak self] in
            do {
                try await sleep(.milliseconds(NICKNAME_DEBOUNCE_MS))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.uiState.check = .checking
            let result: NicknameCheckState
            do {
                result = try await repository.isNicknameTaken(nickname: value.trim()) ? .taken : .available
            } catch {
                // 다음 타자로 대체된 요청만 버린다 — 옛 요청이 새 요청의 상태를 덮으면 안 된다.
                // `isCancellation` 으로 거르지 않는다: 태스크가 살아 있는데 온 `URLError(.cancelled)` 에는 대체한 요청이
                // 없어, 거르면 「사용할 수 있는지 확인하고 있어요」가 다음 타자까지 남는다.
                guard !Task.isCancelled else { return }
                result = error.isNicknameFormatError() ? .invalidFormat : .unknown
            }
            guard !Task.isCancelled else { return }
            self?.uiState.check = result
        }
    }

    /// 격자에서 한 장을 골랐다. **서버에 바로 보내지 않는다** — 이 화면의 커밋 지점은 「저장」 하나다.
    /// 직전 저장 실패 문구는 함께 지운다: 그 문구는 지금 선택에 대한 답이 아니다.
    public func onImagePick(key: String) {
        uiState.imageIntent = .pick(key: key)
        uiState.errorMessage = nil
    }

    /// 「기본 이미지로 되돌리기」. 여기서도 **서버 호출은 하지 않는다** — 되돌리기만 즉시 반영되면
    /// 「저장을 안 눌렀는데 사진이 바뀜」이 생긴다. DELETE 는 `save` 가 PATCH 뒤에 함께 보낸다.
    ///
    /// ### 이미 기본 이미지인 사람에게는 `ImageIntent.none` 으로 접는다
    /// 그 사람에게 이 줄이 보이는 경우는 **이 화면에서 한 장을 골랐을 때뿐**이다
    /// (`canResetProfileImage`). 그때 되돌리기는 「기본으로 바꾼다」가 아니라 **「고른 것 취소」** 다 —
    /// 서버 상태는 이미 기본이라 바꿀 게 없다.
    ///
    /// `ImageIntent.reset` 으로 두면 화면이 거짓말을 한다: 선택 링이 풀리고 이 줄도 사라져 **진입
    /// 직후와 구분되지 않는데** 「저장」만 켜진 채 남고, 누르면 아무것도 바꾸지 않는 DELETE 가 나가고
    /// 「저장했다」며 35 로 돌아간다. `none` 으로 접으면 「저장」이 함께 꺼져 화면과 버튼이 같은 말을 한다.
    public func onImageReset() {
        uiState.imageIntent = uiState.usingDefaultImage ? ImageIntent.none : ImageIntent.reset
        uiState.errorMessage = nil
    }

    /// 바뀐 것만 서버에 보낸다. **PATCH 를 먼저, DELETE 를 나중에.**
    ///
    /// 순서가 중요하다: 되돌리기(DELETE)를 먼저 보내면 뒤의 닉네임 PATCH 가 409 로 실패했을 때
    /// **사진만 이미 기본으로 돌아간 상태**가 남는다. 사용자는 저장이 실패했다는 배너를 보면서
    /// 사진이 사라진 것을 보게 된다. PATCH 가 먼저면 실패 시 아무것도 바뀌지 않는다.
    ///
    /// **바뀌지 않은 닉네임은 싣지 않는다.** 서버는 받아 주지만(같은 값으로 갱신) 「빠진 필드는 안
    /// 건드린다」가 이 앱이 지켜 온 계약이고, 안 보내면 자기 닉네임에 대한 중복 판정 같은 변수도 없다.
    ///
    /// 성공하면 `UiState.saved` 로 화면 이동을 알린다. 여기서 이름·사진 캐시를 직접 고치지 않는다
    /// — 단일 출처는 `UserProfileViewModel` 이고, 그쪽을 다시 조회하는 일은 내비게이션 층이 맡는다.
    public func save() {
        let state = uiState
        guard canSaveProfile(
            nickname: state.nickname,
            currentNickname: state.currentNickname,
            check: state.check,
            imageIntent: state.imageIntent,
            saving: state.saving
        ) else { return }
        let nickname = isNicknameEdited(input: state.nickname, currentNickname: state.currentNickname)
            ? state.nickname.trim()
            : nil
        let imageKey: String? = if case .pick(let key) = state.imageIntent { key } else { nil }
        let resetImage = state.imageIntent == ImageIntent.reset
        uiState.saving = true
        uiState.errorMessage = nil
        let repository = self.repository
        saveJob = scope.launch { [weak self] in
            do {
                // 둘 다 없으면 PATCH 자체를 보내지 않는다 — 되돌리기만 고른 경우다.
                if nickname != nil || imageKey != nil {
                    try await repository.updateProfile(nickname: nickname, imageKey: imageKey)
                    // PATCH 가 끝나면 비교 기준을 옮긴다. 뒤의 DELETE 가 네트워크로 실패해 사용자가
                    // 「저장」 을 다시 눌렀을 때, 이미 서버에 반영된 닉네임을 또 싣지 않기 위해서다.
                    if let nickname { self?.uiState.currentNickname = nickname }
                }
                if resetImage { try await repository.resetProfileImage() }
                self?.uiState.saving = false
                self?.uiState.saved = true
            } catch {
                // 태스크가 취소되는 건 뷰모델이 사라질 때뿐이라 그때만 버린다. `isCancellation` 으로 거르지 않는다:
                // 태스크가 살아 있는데 온 `URLError(.cancelled)` 에서 `saving` 을 내리지 않으면 스피너가 멈추지 않고
                // 입력란·격자·되돌리기가 잠긴 채 남는다. 원본도 `catch (e: Exception)` 하나로 잠금을 푼다.
                guard let failure = authFailureOnLiveTask(error: error) else { return }
                self?.onSaveFailed(failure)
            }
        }
    }

    private func onSaveFailed(_ error: any Error) {
        let authError = (error as? AuthException)?.error
        let duplicated = authError == .nicknameDuplicated
        let invalidFormat = error.isNicknameFormatError()
        let invalidImage = authError == .invalidProfileImage
        // 목록 밖의 키였다 — 사용자가 고칠 입력이 아니라 **앱이 가진 목록이 낡은 것**이다.
        // 이 화면에 「다시 불러오기」를 누를 자리가 없으므로 앱이 스스로 다시 받는다.
        // 이 줄을 지우면 배너는 「다시 골라 주세요」라고 하는데 격자에는 그 400 을 만든 낡은 키가
        // 그대로 남아, 같은 칸을 다시 눌러 같은 400 을 받는 고리에 갇힌다.
        if invalidImage { loadImages() }
        uiState.saving = false
        // 중복·형식은 필드가 빨갛게 말해 주고 「저장」 도 함께 꺼진다
        // — 같은 문장을 버튼 아래에 한 번 더 띄우지 않는다.
        if duplicated {
            uiState.check = .taken
        } else if invalidFormat {
            uiState.check = .invalidFormat
        }
        // 같은 키를 다시 눌러도 같은 400 이다. 그 선택을 버려야 사용자가 「저장」 을
        // 다시 눌렀을 때 최소한 닉네임은 저장된다(서버는 imageKey 를 먼저 검사해
        // **요청 전체를 거절**했으므로 지금은 닉네임도 안 바뀐 상태다).
        if invalidImage { uiState.imageIntent = .none }
        // 사진 오류를 닉네임 필드 오류로 돌리면 거짓이다 — 닉네임은 멀쩡하다.
        // invalidProfileImage 는 여기(배너)로 떨어진다.
        uiState.errorMessage = duplicated || invalidFormat ? nil : error.authUserMessage()
    }
}

private extension Error {
    /// 닉네임 형식 오류는 **서버 코드 두 개로 온다** — 도메인 VO 가 먼저 걸리면 400 `USER107`,
    /// Bean Validation 이 먼저 걸리면 `INVALID_REQUEST(message = "nickname: …")` 다.
    /// 사용자에게는 같은 사실이므로 한 판단으로 모은다(10 의 중복 확인과 같은 규칙).
    func isNicknameFormatError() -> Bool {
        guard let authException = self as? AuthException else { return false }
        return authException.error == .invalidNickname
            || (authException.error == .invalidRequest && authException.serverMessage?.hasPrefix("nickname") == true)
    }
}

/// 36 프로필 수정 — `PATCH /api/v1/users/me`(nickname, imageKey)와
/// `DELETE /api/v1/users/me/profile-image`(되돌리기) 진입점.
///
/// 프리셋 목록은 진입 즉시 받는다(`ProfileEditViewModel` 의 init). 받지 못해도 화면은 열린다.
///
/// - Parameter userName: 35 와 같은 인스턴스(`UserProfileViewModel`)의 표시 이름·사진. 프리필 기준값이다.
///   조회가 끝나기 전에 들어올 수 있어 `UserNameState.resolved` 가 될 때 반영한다.
/// - Parameter onSaved: 저장 성공. 내비게이션 층이 표시 이름과 사진을 다시 조회하고 35 로 되돌린다.
public struct ProfileEditRoute: View {
    private let userName: UserNameState
    private let onBack: () -> Void
    private let onSaved: () -> Void

    @HostedViewModel private var viewModel: ProfileEditViewModel

    public init(
        repository: any AuthRepository,
        userName: UserNameState = .loading,
        onBack: @escaping () -> Void = {},
        onSaved: @escaping () -> Void = {}
    ) {
        self.userName = userName
        self.onBack = onBack
        self.onSaved = onSaved
        _viewModel = HostedViewModel(wrappedValue: ProfileEditViewModel(repository: repository))
    }

    public var body: some View {
        let state = viewModel.uiState
        // 원본 Route 도 `imagesLoadFailed`·`onRetryImages` 를 넘기지 않는다. 그래서 「다시 시도」는 앱에서 그려지지
        // 않는다 — 동작을 그대로 옮겼고, 최종 보고에 원본 결함으로 적었다.
        ProfileEditScreen(
            nickname: state.nickname,
            currentNickname: state.currentNickname,
            check: state.check,
            images: state.images,
            imageIntent: state.imageIntent,
            usingDefaultImage: state.usingDefaultImage,
            saving: state.saving,
            errorMessage: state.errorMessage,
            onNicknameChange: { viewModel.onNicknameChange(raw: $0) },
            onImagePick: { viewModel.onImagePick(key: $0) },
            onImageReset: { viewModel.onImageReset() },
            onSave: { viewModel.save() },
            onBack: onBack
        )
        .task(id: userName) {
            if case .resolved(let name, let imageUrl) = userName {
                viewModel.prefill(name: name, imageUrl: imageUrl)
            }
        }
        .task(id: state.saved) {
            if state.saved { onSaved() }
        }
    }
}

import Foundation
import MoyeotaDomain
import PresentationCore
import Testing
@testable import FeatureMyPage

/// 36 프로필 수정이 **무엇을 서버에 보내는가** — `ProfileEditViewModel.save` 가 고른 값을
/// Repository 까지 실제로 넘기는지 본다.
///
/// 이 테스트가 따로 있어야 하는 이유: `ProfileSaveRulesTest` 는 「저장」 버튼이 켜지는가(순수 게이트)
/// 까지만 보고, data 쪽 `RemoteAuthRepositoryTest.이미지 키만 바꿀 때 닉네임을 싣지 않는다` 는
/// 「Repository 에 들어온 imageKey 가 PATCH 본문에 실리는가」까지만 본다. **그 둘 사이가 빈다** —
/// 화면이 애초에 `imageKey = nil` 로 부르면 양쪽 테스트가 다 통과하면서 사진은 저장되지 않는다.
/// 그게 이번 작업 전 이 화면의 실제 결함이었다.
///
/// 특히 세 가지를 못 박는다:
/// - 고른 key 가 **그 값 그대로** PATCH 로 간다(URL 로 바뀌면 400 `USER112` 다)
/// - 되돌리기는 **PATCH 가 아니라 DELETE** 다. `updateProfile(imageKey: nil)` 은 서버에서
///   「건드리지 마라」라서, 되돌리기를 그렇게 부르면 아무 일도 일어나지 않는다
/// - 되돌리기와 닉네임을 함께 저장할 때 **PATCH 가 먼저** 나간다(닉네임이 409 로 실패했을 때
///   사진만 기본으로 돌아간 상태가 남지 않게)
///
/// 화면을 그리지는 않는다. 여기서 보는 건 뷰모델과 Repository 사이의 호출뿐이다.
/// 원본 테스트 디스패처의 `advanceUntilIdle` 자리는 대기 함수 주입과 뷰모델의 태스크 손잡이가 맡는다.
@MainActor
@Suite struct ProfileEditSaveTest {

    @Test("고른 이미지의 key 를 그대로 PATCH 에 싣는다")
    func pickedKeyGoesToPatch() async {
        let repository = ProfileEditFakeAuthRepository()
        let viewModel = makeViewModel(repository)
        viewModel.prefill(name: "성윤", imageUrl: preset("07"))
        await viewModel.advanceUntilIdle()

        viewModel.onImagePick(key: "profile/presets/03.png")
        viewModel.save()
        await viewModel.advanceUntilIdle()

        // 닉네임은 건드리지 않았으니 nil 이고, key 는 목록이 준 값 그대로여야 한다.
        #expect(repository.patches == [Patch(nil, "profile/presets/03.png")])
        // 사진을 고른 저장은 되돌리기가 아니다 — DELETE 가 함께 나가면 방금 고른 사진이 지워진다.
        #expect(repository.resetCount == 0)
        #expect(viewModel.uiState.saved)
    }

    @Test("되돌리기는 PATCH 가 아니라 DELETE 로 나간다")
    func resetGoesToDelete() async {
        let repository = ProfileEditFakeAuthRepository()
        let viewModel = makeViewModel(repository)
        viewModel.prefill(name: "성윤", imageUrl: preset("03"))
        await viewModel.advanceUntilIdle()

        viewModel.onImageReset()
        viewModel.save()
        await viewModel.advanceUntilIdle()

        // PATCH 는 **아예 나가지 않는다.** `updateProfile(nil, nil)` 로 부르면 서버는 204 를
        // 주면서 아무것도 바꾸지 않아, 사용자에게는 「저장했는데 사진이 그대로」로 보인다.
        #expect(repository.patches.isEmpty)
        #expect(repository.resetCount == 1)
        #expect(viewModel.uiState.saved)
    }

    /// 기본 이미지를 쓰는 사람에게 「되돌리기」는 **「고른 것 취소」** 다 — 서버 상태가 이미 기본이라
    /// 되돌릴 것이 없다. 그 경우 `onImageReset` 이 `ImageIntent.reset` 을 세우면 화면이 거짓말을 한다:
    /// 선택 링이 풀리고 되돌리기 줄도 사라져 **진입 직후와 구분되지 않는데** 「저장」만 켜진 채 남고,
    /// 누르면 아무것도 바꾸지 않는 DELETE 가 나가고 「저장했다」며 35 로 돌아간다.
    ///
    /// 리뷰에서 실제로 잡힌 결함이라 회귀 테스트로 남긴다.
    @Test("기본 이미지 사용자가 고른 뒤 되돌리면 저장이 꺼지고 아무 요청도 나가지 않는다")
    func defaultUserCancelPick() async {
        let repository = ProfileEditFakeAuthRepository()
        let viewModel = makeViewModel(repository)
        // 한 번도 고른 적 없는 사용자 — 서버는 그래도 기본 이미지의 전체 URL 을 준다
        viewModel.prefill(name: "성윤", imageUrl: "https://cdn.moyeota.co.kr/profile/presets/default.png")
        await viewModel.advanceUntilIdle()

        viewModel.onImagePick(key: "profile/presets/07.png")
        #expect(viewModel.uiState.canSaveNow(), "고르면 저장이 켜져야 한다")

        viewModel.onImageReset()

        #expect(!viewModel.uiState.canSaveNow(), "취소했으니 저장이 꺼져야 한다")
        #expect(viewModel.uiState.imageIntent == ImageIntent.none)

        viewModel.save()
        await viewModel.advanceUntilIdle()

        #expect(repository.patches.isEmpty)
        #expect(repository.resetCount == 0, "바꿀 게 없으니 DELETE 도 나가면 안 된다")
    }

    /// 반대 경우 — 프리셋을 쓰던 사람의 되돌리기는 진짜 되돌리기다. 위 테스트의 수정이
    /// 이쪽을 `ImageIntent.none` 으로 접어 버리지 않았는지 함께 못 박는다.
    @Test("프리셋을 쓰던 사용자의 되돌리기는 DELETE 로 나간다")
    func presetUserResetDeletes() async {
        let repository = ProfileEditFakeAuthRepository()
        let viewModel = makeViewModel(repository)
        viewModel.prefill(name: "성윤", imageUrl: preset("03"))
        await viewModel.advanceUntilIdle()

        viewModel.onImageReset()

        #expect(viewModel.uiState.imageIntent == .reset)
        #expect(viewModel.uiState.canSaveNow(), "바뀌는 게 있으니 저장이 켜져야 한다")

        viewModel.save()
        await viewModel.advanceUntilIdle()

        #expect(repository.resetCount == 1)
    }

    /// **로그인 직후** 이 화면을 열면 프로필 조회가 아직 안 끝나 `prefill(nil, nil)` 이 먼저 온다.
    /// 예전에는 그 호출이 시드를 태워 버려, 뒤이어 이름이 도착해도 입력란이 **영영 빈 채로** 남았다
    /// — 사용자에게는 「닉네임이 없는 계정」으로 보인다. 실기 검증에서 잡힌 결함이라 회귀로 남긴다.
    @Test("조회가 늦게 끝나도 도착한 닉네임으로 입력란을 채운다")
    func lateNameStillSeeds() {
        let viewModel = makeViewModel(ProfileEditFakeAuthRepository())

        // 1) 조회 전 — 화면이 loading 상태의 UserNameState 로 먼저 그려진다
        viewModel.prefill(name: nil, imageUrl: nil)
        #expect(viewModel.uiState.nickname == "")

        // 2) 조회가 끝나 이름이 도착한다
        viewModel.prefill(name: "테스터1", imageUrl: preset("03"))

        #expect(viewModel.uiState.nickname == "테스터1")
        #expect(viewModel.uiState.currentNickname == "테스터1")
    }

    /// 시드를 「실제로 채웠을 때만」 태우는 수정이 **금칙어 가드를 뚫으면 안 된다.**
    /// 서버는 금칙어를 검사하지 않으므로(길이·문자종류만 본다) 다른 경로로 가입한 사용자가
    /// 「모여타」가 든 닉네임을 가질 수 있다. 그 이름을 입력란에 채우면 열자마자 형식 오류가 뜬다.
    /// 비교 기준(`UiState.currentNickname`)에는 그대로 담아야 한다 — 안 그러면 「안 바꿨는데 바꾼 것」이 된다.
    @Test("규칙에 안 맞는 표시 이름은 입력란에 채우지 않는다")
    func invalidNameNotSeeded() {
        let viewModel = makeViewModel(ProfileEditFakeAuthRepository())

        viewModel.prefill(name: "모여타일", imageUrl: preset("03"))

        #expect(viewModel.uiState.nickname == "")
        #expect(viewModel.uiState.currentNickname == "모여타일")
    }

    /// 반대 방향 — 시드는 **한 번만** 돈다. 저장 직후 재조회나 탭 복귀로 `prefill` 이 다시 와도
    /// 사용자가 고치던 글자를 되돌리면 안 된다.
    @Test("채운 뒤에는 재조회가 사용자 입력을 되돌리지 않는다")
    func seedOnlyOnce() {
        let viewModel = makeViewModel(ProfileEditFakeAuthRepository())
        viewModel.prefill(name: "테스터1", imageUrl: preset("03"))

        viewModel.onNicknameChange(raw: "새이름")
        viewModel.prefill(name: "테스터1", imageUrl: preset("03"))

        #expect(viewModel.uiState.nickname == "새이름")
        // 비교 기준은 **올 때마다** 갱신된다 — 안 그러면 방금 저장한 자기 닉네임이 「이미 사용 중」이 된다
        #expect(viewModel.uiState.currentNickname == "테스터1")
    }

    @Test("닉네임과 사진을 함께 바꾸면 한 번의 PATCH 에 둘 다 싣는다")
    func nicknameAndImageInOnePatch() async {
        let repository = ProfileEditFakeAuthRepository()
        let viewModel = makeViewModel(repository)
        viewModel.prefill(name: "성윤", imageUrl: preset("03"))
        await viewModel.advanceUntilIdle()

        viewModel.onNicknameChange(raw: "윤성")
        viewModel.onImagePick(key: "profile/presets/09.png")
        viewModel.save()
        await viewModel.advanceUntilIdle()

        // 두 번 보내면 안 된다 — 서버는 한 요청을 통째로 받거나 통째로 거절한다.
        #expect(repository.patches == [Patch("윤성", "profile/presets/09.png")])
        #expect(repository.resetCount == 0)
    }

    @Test("사진을 건드리지 않은 저장은 imageKey 를 싣지 않는다")
    func untouchedImageNotSent() async {
        let repository = ProfileEditFakeAuthRepository()
        let viewModel = makeViewModel(repository)
        viewModel.prefill(name: "성윤", imageUrl: preset("03"))
        await viewModel.advanceUntilIdle()

        viewModel.onNicknameChange(raw: "윤성")
        viewModel.save()
        await viewModel.advanceUntilIdle()

        // imageKey 는 nil 이어야 한다 — 「건드리지 마라」가 정확히 이 경우의 뜻이다.
        #expect(repository.patches == [Patch("윤성", nil)])
        #expect(repository.resetCount == 0)
    }

    @Test("닉네임을 함께 바꿔도 되돌리기는 PATCH 뒤에 보낸다")
    func deleteAfterPatch() async {
        let repository = ProfileEditFakeAuthRepository()
        let viewModel = makeViewModel(repository)
        viewModel.prefill(name: "성윤", imageUrl: preset("03"))
        await viewModel.advanceUntilIdle()

        viewModel.onNicknameChange(raw: "윤성")
        viewModel.onImageReset()
        viewModel.save()
        await viewModel.advanceUntilIdle()

        // 순서가 뒤집히면, 닉네임이 409 로 실패했을 때 사진만 이미 기본으로 돌아간 상태가 남는다.
        #expect(repository.callOrder == ["PATCH", "DELETE"])
        #expect(repository.patches == [Patch("윤성", nil)])
    }

    @Test("목록 밖의 키라고 거절되면 고른 값을 비우고 목록을 다시 받는다")
    func invalidKeyClearsAndReloads() async {
        let repository = ProfileEditFakeAuthRepository(
            updateFailure: AuthException(error: .invalidProfileImage, serverMessage: "존재하지 않는 프로필 이미지입니다.")
        )
        let viewModel = makeViewModel(repository)
        viewModel.prefill(name: "성윤", imageUrl: preset("03"))
        await viewModel.advanceUntilIdle()
        #expect(repository.imageListCalls == 1)

        viewModel.onImagePick(key: "profile/presets/99.png")
        viewModel.save()
        await viewModel.advanceUntilIdle()

        let state = viewModel.uiState
        // 같은 키를 다시 눌러도 같은 400 이다 — 그 선택을 들고 있으면 사용자가 빠져나올 수 없다.
        #expect(state.imageIntent == ImageIntent.none)
        // 앱이 가진 목록이 낡았다는 뜻이므로 앱이 알아서 다시 받는다(사용자가 누를 자리가 없다).
        #expect(repository.imageListCalls == 2)
        #expect(!state.saved)
        // 사진 오류는 닉네임 필드가 아니라 배너로 떨어진다 — 닉네임은 멀쩡하다.
        // 문구를 여기 복사하지 않고 같은 출처와 비교한다: 문구가 바뀌어도 「배너로 간다」는 사실만 본다.
        #expect(state.errorMessage == AuthException(error: .invalidProfileImage).authUserMessage())
        #expect(state.check != .taken)
        #expect(state.check != .invalidFormat)
    }
}

/// 나간 PATCH 의 본문. `(nickname, imageKey)`.
struct Patch: Equatable, CustomStringConvertible {
    let nickname: String?
    let imageKey: String?

    init(_ nickname: String?, _ imageKey: String?) {
        self.nickname = nickname
        self.imageKey = imageKey
    }

    var description: String { "(\(nickname ?? "nil"), \(imageKey ?? "nil"))" }
}

/// 프리셋 URL. 판정에 쓰이는 건 파일 이름뿐이라 호스트는 CDN 실제 주소 모양만 맞춘다.
func preset(_ number: String) -> String {
    "https://cdn.moyeota.co.kr/profile/presets/\(number).png"
}

/// 디바운스를 기다리지 않는 뷰모델. 원본 테스트의 가상 시간 자리다.
@MainActor
func makeViewModel(_ repository: ProfileEditFakeAuthRepository) -> ProfileEditViewModel {
    ProfileEditViewModel(repository: repository, sleep: { _ in })
}

extension ProfileEditViewModel {
    /// 원본 테스트의 `advanceUntilIdle()`. 저장 실패가 목록 재조회를 띄우므로 저장을 먼저 기다린다.
    func advanceUntilIdle() async {
        await saveJob?.value
        await imagesJob?.value
        await checkJob?.value
    }
}

extension ProfileEditViewModel.UiState {
    /// 화면이 「저장」 활성을 계산하는 것과 **같은 식**을 쓴다(`ProfileEditScreen` 이
    /// `canSaveProfile` 을 그대로 부른다). 여기서 따로 판단하면 테스트와 화면이 갈린다.
    func canSaveNow() -> Bool {
        canSaveProfile(
            nickname: nickname,
            currentNickname: currentNickname,
            check: check,
            imageIntent: imageIntent,
            saving: saving
        )
    }
}

/// 격자에 쓰는 프리셋 두 장. 서버는 16장을 주지만 **이 테스트가 보는 건 장수가 아니라 호출 내용**이라
/// 늘리지 않았다(목록이 16장이라는 건 서버 계약이고 단위 테스트로 못 박을 수 없다).
private let PRESET_PROFILE_IMAGES = [
    ProfileImage(key: "profile/presets/01.png", url: "https://cdn.moyeota.co.kr/profile/presets/01.png"),
    ProfileImage(key: "profile/presets/02.png", url: "https://cdn.moyeota.co.kr/profile/presets/02.png"),
]

/// 36 이 쓰는 네 가지(`updateProfile`·`resetProfileImage`·`getProfileImages`·`isNicknameTaken`)만 기록하는 페이크.
///
/// 나머지 메서드는 이 화면에서 불리면 **테스트가 터져야 한다** — 조용히 기본값을 돌려주면
/// 「저장이 엉뚱한 API 를 부른다」는 사고가 통과한다. 뷰모델의 catch 가 던진 값을 삼키므로 `Issue.record` 로 남긴다.
///
/// 목록 값은 **백엔드 `ProfileImages` 설정 기준**이다. 로컬 DB 가 죽어 실서버로 확인한 값이 아니다.
final class ProfileEditFakeAuthRepository: AuthRepository, @unchecked Sendable {
    private struct Unrelated: Error {}

    let authState: StateFlow<AuthState> = MutableStateFlow(.authenticated(userUuid: "user-uuid"))

    private let lock = NSLock()
    private var imageResults: [Result<[ProfileImage], any Error>]
    private let images: [ProfileImage]
    private let updateFailure: (any Error)?
    private var resetFailures: [any Error]
    /// 중복 확인을 시험마다 다르게 답하는 자리. 없으면 통과시켜 저장 경로만 보게 한다.
    private let nicknameTaken: (@Sendable (String) async throws -> Bool)?
    private var _patches: [Patch] = []
    private var _callOrder: [String] = []
    private var _resetCount = 0
    private var _imageListCalls = 0
    private var _nicknameChecks: [String] = []

    init(
        images: [ProfileImage] = PRESET_PROFILE_IMAGES,
        imageResults: [Result<[ProfileImage], any Error>] = [],
        updateFailure: (any Error)? = nil,
        resetFailures: [any Error] = [],
        nicknameTaken: (@Sendable (String) async throws -> Bool)? = nil
    ) {
        self.images = images
        self.imageResults = imageResults
        self.updateFailure = updateFailure
        self.resetFailures = resetFailures
        self.nicknameTaken = nicknameTaken
    }

    /// 나간 PATCH 의 본문을 보낸 순서대로 담는다.
    var patches: [Patch] { lock.withLock { _patches } }
    /// PATCH 와 DELETE 가 나간 순서. 둘의 **앞뒤**가 이 화면의 계약이다.
    var callOrder: [String] { lock.withLock { _callOrder } }
    var resetCount: Int { lock.withLock { _resetCount } }
    var imageListCalls: Int { lock.withLock { _imageListCalls } }
    var nicknameChecks: [String] { lock.withLock { _nicknameChecks } }

    func updateProfile(nickname: String?, imageKey: String?) async throws {
        lock.withLock {
            _patches.append(Patch(nickname, imageKey))
            _callOrder.append("PATCH")
        }
        if let updateFailure { throw updateFailure }
    }

    func resetProfileImage() async throws {
        let failure: (any Error)? = lock.withLock {
            _resetCount += 1
            _callOrder.append("DELETE")
            return _resetFailuresRemoveFirst()
        }
        if let failure { throw failure }
    }

    private func _resetFailuresRemoveFirst() -> (any Error)? {
        resetFailures.isEmpty ? nil : resetFailures.removeFirst()
    }

    func getProfileImages() async throws -> [ProfileImage] {
        let result: Result<[ProfileImage], any Error>? = lock.withLock {
            _imageListCalls += 1
            return imageResults.isEmpty ? nil : imageResults.removeFirst()
        }
        if let result { return try result.get() }
        return images
    }

    /// 중복 확인은 디바운스가 끝나면 불린다.
    func isNicknameTaken(nickname: String) async throws -> Bool {
        lock.withLock { _nicknameChecks.append(nickname) }
        if let nicknameTaken { return try await nicknameTaken(nickname) }
        return false
    }

    // 전화번호 가입 여부 선확인은 10 프로필 만들기의 번호 입력란에서만 불린다 — 36 에는 번호 입력이
    // 없다. 조용히 false 를 돌려주면 「프로필 수정이 가입 API 를 두드린다」는 사고가 통과한다.
    func isPhoneRegistered(phoneNumber: String) async throws -> Bool {
        throw unrelated("36 프로필 수정과 무관하다")
    }

    func sendPhoneVerificationCode(phoneNumber: String) async throws {
        throw unrelated("36 프로필 수정과 무관하다")
    }

    func verifyPhoneCode(phoneNumber: String, code: String) async throws -> String {
        throw unrelated("36 프로필 수정과 무관하다")
    }

    func register(newUser: NewUser) async throws -> String {
        throw unrelated("36 프로필 수정과 무관하다")
    }

    func login(loginId: String, password: String) async throws -> String {
        throw unrelated("36 프로필 수정과 무관하다")
    }

    func logout() async throws {
        throw unrelated("36 프로필 수정과 무관하다")
    }

    func deleteAccount(password: String) async throws {
        throw unrelated("탈퇴는 37 의 몫이다")
    }

    func getMyProfile() async throws -> UserProfileInfo {
        throw unrelated("프리필 값은 35 가 조회해 prefill 로 넘긴다")
    }

    private func unrelated(_ message: String) -> any Error {
        Issue.record(Comment(rawValue: message))
        return Unrelated()
    }
}

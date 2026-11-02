import Foundation
import MoyeotaDomain
import PresentationCore
import Testing
@testable import FeatureMyPage

// 원본 테스트에 없는 것들. 원본 catch 분기와, Swift 로 옮기면서 저절로는 지켜지지 않는 성질
// (`Main.immediate` 의 동기 실행, UTF-16 단위 글자 수, 취소 처리)을 고정한다.

private struct NetworkDown: Error {}

private final class DurationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Duration] = []

    func append(_ value: Duration) { lock.withLock { values.append(value) } }
    var recorded: [Duration] { lock.withLock { values } }
}

/// 테스트가 풀어 줄 때까지 응답을 붙잡아 두는 문.
private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }

    var isWaiting: Bool { continuation != nil }
}

@MainActor
@Suite struct ProfileEditBehaviorTest {

    // ─────────────────────────── 입력 ───────────────────────────

    @Test("입력에서 공백을 거르고 UTF-16 10칸에서 자른다")
    func inputFilteredAndCut() {
        let viewModel = makeViewModel(ProfileEditFakeAuthRepository())

        viewModel.onNicknameChange(raw: " 가 나\t다\u{3000}")
        #expect(viewModel.uiState.nickname == "가나다")

        viewModel.onNicknameChange(raw: "가나다라마바사아자차카")
        #expect(viewModel.uiState.nickname == "가나다라마바사아자차")

        // 이모지는 한 글자가 두 칸이다 — 원본 `take(10)` 과 카운터가 같은 값을 보게 한다.
        viewModel.onNicknameChange(raw: "😀😀😀😀😀😀")
        #expect(viewModel.uiState.nickname.utf16.count == 10)
    }

    @Test("정규화가 다른 닉네임은 같은 값으로 보지 않는다")
    func normalizationIsNotEqual() {
        // 원본 문자열 비교는 코드 유닛 단위다. Swift `==` 를 쓰면 이 둘이 같아진다.
        #expect(!isNicknameUnchanged(input: "\u{1100}\u{1161}나", currentNickname: "가나"))
        #expect(isNicknameEdited(input: "\u{1100}\u{1161}나", currentNickname: "가나"))
    }

    // ─────────────────────────── 중복 확인 ───────────────────────────

    @Test("입력이 멈추고 500ms 뒤에 중복을 묻는다")
    func debouncesBeforeAsking() async {
        let recorder = DurationRecorder()
        let repository = ProfileEditFakeAuthRepository(nicknameTaken: { _ in true })
        let viewModel = ProfileEditViewModel(repository: repository, sleep: { recorder.append($0) })
        viewModel.prefill(name: "성윤", imageUrl: nil)

        viewModel.onNicknameChange(raw: "길동이")
        await viewModel.advanceUntilIdle()

        #expect(recorder.recorded == [.milliseconds(500)])
        #expect(repository.nicknameChecks == ["길동이"])
        #expect(viewModel.uiState.check == .taken)
    }

    @Test("형식이 틀리거나 내 닉네임이면 묻지 않는다")
    func doesNotAskWhenPointless() async {
        let repository = ProfileEditFakeAuthRepository()
        let viewModel = makeViewModel(repository)
        viewModel.prefill(name: "성윤", imageUrl: nil)

        viewModel.onNicknameChange(raw: "가")
        viewModel.onNicknameChange(raw: "성윤")
        await viewModel.advanceUntilIdle()

        #expect(repository.nicknameChecks.isEmpty)
        #expect(viewModel.uiState.check == .idle)
    }

    @Test("중복 확인 실패는 코드에 따라 형식 오류와 확인 불가로 갈린다")
    func checkFailureMapping() async {
        let cases: [(any Error, NicknameCheckState)] = [
            (AuthException(error: .invalidNickname), .invalidFormat),
            (AuthException(error: .invalidRequest, serverMessage: "nickname: 형식"), .invalidFormat),
            (AuthException(error: .invalidRequest, serverMessage: "phoneNumber: 형식"), .unknown),
            (AuthException(error: .network), .unknown),
            (NetworkDown(), .unknown),
        ]
        for (failure, expected) in cases {
            let box = SendableError(failure)
            let viewModel = makeViewModel(ProfileEditFakeAuthRepository(nicknameTaken: { _ in throw box.error }))
            viewModel.onNicknameChange(raw: "길동이")
            await viewModel.advanceUntilIdle()
            #expect(viewModel.uiState.check == expected)
        }
    }

    @Test("다음 타자가 앞선 확인의 늦은 응답을 버린다")
    func staleCheckIsDropped() async throws {
        let gate = Gate()
        let repository = ProfileEditFakeAuthRepository(nicknameTaken: { nickname in
            if nickname == "첫이름" {
                await gate.wait()
                return true
            }
            return false
        })
        let viewModel = makeViewModel(repository)

        viewModel.onNicknameChange(raw: "첫이름")
        let first = try #require(viewModel.checkJob)
        while !(await gate.isWaiting) { await Task.yield() }

        viewModel.onNicknameChange(raw: "둘째이름")
        await viewModel.checkJob?.value
        #expect(viewModel.uiState.check == .available)

        await gate.open()
        await first.value

        // 「첫이름」 은 이미 사용 중이지만 그 답은 지금 입력에 대한 답이 아니다.
        #expect(viewModel.uiState.check == .available)
    }

    /// 태스크가 살아 있는데 전송만 끊긴 경우다 — 대체한 새 요청이 없으니 원본 `catch (e: Exception)` 처럼 내린다.
    /// 내리지 않으면 입력란 아래 「사용할 수 있는지 확인하고 있어요」가 다음 타자까지 남는다.
    @Test("태스크가 살아 있는데 URLError(.cancelled) 로 끝난 확인은 확인 중에 남지 않는다")
    func urlCancelledCheckDoesNotStick() async {
        let repository = ProfileEditFakeAuthRepository(nicknameTaken: { _ in throw URLError(.cancelled) })
        let viewModel = makeViewModel(repository)

        viewModel.onNicknameChange(raw: "길동이")
        await viewModel.advanceUntilIdle()

        #expect(viewModel.uiState.check == .unknown)
    }

    /// 위 테스트의 수정이 「옛 요청이 새 요청의 상태를 덮지 않는다」까지 없애지 않았는지 함께 못 박는다.
    /// 앞 요청은 취소된 뒤 `URLSession` 처럼 `URLError(.cancelled)` 를 던진다.
    @Test("다음 타자로 취소된 앞 확인의 URLError(.cancelled) 는 새 확인 결과를 덮지 않는다")
    func replacedCheckUrlCancelledIsDropped() async throws {
        let gate = Gate()
        let repository = ProfileEditFakeAuthRepository(nicknameTaken: { nickname in
            if nickname == "첫이름" {
                await gate.wait()
                throw URLError(.cancelled)
            }
            return false
        })
        let viewModel = makeViewModel(repository)

        viewModel.onNicknameChange(raw: "첫이름")
        let first = try #require(viewModel.checkJob)
        while !(await gate.isWaiting) { await Task.yield() }

        viewModel.onNicknameChange(raw: "둘째이름")
        await viewModel.checkJob?.value
        #expect(viewModel.uiState.check == .available)

        await gate.open()
        await first.value

        #expect(viewModel.uiState.check == .available)
    }

    // ─────────────────────────── 저장 ───────────────────────────

    /// 원본은 `catch (e: Exception)` 하나로 모든 실패에서 잠금을 푼다. 살아 있는 화면이 스피너에 갇히면
    /// 입력란·격자·되돌리기까지 비활성이라 빠져나갈 길이 뒤로가기뿐이다.
    @Test("태스크가 살아 있는데 PATCH 가 URLError(.cancelled) 로 끝나면 잠금을 풀고 배너를 띄운다")
    func urlCancelledSaveUnlocks() async {
        let repository = ProfileEditFakeAuthRepository(updateFailure: URLError(.cancelled))
        let viewModel = makeViewModel(repository)
        viewModel.prefill(name: "성윤", imageUrl: preset("03"))
        viewModel.onImagePick(key: "profile/presets/03.png")

        viewModel.save()
        await viewModel.advanceUntilIdle()

        let state = viewModel.uiState
        #expect(!state.saving)
        #expect(!state.saved)
        #expect(state.errorMessage == authErrorMessage(error: .network), "원본은 OkHttp IOException 이 NETWORK 가 된다")
        #expect(state.imageIntent == .pick(key: "profile/presets/03.png"))
        #expect(state.canSaveNow())
    }

    /// PATCH 는 이미 서버에 반영됐다. 잠금이 안 풀리면 다시 눌러 `saved` 까지 갈 길이 없어,
    /// 35·14 가 옛 이름을 계속 보여 준다.
    @Test("PATCH 뒤 DELETE 가 URLError(.cancelled) 로 끝나도 다시 저장해 마칠 수 있다")
    func urlCancelledDeleteCanRetry() async {
        let repository = ProfileEditFakeAuthRepository(resetFailures: [URLError(.cancelled)])
        let viewModel = makeViewModel(repository)
        viewModel.prefill(name: "성윤", imageUrl: preset("03"))
        viewModel.onNicknameChange(raw: "윤성")
        viewModel.onImageReset()

        viewModel.save()
        await viewModel.advanceUntilIdle()

        #expect(!viewModel.uiState.saving)
        #expect(!viewModel.uiState.saved)
        #expect(viewModel.uiState.currentNickname == "윤성")
        #expect(viewModel.uiState.errorMessage == authErrorMessage(error: .network))

        viewModel.save()
        await viewModel.advanceUntilIdle()

        #expect(repository.patches == [Patch("윤성", nil)])
        #expect(repository.resetCount == 2)
        #expect(viewModel.uiState.saved)
    }

    /// 태스크 자체가 취소되는 건 뷰모델이 사라질 때뿐이다 — 그 실패는 화면에 쓰지 않는다.
    @Test("저장 태스크가 취소되면 배너를 쓰지 않는다")
    func cancelledSaveTaskWritesNoBanner() async {
        let repository = ProfileEditFakeAuthRepository(updateFailure: URLError(.cancelled))
        let viewModel = makeViewModel(repository)
        viewModel.prefill(name: "성윤", imageUrl: preset("03"))
        viewModel.onImagePick(key: "profile/presets/03.png")

        viewModel.save()
        viewModel.saveJob?.cancel()
        await viewModel.advanceUntilIdle()

        #expect(viewModel.uiState.errorMessage == nil)
        #expect(!viewModel.uiState.saved)
    }

    /// 원본 `viewModelScope` 는 `Main.immediate` 라 `saving` 이 호출 자리에서 켜진다.
    @Test("저장을 연달아 눌러도 PATCH 는 한 번이다")
    func doubleTapSavesOnce() async {
        let repository = ProfileEditFakeAuthRepository()
        let viewModel = makeViewModel(repository)
        viewModel.prefill(name: "성윤", imageUrl: preset("03"))

        viewModel.onImagePick(key: "profile/presets/03.png")
        viewModel.save()
        #expect(viewModel.uiState.saving)
        viewModel.save()
        await viewModel.advanceUntilIdle()

        #expect(repository.patches.count == 1)
        #expect(!viewModel.uiState.saving)
        #expect(viewModel.uiState.saved)
    }

    @Test("닉네임 중복 409 는 필드가 말하고 배너를 띄우지 않는다")
    func duplicatedGoesToField() async {
        let repository = ProfileEditFakeAuthRepository(updateFailure: AuthException(error: .nicknameDuplicated))
        let viewModel = makeViewModel(repository)
        viewModel.prefill(name: "성윤", imageUrl: preset("03"))
        viewModel.onNicknameChange(raw: "길동이")
        await viewModel.advanceUntilIdle()

        viewModel.onImagePick(key: "profile/presets/03.png")
        viewModel.save()
        await viewModel.advanceUntilIdle()

        let state = viewModel.uiState
        #expect(state.check == .taken)
        #expect(state.errorMessage == nil)
        #expect(!state.saving)
        #expect(!state.saved)
        // 사진 선택은 그대로다 — 닉네임만 고쳐 다시 저장하면 된다.
        #expect(state.imageIntent == .pick(key: "profile/presets/03.png"))
    }

    @Test("서버 형식 오류는 INVALID_REQUEST nickname 으로 와도 필드가 말한다")
    func invalidRequestNicknameGoesToField() async {
        let repository = ProfileEditFakeAuthRepository(
            updateFailure: AuthException(error: .invalidRequest, serverMessage: "nickname: 2~10자")
        )
        let viewModel = makeViewModel(repository)
        viewModel.prefill(name: "성윤", imageUrl: preset("03"))
        viewModel.onNicknameChange(raw: "길동이")
        await viewModel.advanceUntilIdle()

        viewModel.save()
        await viewModel.advanceUntilIdle()

        #expect(viewModel.uiState.check == .invalidFormat)
        #expect(viewModel.uiState.errorMessage == nil)
    }

    @Test("그 밖의 실패는 배너로 간다")
    func otherFailuresGoToBanner() async {
        let repository = ProfileEditFakeAuthRepository(updateFailure: AuthException(error: .network))
        let viewModel = makeViewModel(repository)
        viewModel.prefill(name: "성윤", imageUrl: preset("03"))
        viewModel.onImagePick(key: "profile/presets/03.png")

        viewModel.save()
        await viewModel.advanceUntilIdle()

        #expect(viewModel.uiState.errorMessage == "네트워크 연결을 확인해 주세요")
        #expect(!viewModel.uiState.saving)
        #expect(viewModel.uiState.imageIntent == .pick(key: "profile/presets/03.png"))
    }

    @Test("DELETE 만 실패해 다시 저장하면 반영된 닉네임을 또 싣지 않는다")
    func retryAfterDeleteFailureSkipsNickname() async {
        let repository = ProfileEditFakeAuthRepository(resetFailures: [AuthException(error: .network)])
        let viewModel = makeViewModel(repository)
        viewModel.prefill(name: "성윤", imageUrl: preset("03"))
        viewModel.onNicknameChange(raw: "윤성")
        viewModel.onImageReset()

        viewModel.save()
        await viewModel.advanceUntilIdle()
        #expect(viewModel.uiState.currentNickname == "윤성")
        #expect(!viewModel.uiState.saved)

        viewModel.save()
        await viewModel.advanceUntilIdle()

        #expect(repository.patches == [Patch("윤성", nil)])
        #expect(repository.resetCount == 2)
        #expect(viewModel.uiState.saved)
    }

    @Test("입력을 고치거나 사진을 고르면 저장 실패 문구가 지워진다")
    func editingClearsBanner() async {
        let repository = ProfileEditFakeAuthRepository(updateFailure: AuthException(error: .network))
        let viewModel = makeViewModel(repository)
        viewModel.prefill(name: "성윤", imageUrl: preset("03"))
        viewModel.onImagePick(key: "profile/presets/03.png")
        viewModel.save()
        await viewModel.advanceUntilIdle()
        #expect(viewModel.uiState.errorMessage != nil)

        viewModel.onImagePick(key: "profile/presets/02.png")
        #expect(viewModel.uiState.errorMessage == nil)
    }

    // ─────────────────────────── 사진 목록 ───────────────────────────

    @Test("목록 조회가 실패하면 실패 상태로 남고 다시 시도로 풀린다")
    func imagesFailureAndRetry() async {
        let repository = ProfileEditFakeAuthRepository(imageResults: [.failure(NetworkDown())])
        let viewModel = makeViewModel(repository)
        await viewModel.advanceUntilIdle()

        #expect(viewModel.uiState.imagesLoadFailed)
        #expect(viewModel.uiState.images.isEmpty)

        viewModel.retryImages()
        #expect(!viewModel.uiState.imagesLoadFailed)
        await viewModel.advanceUntilIdle()

        #expect(!viewModel.uiState.imagesLoadFailed)
        #expect(viewModel.uiState.images.count == 2)
    }

    /// 첫 요청 태스크를 실제로 취소한다. `URLSession` 은 그 경우에도 `URLError(.cancelled)` 로 끝날 수 있다.
    @Test("태스크가 정말 취소된 목록 요청은 무슨 오류로 끝나든 실패로 쓰지 않는다", arguments: [
        CancellationError() as any Error,
        URLError(.cancelled) as any Error,
    ])
    func cancelledImagesAreNotFailure(error: any Error) async throws {
        let repository = ProfileEditFakeAuthRepository(imageResults: [.failure(error)])
        let viewModel = makeViewModel(repository)
        let first = try #require(viewModel.imagesJob)

        first.cancel()
        await first.value

        #expect(!viewModel.uiState.imagesLoadFailed)
    }

    /// 원본 `runCatching` 은 OkHttp `IOException("Canceled")` 도 실패로 받는다. 조용히 끝내면
    /// 「프로필 사진」 섹션이 재시도 버튼도 없이 사라진다.
    @Test("살아 있는 태스크의 URLError(.cancelled) 는 목록 실패로 남아 재시도를 그린다")
    func liveUrlCancelledImagesAreFailure() async {
        let repository = ProfileEditFakeAuthRepository(imageResults: [.failure(URLError(.cancelled))])
        let viewModel = makeViewModel(repository)
        await viewModel.advanceUntilIdle()

        #expect(viewModel.uiState.imagesLoadFailed)
    }

    @Test("프리필은 사용자가 고른 사진을 되돌리지 않고 기본 이미지 여부만 갱신한다")
    func prefillKeepsImageIntent() {
        let viewModel = makeViewModel(ProfileEditFakeAuthRepository())
        #expect(viewModel.uiState.usingDefaultImage)

        viewModel.onImagePick(key: "profile/presets/03.png")
        viewModel.prefill(name: "성윤", imageUrl: preset("07"))

        #expect(!viewModel.uiState.usingDefaultImage)
        #expect(viewModel.uiState.imageIntent == .pick(key: "profile/presets/03.png"))
    }
}

private struct SendableError: @unchecked Sendable {
    let error: any Error

    init(_ error: any Error) {
        self.error = error
    }
}

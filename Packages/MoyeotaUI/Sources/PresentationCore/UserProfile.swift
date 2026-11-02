import MoyeotaDomain
import Observation

/// 로그인한 사용자의 표시용 신원 상태 — 이름과 프로필 사진.
///
/// `loading` 과 `resolved(name: nil)` 을 굳이 나누는 이유: 조회가 아직 안 끝난 것과
/// "서버에 이름이 없다"는 건 화면이 달리 그려야 한다(전자는 빈 자리/스켈레톤, 후자는 폴백 문구).
/// 한 상태로 뭉치면 로딩 중에 "이름 미설정"이 스쳐 보인다. 사진도 같다 — 로딩 중에 기본 이미지가
/// 스쳐 보이면 안 된다.
///
/// 이름(`UserName…`)만 담던 자리에 사진이 붙어 타입 이름이 좁아졌지만, 소비처가 네 곳이라
/// 개칭은 별 변경으로 떼어 둔다(이 변경에 섞으면 무엇이 기능이고 무엇이 이름 변경인지 안 갈린다).
public enum UserNameState: Hashable, Sendable {
    /// 미로그인이거나 아직 조회 중 — 이름·사진 자리를 비워 둔다.
    case loading

    /// 조회 완료. `name` 이 nil 이면 서버에 이름이 없거나 조회에 실패한 것 — 화면이 폴백한다.
    ///
    /// `imageUrl` 은 **서버가 비워 보내지 않는다** — 고른 적 없는 사용자에게도 기본 이미지의 전체
    /// 주소를 준다. 그래서 여기가 nil 이면 "사진이 없다"가 아니라 조회 실패거나 구버전 서버다.
    case resolved(name: String?, imageUrl: String? = nil)
}

/// 세션당 한 번만 이름을 받아 오는 공용 홀더.
///
/// 내비게이션 스택 바깥(앱 루트)에 두고 홈·마이페이지가 같은 인스턴스를 본다
/// — 화면마다 부르면 탭을 오갈 때마다 같은 응답을 반복해서 받게 된다.
/// `AuthRepository.getMyProfile()` 이 캐시하지 않으므로 캐시는 이 계층의 책임이다.
///
/// 로그인 사용자가 바뀌면(= uuid 가 바뀌면) 다시 받는다. 로그아웃하면 `UserNameState.loading` 으로
/// 되돌려, 다음 사용자의 이름이 뜨기 전에 이전 사용자의 이름이 남지 않게 한다.
/// 같은 사용자의 이름이 바뀌는 경우(36 프로필 수정)는 `refresh` 로 명시적으로 다시 받는다.
///
/// **실패해도 조용히 넘어간다.** 이름은 인사말과 프로필 카드의 부가 정보라,
/// 이것 때문에 화면 전체가 에러로 막히면 손해가 더 크다.
@MainActor
@Observable
public final class UserProfileViewModel {
    public private(set) var userName: UserNameState = .loading

    @ObservationIgnored private let repository: any AuthRepository
    @ObservationIgnored private let scope = ViewModelScope()

    // 진행 중인 조회. 사용자 전환(init 의 수집)과 수동 재조회(`refresh`)가 같은 자리를 쓰므로
    // 한 곳으로 모아 **항상 마지막 요청만 살려 둔다** — 두 응답이 겹치면 늦게 도착한 쪽이 이기고,
    // 그게 이전 사용자의 이름일 수도 있다.
    @ObservationIgnored private var loadJob: Task<Void, Never>?

    public init(repository: any AuthRepository) {
        self.repository = repository
        let states = repository.authState.values()
        scope.launch { [weak self] in
            var seenAny = false
            var previous: String?
            for await state in states {
                let uuid: String? = if case .authenticated(let userUuid) = state { userUuid } else { nil }
                // `map { uuid }.distinctUntilChanged()` 의 자리 — unknown ↔ unauthenticated 는 같은 nil 이다.
                if seenAny && uuid == previous { continue }
                seenAny = true
                previous = uuid
                self?.onUserChanged(uuid: uuid)
            }
        }
    }

    private func onUserChanged(uuid: String?) {
        if uuid == nil {
            // 미로그인/복원 전 — 조회하지 않는다(토큰이 없어 401 이 확정이다).
            loadJob?.cancel()
            userName = .loading
        } else {
            // 사용자가 바뀌었다 — 이전 이름을 지우고(빈 자리) 새로 받는다
            load(showLoading: true)
        }
    }

    /// 서버 값으로 이름을 다시 맞춘다 — 36 프로필 수정이 닉네임을 저장한 뒤 호출한다.
    ///
    /// init 의 수집은 **uuid 가 바뀔 때만** 깨어나므로 같은 사용자에게는
    /// 아무 일도 일어나지 않는다. 그래서 재조회는 이 입구가 따로 필요하고, 두 경로가 동시에 겹쳐도
    /// `loadJob` 이 앞선 요청을 취소해 응답이 뒤섞이지 않는다.
    ///
    /// 미로그인이면 조회할 토큰이 없으니 그대로 둔다.
    public func refresh() {
        guard case .authenticated = repository.authState.value else { return }
        // 이미 보여 주던 이름을 비우지 않는다 — 저장 직후의 깜빡임을 만들지 않기 위해서다
        load(showLoading: false)
    }

    private func load(showLoading: Bool) {
        loadJob?.cancel()
        if showLoading { userName = .loading }
        let repository = self.repository
        loadJob = scope.launch { [weak self] in
            // `.name` 을 바로 꺼내면 imageUrl 을 영영 못 가져온다 — 응답 값째로 받는다.
            let info: UserProfileInfo?
            do {
                info = try await repository.getMyProfile()
            } catch {
                // 태스크가 정말 취소됐을 때만 조용히 끝낸다. 살아 있는 태스크의 `URLError(.cancelled)` 까지 끝내면
                // 원본 `runCatching` 과 달리 이름 자리가 `loading` 에서 내려오지 않는다.
                if Task.isCancelled { return }
                info = nil
            }
            // 취소된 요청은 아무것도 쓰지 않는다 — 앞선 요청의 결과가 로그아웃 뒤의 빈 자리를 덮으면 안 된다.
            guard !Task.isCancelled, let self else { return }
            // 재조회가 실패했다고 이미 띄워 둔 이름을 「이름 미설정」으로 되돌리지는 않는다
            // — 저장은 서버에서 끝났는데 조회만 실패한 상황에서, 그러면 저장이 날아간 것처럼 보인다.
            //
            // 조건이 `name != nil` 이 아니라 `info != nil` 인 게 중요하다. 조회가 **성공했는데
            // 이름만 nil** 인 사용자(닉네임·실명이 둘 다 없다)는 앞 조건에서는 갱신이 건너뛰어져,
            // 사진은 있는데 재조회 때마다 아바타를 잃는다. 실패는 `info == nil` 하나로 판정된다.
            if info != nil || showLoading {
                self.userName = .resolved(name: info?.name, imageUrl: info?.imageUrl)
            }
        }
    }
}

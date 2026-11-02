import Foundation
import os

/// 「조용히 삼켜진 실패」를 밖으로 알리는 통로.
///
/// 이 앱은 **의도적으로 안 죽게** 쓰여 있다. `try?`·`quietly {}` 로 실패를 삼키는 자리가 많고,
/// 그건 UX 로는 옳다 — 지하철에서 조회 하나 실패했다고 화면이 죽으면 안 된다.
/// 대가는 **프로덕션에서 아무것도 안 보인다**는 것이다. 오류 로그가 거의 없어
/// 크래시 통계는 깨끗한데 사용자는 앱이 안 된다고 말하는 상태가 될 수 있다.
///
/// ### 왜 생성자 주입이 아니라 전역인가
/// 이 저장소는 Repository 구현들을 `AppContainer` 로 조립해 넘기는 DI 를 쓴다. 그 선을 따르면
/// Repository·소켓·토큰 재발급 열 몇 곳의 생성자와 **그만큼의 테스트 fake** 가 함께 바뀐다.
/// 보고용 sink 하나를 꽂으려고 치르기에는 비싼 값이고, 프로덕션 첫 게시 직전에 넓힐 표면이 아니다.
/// `os.Logger` 와 같은 범주 — **부수효과가 없고 교체가 필요 없는 진단 출력** — 으로 보고
/// 전역에 둔다. 기본값이 무동작이라 단위 테스트는 아무것도 설치하지 않으면 그대로 통과한다.
///
/// 「무엇을 보고할지」는 여기서 정하고, **어디로 보낼지만** 앱 타깃이 `install` 로 꽂는다.
/// domain 은 Firebase 를 모른다.
public enum Diagnostics {

    /// 보고 받는 쪽. 던질 수 있게 둔다 — 원본의 sink 는 무엇이든 던질 수 있었고, 그래도 호출부로 새지 않는 것이
    /// `report` 의 약속이다(Firebase 가 초기화되지 않았을 때 등).
    public typealias Sink = @Sendable (FailureSite, any Error) throws -> Void

    /// 잠금 — 설치는 메인 스레드(앱 시작), 보고는 아무 스레드에서나 일어난다.
    private static let installedSink = OSAllocatedUnfairLock<Sink?>(initialState: nil)

    /// app 모듈이 앱 시작 때 한 번 꽂는다. 꽂기 전의 보고는 조용히 버린다.
    public static func install(sink: @escaping Sink) {
        installedSink.withLock { $0 = sink }
    }

    /// 테스트끼리 설치가 새지 않게 비운다.
    public static func reset() {
        installedSink.withLock { $0 = nil }
    }

    /// 보고할 가치가 있을 때만 보고한다(`isWorthReporting`).
    ///
    /// `httpStatus` 는 **호출부가 알 때만** 넘긴다. domain 은 네트워크 계층을 모르므로 4xx/5xx 를
    /// 스스로 가를 수 없다 — 상태 코드를 쥐고 있는 data 쪽이 넘겨 준다.
    ///
    /// **취소 말고는 절대 던지지 않는다.** 이 함수는 전부 `catch` 안에서 불리고, 여기서 터지면 삼켜져 있던
    /// 실패가 오히려 크래시로 승격된다. 단 취소(`isCancellation`)만은 예외로, 보고하지 않고
    /// **그대로 되던진다** — 태스크 취소를 삼키면 구조적 동시성이 깨진다. 그래서 `throws` 이고 호출부는
    /// `try` 로 불러 취소를 위로 흘려야 한다(Kotlin 은 검사 예외가 없어 시그니처에 드러나지 않았다).
    public static func report(site: FailureSite, throwable: any Error, httpStatus: Int? = nil) throws {
        if isCancellation(throwable: throwable) { throw throwable }
        if !isWorthReporting(throwable: throwable, httpStatus: httpStatus) { return }
        let sink = installedSink.withLock { $0 }
        do {
            try sink?(site, throwable)
        } catch {
            // sink 의 실패는 보고할 곳도 없다 — 호출부로 새지 않게 여기서 끝낸다.
        }
    }
}

/// 보고가 올라오는 지점. 대시보드에서 이 값으로 묶여 보이므로 **개수를 적게 유지한다** —
/// 자리마다 새로 만들면 같은 결함이 여러 줄로 흩어진다.
public enum FailureSite: String, CaseIterable, Sendable {
    /// 진행 중인 방 복구. 실패하면 사용자가 타고 있던 방으로 못 돌아간다.
    case activePartyRestore = "ACTIVE_PARTY_RESTORE"

    /// 서버가 리프레시 토큰을 **거절**했다 → 강제 로그아웃. 타임아웃은 여기 오지 않는다.
    case tokenRefreshRejected = "TOKEN_REFRESH_REJECTED"

    /// 채팅 소켓이 **연속으로** 재연결에 실패했다. 한 번 실패는 보고하지 않는다.
    case chatSocketReconnect = "CHAT_SOCKET_RECONNECT"

    /// 즐겨찾기 조회·삭제 실패.
    case favoritePlaces = "FAVORITE_PLACES"

    /// 탑승 기록 조회 실패.
    case rideHistory = "RIDE_HISTORY"

    /// Kotlin `enum.name` — 원본 상수 이름 그대로. 대시보드 키로 쓴다.
    public var name: String { rawValue }
}

/// 보고할 가치가 있는 실패인가.
///
/// 기준을 한곳에 모으는 이유: 자리마다 각자 판단하면 **대시보드가 지하철로 가득 찬다.**
/// 신호가 소음에 묻히면 켜 두나 마나다.
///
/// | 종류 | 보고 | 왜 |
/// |---|---|---|
/// | 취소(`isCancellation`) | ✗ | 화면을 벗어나면 **정상적으로** 발생한다. 전부 쓰레기다 |
/// | 전송 계층 실패(`isIOFailure`) | ✗ | 타임아웃·DNS·소켓·SSL — 지하철이지 결함이 아니다 |
/// | HTTP 4xx | ✗ | 서버의 정상 판단(401·403·404·409·429)이고 호출부가 이미 처리한다 |
/// | HTTP 5xx | ✓ | 서버 결함이다. 앱이 아는 유일한 창구다 |
/// | 그 밖 | ✓ | 파싱 실패(`DecodingError`)·매퍼의 결함 — **앱이나 계약의 결함**이다 |
///
/// 취소를 **가장 먼저** 거른다 — `URLError(.cancelled)` 도 취소이므로, 순서가 밀리면
/// 전송 계층 실패로 읽혀 취소라는 사실이 사라진다.
public func isWorthReporting(throwable: any Error, httpStatus: Int?) -> Bool {
    if isCancellation(throwable: throwable) { return false }
    if isIOFailure(throwable: throwable) { return false }
    if let httpStatus { return httpStatus >= 500 }
    return true
}

/// 태스크 취소로 생긴 실패인가 — Kotlin `CancellationException` 의 자리.
///
/// `URLSession` 은 태스크가 취소되면 `CancellationError` 가 아니라 `URLError(.cancelled)` 를 던진다.
/// 그것도 같은 사건이므로 함께 본다. 이걸 빠뜨리면 화면을 벗어날 때마다 「실패」로 처리된다.
public func isCancellation(throwable: any Error) -> Bool {
    if throwable is CancellationError { return true }
    let error = throwable as NSError
    return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
}

/// 응답을 받지 못한 전송 계층 실패인가 — Kotlin `IOException` 하위 전부의 자리.
///
/// `URLSession` 의 실패는 `URLError`(소켓 수준은 `POSIXError`·CFNetwork)로 온다. 웹소켓·스트림 쪽은 Swift 값이
/// 아니라 `NSError` 로 올라오는 일이 있어 타입이 아니라 오류 도메인으로 본다(`URLError` 도 이 도메인으로 다리 놓인다).
public func isIOFailure(throwable: any Error) -> Bool {
    if throwable is IOException { return true }
    let domain = (throwable as NSError).domain
    return domain == NSURLErrorDomain || domain == NSPOSIXErrorDomain || domain == "kCFErrorDomainCFNetwork"
}

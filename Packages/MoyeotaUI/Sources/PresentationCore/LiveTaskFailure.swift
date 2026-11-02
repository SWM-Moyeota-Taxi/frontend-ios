import Foundation
import MoyeotaDomain

/// `catch` 에 온 오류를 원본이 받았을 실패 값으로 옮긴다. 태스크가 실제로 취소됐으면 nil 이다 — 알릴 곳이 없다.
///
/// **규칙: 조용히 끝내도 되는 것은 정말 취소된 태스크뿐이다.** `isCancellation` 으로 판정하면 안 된다.
/// `HttpClient` 가 태스크 취소를 `CancellationError` 로 바꾸므로 `URLError(.cancelled)` 가 그대로 올라왔다면 태스크는
/// **살아 있다**(세션 무효화·인증 챌린지 취소 등). 이때 끝내 버리면 아무도 진행 표시를 내려 주지 않아 스피너와 잠금이 남는다.
///
/// 원본에서 이 값은 OkHttp 의 `IOException("Canceled")` 으로, 데이터 계층이 네트워크 실패로 올린다. iOS 데이터 계층은
/// `isCancellation` 인 값을 그대로 통과시키므로 문구가 갈리는 화면은 `transportCancelled` 로 같은 값을 만든다.
///
/// 살아 있는 태스크에 온 `CancellationError`(다른 태스크의 취소가 전달된 경우)는 원본 `catch (e: Exception)` 이 받는
/// `CancellationException` 처럼 그대로 실패로 돌려준다 — 여기서 삼키면 똑같이 잠금이 남는다.
///
/// 문구를 가를 필요 없이 조용히 끝낼지만 정하면 되는 자리는 `if Task.isCancelled { return }` 한 줄이면 같다.
public func failureOnLiveTask(
    error: any Error,
    transportCancelled: (any Error) -> any Error = { $0 }
) -> (any Error)? {
    if Task.isCancelled { return nil }
    if error is CancellationError || !isCancellation(throwable: error) { return error }
    return transportCancelled(error)
}

/// `failureOnLiveTask` 의 인증 판. 원본 `toAuthException` 처럼 살아 있는 태스크의 `URLError(.cancelled)` 를 `NETWORK` 로 옮긴다.
public func authFailureOnLiveTask(error: any Error) -> (any Error)? {
    failureOnLiveTask(error: error) { AuthException(error: .network, cause: $0) }
}

import Foundation

/// 즐겨찾기 삭제 실패를 화면이 다룰 수 있는 형태로 좁힌 예외.
///
/// presentation 은 네트워크 계층을 의존하지 않으므로(`MoyeotaUI` 는 `MoyeotaCore` 중 `MoyeotaDomain` 만 본다)
/// HTTP 상태를 그대로 올리면 화면이 404 와 500 을 구분할 수 없다. `ChatException` 과 같은 경계다.
///
/// ### 왜 404 를 성공으로 접지 않는가
/// 삭제는 **멱등이 아니다** — 같은 id 두 번째도, 없는 id 도, **남의 id 도 전부 같은
/// 404 `FAVORITE_PLACE_NOT_FOUND`** 다(실측(2026-11-01, 로컬 `:8080`); 403 이 아니라 존재 은닉이다).
/// 「이미 지워졌으니 성공」으로 접으면 남의 행을 지우려는 시도까지 성공으로 보이고, 화면은 서버와
/// 어긋난 목록을 계속 들고 있는다. 그래서 실패로 올리고 **화면이 목록을 다시 받게** 한다.
///
/// 404 를 삼키는 자리는 전체 삭제 하나뿐이다 — 「이미 비어 있다」는 부른 쪽이 원한 상태가 이미
/// 참이라는 뜻이고, 그건 리포지토리가 처리하므로 이 예외까지 올라오지 않는다
/// (`RemotePlaceRepository.deleteAllFavoritePlaces`).
public struct FavoritePlaceException: Throwable {
    /// 서버 에러 코드(`FAVORITE_PLACE_NOT_FOUND`·`INVALID_PLACE_IDS` 등). 본문이 없거나 파싱 실패면 null.
    public let code: String?
    /// 서버가 준 한국어 원문 message. 없으면 null.
    public let serverMessage: String?
    /// HTTP 상태 코드. 응답 자체를 받지 못했으면 null.
    public let httpStatus: Int?
    /// 응답을 받지 못한 실패(연결 거부·타임아웃·DNS). 사용자에게는 재시도를 안내한다.
    public let isNetwork: Bool
    public let cause: (any Error)?

    public init(
        code: String?,
        serverMessage: String?,
        httpStatus: Int? = nil,
        isNetwork: Bool = false,
        cause: (any Error)? = nil
    ) {
        self.code = code
        self.serverMessage = serverMessage
        self.httpStatus = httpStatus
        self.isNetwork = isNetwork
        self.cause = cause
    }

    public var message: String? { serverMessage ?? code ?? "즐겨찾기 요청에 실패했습니다." }

    /// 404 `FAVORITE_PLACE_NOT_FOUND` — **이미 지워졌거나 내 것이 아니다.**
    /// 서버가 둘을 구분해 주지 않으므로 문구도 구분하지 않는다. 이 값이 참이면 화면이 보고 있는 목록이
    /// 서버와 어긋났다는 뜻이라 재조회가 필요하다.
    public var isNotFound: Bool {
        code == "FAVORITE_PLACE_NOT_FOUND" || (code == nil && httpStatus == 404)
    }
}

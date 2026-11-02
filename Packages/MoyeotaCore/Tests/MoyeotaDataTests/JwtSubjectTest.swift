import Testing
@testable import MoyeotaData

@Suite struct JwtSubjectTest {

    /// 실서버(localhost:8080)가 발급한 진짜 액세스 토큰이다.
    /// 페이로드: `{"sub":"01a06109-f878-7706-aab0-5466fb311d26","tokenType":"ACCESS","iat":…,"exp":…}`
    /// 같은 계정의 가입 응답 `uuid` 와 값이 일치함을 curl 로 확인했다 — 이게 이 함수의 존재 이유다.
    ///
    /// 서명 부분은 검증하지 않으므로 만료돼도 이 테스트는 유효하다. 공개 저장소라 서명은 임의 값으로 바꿔 둔다.
    private let realAccessToken =
        "eyJhbGciOiJIUzM4NCJ9."
        + "eyJzdWIiOiIwMWEwNjEwOS1mODc4LTc3MDYtYWFiMC01NDY2ZmIzMTFkMjYiLCJ0b2tlblR5cGUiOiJBQ0NFU1MiLCJpYXQiOjE3ODgzMzQ0MzgsImV4cCI6MTc4ODMzNTAzOH0."
        + "not-a-real-signature_not-a-real-signature_not-a-real-signature_x"

    @Test("실서버 액세스 토큰에서 사용자 UUID 를 읽는다")
    func readsUuidFromRealToken() {
        #expect(jwtSubject(token: realAccessToken) == "01a06109-f878-7706-aab0-5466fb311d26")
    }

    /// 서버 페이로드는 base64**url** 이고 패딩도 없다. 표준 알파벳만 아는 디코더로 읽으면
    /// `-`/`_` 가 섞인 순간 깨지는데, UUID 만 든 실제 페이로드에는 그 문자가 잘 안 나와서
    /// 위 테스트만으로는 드러나지 않는다. 그래서 둘 다 들어가는 페이로드를 일부러 만든다.
    @Test("패딩 없는 base64url 페이로드도 디코딩한다")
    func decodesUnpaddedBase64Url() {
        // {"sub":"?wv~("} → URL-safe 인코딩 결과에 `-` 와 `_` 가 모두 들어가고 패딩은 없다.
        let payload = "eyJzdWIiOiI_d3Z-KCJ9"
        #expect(jwtSubject(token: "header.\(payload).signature") == "?wv~(")
    }

    @Test("JWT 형식이 아니면 null 이다")
    func notJwtIsNull() {
        #expect(jwtSubject(token: "not-a-jwt") == nil, "점이 없다")
        #expect(jwtSubject(token: "header.payload") == nil, "구획이 둘뿐이다")
        #expect(jwtSubject(token: "") == nil, "빈 문자열")
    }

    @Test("페이로드가 깨졌거나 sub 가 없으면 null 이다")
    func brokenPayloadIsNull() {
        // base64 로 안 풀리는 문자열
        #expect(jwtSubject(token: "header.!!!not-base64!!!.signature") == nil)
        // 풀리지만 JSON 이 아니다
        #expect(jwtSubject(token: "header.aGVsbG8gd29ybGQ.signature") == nil)
        // JSON 이지만 sub 가 없다 → {"tokenType":"ACCESS"}
        #expect(jwtSubject(token: "header.eyJ0b2tlblR5cGUiOiJBQ0NFU1MifQ.signature") == nil)
        // sub 가 빈 문자열이다 → {"sub":""}
        #expect(jwtSubject(token: "header.eyJzdWIiOiIifQ.signature") == nil)
    }
}

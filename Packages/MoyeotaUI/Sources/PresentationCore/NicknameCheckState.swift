/// 10 프로필 만들기의 닉네임 중복 확인 결과.
///
/// `unknown` 이 있는 이유: 확인에 실패했다는 사실은 사용자가 고칠 수 있는 게 아니다.
/// 그래서 화면은 아무 말도 하지 않고 다음 단계도 막지 않는다 — 최종 판정은 어차피 가입 시점의 서버다.
public enum NicknameCheckState: CaseIterable, Hashable, Sendable {
    /// 아직 물어볼 상태가 아니다(빈 입력·형식 미달·디바운스 대기).
    case idle

    /// 서버 조회 중.
    case checking

    /// `exists=false` — 지금은 비어 있는 닉네임.
    case available

    /// `exists=true` — 이미 누가 쓰고 있다.
    case taken

    /// 400 USER107 — 서버 형식 규칙에 걸렸다(앱 규칙과 어긋난 문자).
    case invalidFormat

    /// 네트워크·서버 오류. 조용히 넘어간다.
    case unknown
}

import Testing
@testable import FeatureChat

/// 24 채팅 입력의 **글자 수 카운터 + 전송 잠금**.
///
/// 왜 테스트가 필요한가: 이 자리에는 이미 한 번 결함이 있었다. 입력창이 **500자**에서 하드 컷해서
/// ViewModel 의 1000자 검사와 「1000자까지 보낼 수 있어요」 안내가 **둘 다 도달 불가능한 죽은
/// 코드**였고, 사용자는 500자에서 **이유도 모르고 조용히** 막혔다. 이제 전송 버튼을 길이로
/// 잠그는데, 그 잠금은 「이유가 누르지 않아도 보인다」는 조건에서만 성립한다 — 카운터가 사라지거나
/// 세는 기준이 전송과 갈리면 같은 결함으로 반쯤 되돌아간다. 그 조건을 여기서 못 박는다.
///
/// 이 테스트가 잡는 것:
/// - **trim 기준 어긋남**: 화면이 trim 전 길이를 세면 「999자인데 버튼이 잠김」이 생긴다
///   (`ChatRoomViewModel.send` 는 `text.trim()` 한 값으로 판정하고 그 값을 보낸다)
/// - **이유 없는 잠금**: 잠긴 상태(`sendEnabled == false`)인데 카운터가 nil 인 경우
/// - 공백만 입력했을 때의 비활성이 유지되는지
/// - 카운터가 **한도보다 앞서** 뜨는지(같이 뜨면 잠기는 순간 레이아웃이 움직인다)
///
/// 볼 수 없는 것: 실제 색·자리·레이아웃 이동량.
@Suite struct ChatInputLimitTest {

    private func text(_ length: Int) -> String {
        String(repeating: "가", count: length)
    }

    /// 평상시 메시지에는 카운터가 없다 — 수십 자 메시지마다 숫자가 뜨면 말풍선 높이만 잃는다.
    @Test("평상시에는 카운터가 없다")
    func noCounterNormally() {
        #expect(chatInputUi(input: "안녕하세요", sending: false).counter == nil)
        #expect(chatInputUi(input: text(100), sending: false).counter == nil)
        #expect(chatInputUi(input: text(MAX_CONTENT_LENGTH / 2), sending: false).counter == nil)
    }

    /// 카운터는 **한도보다 앞서** 뜬다. 넘긴 순간에 처음 나타나면 ① 경고가 아니라 사후 통보가 되고
    /// ② 입력 바가 그 프레임에 높아져 **누르려던 전송 버튼이 움직이며** 잠긴다.
    @Test("한도에 가까워지면 카운터가 먼저 뜬다")
    func counterAppearsNearLimit() {
        #expect(COUNTER_VISIBLE_FROM == 900, "임계값이 바뀌었다 — 근거를 적은 주석도 같이 고쳐라")
        #expect(chatInputUi(input: text(COUNTER_VISIBLE_FROM - 1), sending: false).counter == nil)
        #expect(chatInputUi(input: text(COUNTER_VISIBLE_FROM), sending: false).counter != nil)
        #expect(chatInputUi(input: text(COUNTER_VISIBLE_FROM), sending: false).counter == "900/1000자")
    }

    /// **카운터가 잠김보다 먼저 뜬다**는 부등식. 둘이 같은 지점이면 숫자가 나타나는 프레임에 입력
    /// 바가 한 줄 높아지고, 그러면 **전송 버튼이 위로 움직이면서** 잠긴다.
    @Test("카운터는 전송이 잠기기 전에 떠 있다")
    func counterPrecedesLock() {
        #expect(
            COUNTER_VISIBLE_FROM < MAX_CONTENT_LENGTH,
            "카운터가 한도 이후에 뜨면 잠기는 순간 레이아웃이 움직인다"
        )
        // 아직 보낼 수 있는 길이인데 카운터가 이미 보인다 = 예고가 성립한다
        let warned = chatInputUi(input: text(MAX_CONTENT_LENGTH), sending: false)
        #expect(warned.sendEnabled)
        #expect(warned.counter != nil)
    }

    /// **길이를 `trim()` 뒤에 센다** — 전송과 같은 기준이다. 앞뒤 공백을 섞어 1002자를 만들어도
    /// 서버로 갈 값은 1000자이므로 보낼 수 있어야 하고, 카운터도 1000을 말해야 한다.
    /// (이 테스트가 깨지면 화면과 ViewModel 이 서로 다른 길이를 보고 있다는 뜻이다.)
    @Test("공백은 세지 않는다 — 전송과 같은 기준")
    func whitespaceIsNotCounted() {
        let padded = "  " + text(MAX_CONTENT_LENGTH) + "\n"
        let ui = chatInputUi(input: padded, sending: false)
        #expect(ui.counter == "1000/1000자")
        #expect(!ui.overLimit, "trim 하면 한도 안인데 초과로 봤다")
        #expect(ui.sendEnabled, "trim 하면 1000자인데 전송이 잠겼다")
    }

    /// 한도까지는 보낼 수 있다 — 서버 `@Size(max = 1000)` 가 받는 경계값이다.
    @Test("한도까지는 전송할 수 있다")
    func sendableAtLimit() {
        #expect(chatInputUi(input: text(MAX_CONTENT_LENGTH), sending: false).sendEnabled)
        #expect(!chatInputUi(input: text(MAX_CONTENT_LENGTH), sending: false).overLimit)
    }

    /// 한 글자만 넘으면 잠긴다. 서버도 같은 한도로 거절하므로 눌러 봐야 400 뿐이다.
    @Test("한도를 넘으면 전송이 잠긴다")
    func lockedOverLimit() {
        let ui = chatInputUi(input: text(MAX_CONTENT_LENGTH + 1), sending: false)
        #expect(ui.overLimit)
        #expect(!ui.sendEnabled)
    }

    /// **이 테스트가 이 과제의 핵심이다.** 전송이 잠긴 길이에서는 **반드시** 카운터가 있어야 한다 —
    /// 없으면 예전의 「조용히 막힘」으로 되돌아간 것이다. 잠금은 이유가 보이는 것에 대한 대가다.
    @Test("잠긴 이유는 누르지 않아도 보인다")
    func lockReasonIsVisible() {
        // 마지막 값은 입력창 하드 상한(`INPUT_HARD_LIMIT` = 2000, 화면 파일의 private)과 같은
        // 길이다 — 붙여넣기로 한 번에 닿을 수 있는 최댓값에서도 이유가 보여야 한다.
        for length in [MAX_CONTENT_LENGTH + 1, MAX_CONTENT_LENGTH + 500, 2_000] {
            let ui = chatInputUi(input: text(length), sending: false)
            #expect(!ui.sendEnabled, "\(length)자인데 전송이 살아 있다")
            #expect(ui.counter != nil, "\(length)자에서 잠겼는데 카운터가 없다")
            #expect(ui.overLimit, "초과 강조가 꺼져 있다(\(length)자)")
        }
    }

    /// 초과 카운터는 숫자만 바꾸지 않고 **할 일**을 말한다. 색만으로 말하면 색을 구분하기 어려운
    /// 사용자에게는 아무 말도 하지 않은 것과 같다.
    @Test("초과 문구는 무엇을 해야 하는지 말한다")
    func overLimitTextSaysWhatToDo() throws {
        let counter = try #require(chatInputUi(input: text(1_024), sending: false).counter)
        #expect(counter.hasPrefix("1024/1000"), "현재 길이가 없다: \(counter)")
        #expect(counter.contains("줄여"), "줄이라는 말이 없다: \(counter)")
    }

    /// 공백만 입력했을 때의 비활성은 그대로다 — 보낼 내용이 없다.
    @Test("공백만 입력하면 전송할 수 없다")
    func blankCannotBeSent() {
        #expect(!chatInputUi(input: "", sending: false).sendEnabled)
        #expect(!chatInputUi(input: "   ", sending: false).sendEnabled)
        #expect(!chatInputUi(input: "\n\t ", sending: false).sendEnabled)
        #expect(chatInputUi(input: "   ", sending: false).counter == nil, "빈 입력에 카운터를 띄우지 않는다")
    }

    /// 전송 중에는 길이와 무관하게 잠긴다(중복 전송 방지 — 기존 동작).
    @Test("전송 중에는 잠긴다")
    func lockedWhileSending() {
        #expect(!chatInputUi(input: "안녕하세요", sending: true).sendEnabled)
        #expect(chatInputUi(input: "안녕하세요", sending: false).sendEnabled)
    }

    /// 화면이 보는 한도가 **서버 한도와 같은 상수**라는 것. 예전 결함의 뿌리는 화면이 자기만의
    /// 숫자(500)를 들고 있었다는 것이다 — 숫자를 두 곳에 적으면 반드시 갈린다.
    @Test("한도는 서버와 같은 상수 하나다")
    func limitMatchesServer() {
        #expect(MAX_CONTENT_LENGTH == 1_000)
        #expect(chatInputUi(input: text(MAX_CONTENT_LENGTH), sending: false).counter == "1000/1000자")
    }
}

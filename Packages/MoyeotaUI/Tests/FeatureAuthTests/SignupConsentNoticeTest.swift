import PresentationCore
import Testing
@testable import FeatureAuth

/// 04 로그인의 「가입하면 이용약관 · 개인정보 처리방침에 동의하게 돼요」.
///
/// 2026-10-14 까지 이 줄에는 **아무 일도 하지 않는 `clickable`** 이 걸려 있었다(열 주소가 없었다).
/// 주소가 생긴 뒤에 고쳤고, 여기서 고정하는 것은 두 가지다 — ① 문장은 주소 유무와 무관하게 같다,
/// ② 주소가 없는 문서는 링크가 되지 않는다(죽은 링크를 보여 주지 않는다).
@Suite struct SignupConsentNoticeTest {
    private let terms = "https://example.com/terms/"
    private let privacy = "https://example.com/privacy/"

    @Test("주소가 있으면 두 문서가 각자 링크다")
    func eachDocumentLinks() {
        let notice = signupConsentNotice(termsUrl: terms, privacyUrl: privacy) { _ in }

        #expect(notice.urls == [terms, privacy])
    }

    /// 동의하게 된다는 사실은 주소와 무관하게 참이다 — 주소가 없을 때 문장을 바꾸거나 지우면
    /// **고지가 사라진다.** 링크만 평범한 글자로 남는다.
    @Test("문장은 주소가 없어도 그대로다")
    func sentenceStaysWithoutUrls() {
        let withLinks = signupConsentNotice(termsUrl: terms, privacyUrl: privacy) { _ in }
        let without = signupConsentNotice(termsUrl: nil, privacyUrl: nil) { _ in }

        #expect(withLinks.text == without.text)
        #expect(without.text == "가입하면 이용약관 · 개인정보 처리방침에 동의하게 돼요")
        #expect(without.urls.isEmpty, "주소가 없는데 링크가 생겼다")
    }

    @Test("주소가 하나만 있으면 그 문서만 링크다")
    func singleUrlLinksOnlyThatDocument() {
        #expect(signupConsentNotice(termsUrl: nil, privacyUrl: privacy) { _ in }.urls == [privacy])
        #expect(signupConsentNotice(termsUrl: terms, privacyUrl: nil) { _ in }.urls == [terms])
    }

    /// 플랫폼 기본 동작에 맡기지 않는다 — 받아 줄 앱이 없으면 아무 일도 없다.
    /// 앱의 다른 외부 이동과 같은 길(`ExternalIntents`)로 보내 안내 토스트로 바꾼다.
    ///
    /// `Text` 의 링크는 글자마다 리스너를 달 수 없어 `\.openURL` 하나로 모인다(`LoginScreen` 이 `onOpen` 에 잇는다).
    /// 그래서 원본처럼 링크별 리스너를 부르지 않고, 글자에 실린 주소를 `onOpen` 에 넘겨 같은 결과를 본다.
    @Test("링크를 누르면 받은 콜백으로 주소가 온다")
    func linkTapCallsBack() {
        nonisolated(unsafe) var opened: [String] = []
        let notice = signupConsentNotice(termsUrl: terms, privacyUrl: privacy) { opened.append($0) }

        notice.urls.forEach { notice.onOpen($0) }

        #expect(opened == [terms, privacy])
    }

    /// 운영 기본값으로 불러도 같은 문장이다(지금은 두 주소가 다 채워져 있다).
    @Test("기본값은 SupportLinks 의 주소를 쓴다")
    func defaultsUseSupportLinks() {
        let notice = signupConsentNotice { _ in }

        #expect(notice.urls == [SupportLinks.TERMS_URL, SupportLinks.PRIVACY_URL].compactMap { $0 })
    }
}

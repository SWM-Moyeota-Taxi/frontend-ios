import Foundation
import Testing
@testable import PresentationCore

/// 35 「문의하기」가 메일 앱에 미리 채워 넣는 본문.
///
/// 환경 정보가 빠진 문의는 "앱 버전이 무엇인가요"를 되묻는 왕복을 한 번 더 만든다.
/// 그래서 **읽기에 실패한 값도 줄 자체는 남긴다** — 줄이 사라지면 받는 쪽은 사용자가 지운 것인지
/// 앱이 못 읽은 것인지 구분할 수 없다.
///
/// 원본 기대값(「Android: 14」)을 그대로 지키려고 앞의 세 테스트는 `osLabel: "Android"` 를 넘긴다.
/// 앱이 실제로 보내는 값은 그 아래 iOS 테스트가 본다.
@Suite struct SupportMailBodyTest {
    @Test("앱 버전 Android 버전 기기 모델을 담는다")
    func containsEnvironment() {
        let body = supportMailBody(appVersion: "1.0.0", osRelease: "14", deviceModel: "Pixel 6", osLabel: "Android")
        #expect(body.contains("앱 버전: 1.0.0"))
        #expect(body.contains("Android: 14"))
        #expect(body.contains("기기: Pixel 6"))
    }

    @Test("못 읽은 값은 줄을 지우지 않고 알 수 없음으로 적는다")
    func unknownValuesKeepLines() {
        let body = supportMailBody(appVersion: nil, osRelease: nil, deviceModel: nil, osLabel: "Android")
        #expect(body.contains("앱 버전: 알 수 없음"))
        #expect(body.contains("Android: 알 수 없음"))
        #expect(body.contains("기기: 알 수 없음"))
    }

    @Test("사용자가 적을 자리가 맨 위에 비어 있다")
    func blankSpaceOnTop() {
        let body = supportMailBody(appVersion: "1.0.0", osRelease: "14", deviceModel: "Pixel 6", osLabel: "Android")
        #expect(body.hasPrefix("\n\n"))
    }

    // ─── iOS (원본에 없는 것) ───

    @Test("아이폰 문의에는 iOS 라고 적고 전체 모양은 원본과 같다")
    func iosBody() {
        let body = supportMailBody(appVersion: "1.0", osRelease: "17.2", deviceModel: "iPhone16,2")
        #expect(
            body == "\n\n--- 아래는 확인용 정보예요. 지우지 않고 보내 주세요 ---\n앱 버전: 1.0\niOS: 17.2\n기기: iPhone16,2"
        )
    }

    @Test("mailto 주소에 제목과 본문이 인코딩돼 실린다")
    func mailURL() throws {
        let url = try #require(supportMailURL(address: "a@b.com", subject: "[모여타 문의]", body: "\n\n앱 버전: 1.0"))
        #expect(url.scheme == "mailto")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "a@b.com")
        #expect(components.queryItems?.first { $0.name == "subject" }?.value == "[모여타 문의]")
        #expect(components.queryItems?.first { $0.name == "body" }?.value == "\n\n앱 버전: 1.0")
    }

    @Test("스토어 주소 - 앱 번호가 있으면 앱과 웹이 같은 앱을 가리킨다")
    func storeURLsWithId() {
        let urls = appStoreListingURLs(appStoreId: "123")
        #expect(urls.app.absoluteString == "itms-apps://apps.apple.com/app/id123")
        #expect(urls.web.absoluteString == "https://apps.apple.com/app/id123")
    }

    @Test("스토어 주소 - 앱 번호가 없어도 폴백 주소가 있다")
    func storeURLsWithoutId() {
        let urls = appStoreListingURLs(appStoreId: nil)
        #expect(urls.app.scheme == "itms-apps")
        #expect(urls.web.scheme == "https")
    }
}

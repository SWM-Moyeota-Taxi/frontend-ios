import Foundation
import UIKit

// 앱 밖으로 나가는 이동 — OS 알림 설정 · 메일 앱 · 브라우저.
//
// 화면이 아니라 여기 모아 둔 이유는 두 가지다.
// 1. **받아 줄 앱이 없으면 열기가 실패한다.** 메일 앱을 지운 기기가 실제로 있다. 그 처리를 행마다
//    되풀이하면 한 곳만 빠뜨려도 마이페이지에서 눌러도 아무 일이 없는 행이 생긴다 — 여기서 전부 잡아
//    안내 토스트로 바꾼다.
// 2. 화면은 「무엇을 누르면 어디로 나간다」만 알면 된다. 버전·기종 같은 환경 수집은 UI 가 아니다.
//
// 안내를 스낵바가 아니라 토스트로 내는 이유: 35 마이페이지에는 스낵바 호스트가 없고,
// 이 안내는 화면이 보관할 상태가 아니라 "방금 그 동작이 안 됐다"는 일회성 사실이다.
// 호스트를 세우려면 화면 골격을 바꿔야 하는데, 지금 이 한 줄 때문에 그럴 값은 아니다.

/// 문의 메일 제목 — 받는 쪽에서 필터·분류할 수 있게 고정한다.
private let SUPPORT_MAIL_SUBJECT = "[모여타 문의]"

/// 설치된 앱의 표시 버전(`CFBundleShortVersionString`, `1.0.0`). 읽기 실패하면 nil.
///
/// 35 의 버전 표기와 문의 메일 본문이 같은 값을 써야 하므로 한 곳에 둔다
/// — 두 곳에서 각자 읽으면 한쪽만 포맷이 바뀌어도 사용자가 알려 주는 버전과 표기가 어긋난다.
public func appVersionName(bundle: Bundle = .main) -> String? {
    guard let name = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
          !name.isEmpty
    else { return nil }
    return name
}

/// OS 의 **앱별 알림 설정**을 연다.
///
/// 앱 안에 알림 on/off 를 두지 않는 이유: 서버에 알림 설정 저장 API 가 없다. 앱이 자체 토글을
/// 들고 있으면 꺼 둔 채 기기를 바꾸면 되살아나고, 서버는 그대로 푸시를 보낸다 — 지키지 못할 약속이다.
/// OS 설정은 실제로 적용되는 **유일한 진짜 스위치**라 그쪽으로 넘긴다.
@MainActor
public func openAppNotificationSettings() {
    openExternal(
        URL(string: UIApplication.openNotificationSettingsURLString),
        fallbackMessage: "설정 앱을 열 수 없어요. 휴대폰 설정 → 앱 → 모여타 → 알림에서 바꿀 수 있어요"
    )
}

/// 문의 메일을 **제목과 환경 정보까지 채운 채** 메일 앱으로 띄운다.
///
/// `mailto:` 를 쓴다 — 공유 시트로 보내면 메신저·클라우드까지 후보로 떠서 사용자가 문의를 메일이 아닌
/// 곳으로 보내게 된다.
@MainActor
public func openSupportEmail(address: String) {
    let body = supportMailBody(
        appVersion: appVersionName(),
        osRelease: UIDevice.current.systemVersion,
        deviceModel: deviceModelIdentifier()
    )
    // 메일 앱이 없으면 주소라도 알려 준다 — 문의할 길이 아예 없는 것보다 낫다
    openExternal(
        supportMailURL(address: address, subject: SUPPORT_MAIL_SUBJECT, body: body),
        fallbackMessage: "메일 앱이 없어요. \(address) 로 보내 주세요"
    )
}

/// 외부 웹 페이지(약관 · 개인정보 처리방침)를 기본 브라우저로 연다.
@MainActor
public func openWebPage(url: String) {
    openExternal(URL(string: url), fallbackMessage: "브라우저를 열 수 없어요. \(url) 을 직접 열어 주세요")
}

/// 스토어의 이 앱 페이지를 연다. 강제 업데이트 화면의 「업데이트하러 가기」가 쓴다.
/// 이름은 원본을 따랐고, iOS 에서는 App Store 를 연다.
///
/// `itms-apps://` 을 먼저 쓰는 이유: App Store 앱이 **바로** 열려 설치 버튼까지 한 번에 간다.
/// 브라우저를 거치면 로그인·리다이렉트가 끼어들 수 있다. 다만 App Store 앱을 지운 기기에서는
/// 열기가 실패하므로, **반드시** https 로 폴백해야 한다 — 폴백이 없으면 그 사용자는 잠긴 화면에서
/// 나갈 길이 영영 없다.
@MainActor
public func openPlayStoreListing() {
    let targets = appStoreListingURLs(appStoreId: SupportLinks.APP_STORE_ID)
    UIApplication.shared.open(targets.app, options: [:]) { opened in
        if !opened {
            Task { @MainActor in openWebPage(url: targets.web.absoluteString) }
        }
    }
}

/// 스토어 앱으로 여는 주소와 브라우저 폴백 주소. 앱 번호가 아직 없으면(`SupportLinks.APP_STORE_ID`) 검색 결과로 보낸다.
func appStoreListingURLs(appStoreId: String?) -> (app: URL, web: URL) {
    if let appStoreId {
        return (
            URL(string: "itms-apps://apps.apple.com/app/id\(appStoreId)")!,
            URL(string: "https://apps.apple.com/app/id\(appStoreId)")!
        )
    }
    let term = "%EB%AA%A8%EC%97%AC%ED%83%80" // 모여타
    return (
        URL(string: "itms-apps://search.itunes.apple.com/WebObjects/MZSearch.woa/wa/search?media=software&term=\(term)")!,
        URL(string: "https://apps.apple.com/kr/search?term=\(term)")!
    )
}

/// 문의 메일 본문 — 사용자가 적을 자리를 위에 비워 두고, 아래에 환경 정보를 미리 채운다.
///
/// 환경 정보를 넣는 이유: 없으면 문의 한 건마다 "앱 버전·기종이 무엇인가요"를 되묻는 왕복이
/// 한 번 더 생긴다. 읽기에 실패한 값은 비워 두지 않고 「알 수 없음」으로 적는다
/// — 줄이 사라지면 받는 쪽은 사용자가 지운 것인지 앱이 못 읽은 것인지 구분할 수 없다.
///
/// `osLabel` 은 원본의 「Android:」 자리다. 아이폰 문의에 「Android: 17.2」라고 적으면 받는 쪽을 속이므로 기본값이 iOS 다.
public func supportMailBody(
    appVersion: String?,
    osRelease: String?,
    deviceModel: String?,
    osLabel: String = "iOS"
) -> String {
    """


    --- 아래는 확인용 정보예요. 지우지 않고 보내 주세요 ---
    앱 버전: \(appVersion ?? "알 수 없음")
    \(osLabel): \(osRelease ?? "알 수 없음")
    기기: \(deviceModel ?? "알 수 없음")
    """
}

/// `mailto:` 주소. iOS 에서는 다른 앱에 제목·본문을 넘길 길이 쿼리뿐이다.
func supportMailURL(address: String, subject: String, body: String) -> URL? {
    var components = URLComponents()
    components.scheme = "mailto"
    components.path = address
    components.queryItems = [
        URLQueryItem(name: "subject", value: subject),
        URLQueryItem(name: "body", value: body),
    ]
    return components.url
}

/// `Build.MODEL` 의 자리. `UIDevice.model` 은 「iPhone」 뿐이라 기종 식별자(`iPhone16,2`)를 읽는다.
func deviceModelIdentifier() -> String? {
    if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
        return simulated
    }
    var info = utsname()
    guard uname(&info) == 0 else { return nil }
    let identifier = withUnsafeBytes(of: &info.machine) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
    return identifier.isEmpty ? nil : identifier
}

@MainActor
private func openExternal(_ url: URL?, fallbackMessage: String) {
    guard let url else {
        MoyeotaToast.show(fallbackMessage)
        return
    }
    UIApplication.shared.open(url, options: [:]) { opened in
        if !opened {
            Task { @MainActor in MoyeotaToast.show(fallbackMessage) }
        }
    }
}

/// `Toast.makeText(…, LENGTH_LONG)` 의 자리. iOS 에 시스템 토스트가 없어 창 위에 직접 얹는다.
///
/// 어떤 화면에서든 화면 상태 없이 부를 수 있어야 해서 SwiftUI 상태가 아니라 UIKit 뷰다.
@MainActor
enum MoyeotaToast {
    /// `LENGTH_LONG` = 3.5초
    private static let duration = Duration.milliseconds(3_500)
    private static weak var current: UIView?

    static func show(_ message: String) {
        guard let window = keyWindow() else { return }
        current?.removeFromSuperview()

        let label = UILabel()
        label.text = message
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 14)
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = UIView()
        container.backgroundColor = UIColor(white: 0.2, alpha: 0.95)
        container.layer.cornerRadius = 20
        container.isUserInteractionEnabled = false
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        window.addSubview(container)
        current = container

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            container.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            container.leadingAnchor.constraint(greaterThanOrEqualTo: window.leadingAnchor, constant: 24),
            container.trailingAnchor.constraint(lessThanOrEqualTo: window.trailingAnchor, constant: -24),
            container.bottomAnchor.constraint(equalTo: window.safeAreaLayoutGuide.bottomAnchor, constant: -64),
        ])

        UIAccessibility.post(notification: .announcement, argument: message)

        Task { @MainActor [weak container] in
            try? await Task.sleep(for: duration)
            container?.removeFromSuperview()
        }
    }

    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
    }
}

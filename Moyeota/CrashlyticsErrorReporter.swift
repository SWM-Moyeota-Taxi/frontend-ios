import FirebaseCrashlytics
import Foundation
import MoyeotaDomain

/// `Diagnostics` 가 올린 실패를 Crashlytics 의 **non-fatal** 로 보낸다.
///
/// 앱은 계속 돈다. 사용자가 보는 것은 아무것도 바뀌지 않고, 대시보드에만 한 줄이 남는다.
///
/// ### 원본 오류를 그대로 넘기지 않는다 — 이게 이 파일의 존재 이유다
/// `record(error:)` 에 원본을 넘기면 **오류 내용이 그대로 Google 로 간다.** 이 앱에서 가장 흔한 보고 대상이
/// 파싱 실패인데, 그 오류의 설명에는 실패한 **응답 본문의 키·값**이 들어 있을 수 있고 그 본문에는
/// 닉네임·실명·휴대폰번호·좌표·채팅 본문이 있을 수 있다. 한 번 나가면 앱에서 지울 수 없고,
/// 처리방침이 「보내지 않습니다」라고 적은 것과 정면으로 어긋난다.
///
/// 그래서 `sanitize` 가 **종류와 위치만** 남긴 보고를 새로 만든다.
/// - 메시지: 지점 이름 + 오류 **타입 이름** 사슬. 값은 하나도 없다.
/// - 스택트레이스: 보고 시점의 호출 주소. 파일·메서드·줄 번호로만 복원돼 안전하고,
///   이게 있어야 Crashlytics 가 같은 결함을 한 묶음으로 센다.
///   (원본은 예외의 스택을 옮긴다. Swift `Error` 는 스택을 들고 있지 않아 `Diagnostics.report` 를 부른 자리가 기준이다.)
/// - cause: **연결하지 않는다.** 원인 사슬을 붙이면 그 메시지들이 같이 따라간다.
///
/// ### 커스텀 키를 쓰지 않는다
/// `setCustomValue` 는 **세션 전역**이라 동시에 두 건이 보고되면 값이 뒤섞인다. 지점 이름은
/// 메시지 맨 앞에 박아 두므로 키 없이도 대시보드에서 갈린다.
enum CrashlyticsErrorReporter {

    /// 대시보드에서 「앱이 스스로 처리한 실패」와 「진짜 크래시」가 타입 이름으로 바로 갈린다(원본 `ReportedFailure`).
    private static let REPORTED_FAILURE_NAME = "ReportedFailure"

    private static let MAX_CAUSE_DEPTH = 3

    /// `Diagnostics` 에 sink 를 꽂는다. `MoyeotaApplication` 이 Firebase 를 구성한 뒤 한 번 부른다.
    static func install() {
        Diagnostics.install { site, throwable in
            // `crashlytics()` 를 **보고 시점에** 부른다. 프로퍼티 초기화에 두면
            // Firebase 초기화 실패가 첫 보고가 아니라 앱 시작 지점에서 터진다.
            Crashlytics.crashlytics().record(exceptionModel: sanitize(site, throwable))
        }
    }

    /// 값이 하나도 실리지 않은 보고를 만든다.
    ///
    /// 사슬은 **세 단계까지만** 본다 — 그 아래는 묶음 판정에 보탬이 없고 메시지만 길어진다.
    private static func sanitize(_ site: FailureSite, _ throwable: any Error) -> ExceptionModel {
        var names: [String] = []
        var current: (any Error)? = throwable
        while let error = current, names.count < MAX_CAUSE_DEPTH {
            names.append(typeName(error))
            current = causeOf(error)
        }
        let model = ExceptionModel(
            name: REPORTED_FAILURE_NAME,
            reason: "\(site.name) · \(names.joined(separator: " <- "))"
        )
        model.stackTrace = Thread.callStackReturnAddresses.map { StackFrame(address: $0.uintValue) }
        return model
    }

    /// 타입 이름만 쓴다. `localizedDescription`·`debugDescription` 은 값을 담을 수 있어 건드리지 않는다.
    ///
    /// `NSError` 는 타입이 모두 같아 묶음이 갈리지 않으므로 도메인을 붙인다(상수라 값이 아니다).
    private static func typeName(_ error: any Error) -> String {
        let dynamicType = type(of: error)
        let name = String(reflecting: dynamicType)
        guard dynamicType is NSError.Type else { return name }
        return "\(name)(\((error as NSError).domain))"
    }

    private static func causeOf(_ error: any Error) -> (any Error)? {
        if let throwable = error as? any Throwable { return throwable.cause }
        if let decoding = error as? DecodingError { return decoding.context?.underlyingError }
        return (error as NSError).userInfo[NSUnderlyingErrorKey] as? any Error
    }
}

private extension DecodingError {
    var context: Context? {
        switch self {
        case .typeMismatch(_, let context),
             .valueNotFound(_, let context),
             .keyNotFound(_, let context),
             .dataCorrupted(let context):
            context
        @unknown default:
            nil
        }
    }
}

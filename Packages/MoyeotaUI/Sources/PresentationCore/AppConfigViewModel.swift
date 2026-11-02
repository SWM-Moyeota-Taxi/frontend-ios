import MoyeotaDomain
import Observation
import os

private let logger = Logger(subsystem: "com.moyeota.presentation", category: "AppConfig")

/// 시작 시 조회가 실패했을 때의 재시도 간격. 서버 재기동·네트워크 복구 정도를 기다린다.
private let RETRY_DELAYS_MS: [Int64] = [2_000, 5_000, 15_000]

/// 서버 운영 설정(`GET /api/v1/config`). 내비게이션 스택 바깥(앱 루트)에 두어 화면들이 한 값을 공유한다
/// (`UserProfileViewModel` 과 같은 이유).
///
/// - 시작 시 한 번 읽고, 실패하면 `RETRY_DELAYS_MS` 간격으로 몇 번 더 시도한다. 그래도 못 받으면
///   `AppConfig.Default`(동승 모드)로 간다 — 실사용자 서버가 동승 모드라 틀려도 실제 서비스와 같은 화면이다.
/// - 앱이 다시 앞으로 올 때 아직 못 받았으면 다시 시도한다(`loadIfUnresolved`).
/// - 디버그 빌드는 `setDebugOverride` 로 서버 값을 덮어쓸 수 있다(35 마이페이지 개발자 옵션).
///   메모리에만 들고 있어 프로세스가 죽으면 서버 값으로 돌아간다.
@MainActor
@Observable
public final class AppConfigViewModel {
    /// 서버가 준 그대로의 값(디버그 강제값 미적용). 개발자 옵션의 「서버 값」 표시용.
    public private(set) var serverConfig: AppConfig = .Default

    /// 디버그 강제값. nil 이면 서버 값을 따른다.
    public private(set) var debugOverride: Bool?

    /// 서버 응답을 한 번이라도 받았는가. false 면 지금 값은 기본값이다.
    public private(set) var resolved = false

    /// 화면이 따를 설정 — 강제값이 있으면 강제값, 없으면 서버 값.
    ///
    /// **복사 후 수정이어야 한다.** `AppConfig(taxiEnabled: …)` 로 새로 만들면 서버가 준 나머지 필드
    /// (minVersionCode·recommendedVersionCode)가 조용히 기본값으로 되돌아가 게이트가 영영 안 걸린다.
    /// 디버그 강제값은 택시 모드 하나만 뒤집는다.
    public var config: AppConfig {
        var merged = serverConfig
        merged.taxiEnabled = effectiveTaxiEnabled(server: serverConfig.taxiEnabled, override: debugOverride)
        return merged
    }

    @ObservationIgnored private let repository: any AppConfigRepository
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let scope = ViewModelScope()
    /// 진행 중인 조회. 끝나면 nil 이다(`Job.isActive` 의 자리).
    @ObservationIgnored private(set) var loading: Task<Void, Never>?

    public init(
        repository: any AppConfigRepository,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.repository = repository
        self.sleep = sleep
        load()
    }

    /// 서버 값을 다시 읽는다. 이미 읽는 중이면 겹쳐 띄우지 않는다.
    public func load() {
        if loading != nil { return }
        let repository = self.repository
        let sleep = self.sleep
        loading = scope.launch { [weak self] in
            defer { self?.loading = nil }
            var attempt = 0
            while true {
                let failure: any Error
                do {
                    let config = try await repository.getConfig()
                    guard !Task.isCancelled, let self else { return }
                    self.serverConfig = config
                    self.resolved = true
                    let label = AppMode.of(taxiEnabled: config.taxiEnabled).label
                    logger.info("서버 설정 수신 — 모드=\(label, privacy: .public)")
                    return
                } catch {
                    // 살아 있는 태스크의 `URLError(.cancelled)` 는 원본 `runCatching` 처럼 실패로 쳐서 다시 시도한다.
                    if Task.isCancelled { return }
                    failure = error
                }
                guard attempt < RETRY_DELAYS_MS.count else {
                    logger.warning(
                        "설정 조회 실패(재시도 소진) — 기본값(동승 모드)으로 진행: \(failure.localizedDescription, privacy: .public)"
                    )
                    return
                }
                let wait = RETRY_DELAYS_MS[attempt]
                attempt += 1
                logger.warning(
                    "설정 조회 실패 — \(wait / 1000)초 뒤 재시도: \(failure.localizedDescription, privacy: .public)"
                )
                do {
                    try await sleep(.milliseconds(wait))
                } catch {
                    return
                }
            }
        }
    }

    /// 복귀(onResume)마다 부른다. 아직 서버 값을 못 받았을 때만 다시 시도한다.
    public func loadIfUnresolved() {
        if !resolved { load() }
    }

    /// 디버그 전용 — 서버 값과 무관하게 모드를 고정한다. nil 이면 해제.
    public func setDebugOverride(taxiEnabled: Bool?) {
        debugOverride = taxiEnabled
        let label = taxiEnabled.map { AppMode.of(taxiEnabled: $0).label } ?? "해제(서버 값)"
        logger.info("디버그 모드 강제: \(label, privacy: .public)")
    }
}

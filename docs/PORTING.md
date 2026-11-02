# Android(Kotlin) → iOS(Swift) 포팅 규칙

원본: Android 저장소 [SWM-Moyeota/frontend](https://github.com/SWM-Moyeota/frontend). 이 문서의 원본 경로는 그 저장소 기준이다 (브랜치 `develop`, 커밋 `301e3d4`). **원본은 읽기만 한다.**
목표는 **같은 앱**이다. 화면·문구·규칙·서버 계약이 같고, 플랫폼이 강제하는 부분만 다르다.

## 1. 원칙

1. **동작을 옮긴다. 다시 설계하지 않는다.** 분기·상수(폴링 주기, 재시도, 글자 수 제한, 타임아웃)·오류 매핑·상태 전이·경로·JSON 키를 그대로 옮긴다. 「더 나은 방법」이 보여도 바꾸지 않는다.
2. **사용자에게 보이는 문구는 글자 그대로.** 띄어쓰기·문장부호까지 복사한다. 번역·다듬기 금지.
3. **빈칸을 남기지 않는다.** `TODO`, `fatalError("not implemented")`, 가짜 데이터, 빈 콜백 금지. 원본에 있는 기능은 다 옮긴다. 정말로 iOS 에서 불가능하면 대체 동작을 구현하고 `docs/IOS-DIFFERENCES.md` 에 한 줄 추가한다.
4. **원본의 주석이 이유를 설명한다.** KDoc 은 왜 그런 분기가 있는지를 적어 둔 기록이다 — 읽고 나서 옮겨라. 이유를 담은 주석은 한국어로 유지하고, Android 전용 사정(`minSdk`, `SurfaceView` 등)은 빼거나 iOS 사정으로 바꾼다.
5. **테스트도 옮긴다.** 원본 테스트 하나당 Swift 테스트 하나. 이름은 `@Test("원본 함수명 또는 한국어 설명")`. 단언을 약하게 만들지 않는다. 테스트가 실패하면 테스트가 아니라 구현을 고친다 — 원본 기대값이 진실이다.
6. **자기 모듈만 고친다.** 아래층에 공개 API 가 빠졌으면 `public` 추가·공개 init 추가는 해도 된다. 의미를 바꾸는 수정이 필요하면 최종 보고에 적는다.

## 2. 파일 위치

| Android | iOS |
|---|---|
| `domain/.../model`, `repository`, `session`, `diagnostics` | `Packages/MoyeotaCore/Sources/MoyeotaDomain/{Model,Repository,Session,Diagnostics,Support}` |
| `data/.../remote`, `remote/dto`, `remote/auth`, `remote/chat`, `remote/matching` | `.../MoyeotaData/Remote/{,DTO,Auth,Chat,Matching}` |
| `data/.../repository`, `session`, `local`, `push` | `.../MoyeotaData/{Repository,Session,Local,Push}` |
| `core/designsystem/.../theme`, `component` | `Packages/MoyeotaUI/Sources/MoyeotaDesignSystem/{Theme,Component}` |
| `presentation/.../core` (`MainNavGraph`, `Routes` 제외) | `.../PresentationCore` |
| `presentation/.../core/MainNavGraph.kt`, `Routes.kt` | `.../AppNavigation` |
| `presentation/.../feature/<x>` | `.../Feature<X>` (auth→FeatureAuth, mypage→FeatureMyPage …) |
| `app/...` | `Moyeota/` (앱 타깃 — Firebase 는 여기서만 안다) |
| `*/src/test/...` | 대응 모듈의 `Tests/<모듈>Tests` |

파일 이름은 원본과 같게 한다(`RideHistoryRoute.kt` → `RideHistoryRoute.swift`). 대응 모듈에 첫 파일을 넣을 때 `Placeholder.swift` 를 지운다.

기능 모듈끼리는 서로 import 할 수 없다. 원본의 기능 간 참조 다섯 개는 **PresentationCore 로 옮긴다**: `headcountLabel`(home), `CheckMarkIcon`(auth), `authUserMessage`·`NicknamePolicy`·`NicknameCheckState`(auth), `ChatForeground`(chat).

## 3. 언어 대응

Swift 6 언어 모드(엄격한 동시성), iOS 17, Swift Testing(`import Testing`).

| Kotlin | Swift |
|---|---|
| `data class` | `public struct …: Equatable, Sendable` — 프로퍼티는 `public var`(`copy` 대신 복사 후 수정), **public init 을 직접 쓰고 기본값을 그대로** |
| `enum class X { RECRUITING }` | `public enum X { case recruiting }` (카멜케이스). 서버 문자열은 DTO/매퍼에서 원본 문자열로 비교 |
| `sealed class/interface` | 연관값 enum. 서브타입이 많고 공통 프로퍼티가 있으면 enum + 계산 프로퍼티 |
| `Long` / `Int` / `Double` | `Int64` / `Int` / `Double` |
| `suspend fun` | `async throws`(원본이 예외를 던질 수 있으면). 코루틴 취소는 `CancellationError` 로 전파 — **`catch` 에서 삼키지 말 것** (`runCatching` 이 취소를 삼키던 곳은 원본 의도를 확인) |
| `StateFlow` / `MutableStateFlow` | `MoyeotaDomain` 의 `StateFlow` / `MutableStateFlow` (`Support/StateFlow.swift`). 구독은 `for await v in flow.values()` |
| `Flow` / `SharedFlow` / `Channel` | `AsyncStream` / `AsyncThrowingStream` (`onTermination` 에서 정리) |
| `delay(ms)` | `try await Task.sleep(for: .milliseconds(ms))`. 테스트가 시간을 제어하던 곳은 `sleep: @Sendable (Duration) async throws -> Void` 를 주입 |
| `Mutex` / `synchronized` / `@Volatile` | `actor` 또는 `OSAllocatedUnfairLock`·`NSLock` |
| `java.time.LocalDate` | `MoyeotaDomain.LocalDate` (도메인 포팅 때 만든다) |
| `Log.w` | `os.Logger` |
| Kotlin 패키지 `internal`, 파일 `private` | 같은 모듈 안 공유는 `internal`, 다른 모듈에서 쓰면 `public`. 테스트는 `@testable import` |
| 최상위 함수·확장 프로퍼티 | 최상위 함수·extension. 이름 유지 |

이름은 Kotlin 의 카멜케이스를 그대로 쓴다(`Ride.isHostedByMe`, `updateRequirement(config:installedVersionCode:)`). 다른 에이전트가 원본 이름으로 찾아올 수 있어야 한다.

### JSON

`Codable` + `JSONDecoder`. kotlinx.serialization 과 다른 점을 조심한다:

- Swift 합성 디코더는 **기본값이 있어도 키가 없으면 실패한다.** 기본값이 있는 DTO 필드는 `init(from:)` 에서 `decodeIfPresent(...) ?? 기본값` 으로 직접 쓴다.
- 원본의 `@SerialName`·`Json { ... }` 설정(`ignoreUnknownKeys`, `coerceInputValues`, `explicitNulls`)을 `NetworkModule.kt` 에서 확인하고 그대로 맞춘다. 요청 본문에서 null 을 보내는지 생략하는지도 맞춘다 — 서버 계약이다.
- 숫자/문자열이 섞여 오는 필드, 날짜 포맷은 원본 매퍼를 따른다.

### 네트워크

Retrofit·OkHttp → `URLSession`. 서드파티 라이브러리 없이 쓴다. Interceptor/Authenticator 의 동작(헤더 부착, 401 시 단일 갱신·재시도, 경로 제외 목록)을 그대로 옮긴다. SSE 는 `URLSession.bytes`, STOMP(krossbow)는 `URLSessionWebSocketTask` 위에 직접 구현. HTTP 테스트는 `URLProtocol` 스텁으로 MockWebServer 를 대신한다. 토큰 저장은 Keychain 이며 저장 인터페이스(`TokenStorage`)는 원본과 같다.

## 4. UI 대응

Compose → SwiftUI. `Route`(상태·부수효과) / `Screen`(그리기)의 분리와 파일 구조를 유지한다.

| Compose | SwiftUI |
|---|---|
| `ViewModel` + `StateFlow<UiState>` | `@MainActor @Observable final class …ViewModel`, `private(set) var uiState`. `UiState` 구조체는 원본 그대로 |
| `viewModelScope.launch` | `scope.launch { [weak self] in … }` — `PresentationCore.ViewModelScope`. 뷰모델이 해제되면 취소된다 |
| `viewModel(factory = …)` | `@HostedViewModel private var vm: X` + `init { _vm = HostedViewModel(wrappedValue: X(…)) }`. **`@State var vm = X()` 금지** — 뷰 init 마다 뷰모델이 새로 만들어져 원본의 `init { refresh() }` 가 반복된다 |
| `collectAsState` | `@Observable` 프로퍼티 읽기. 도메인 `StateFlow` 는 뷰모델에서 `for await` 로 받아 프로퍼티에 넣는다 |
| `rememberSaveable` | `@State`. 위에 화면이 쌓여도 남는다(프로세스가 죽으면 사라지는 것만 다르다) |
| `remember` | `@State` + 값이 돌아왔을 때 보이면 `.onDisappear` 에서 처음 값으로 되돌린다. Compose Navigation 은 화면을 덮으면 그 컴포지션을 버려 `remember` 가 사라지지만, `@State` 는 스택에 있는 동안 남는다 |
| `LaunchedEffect(key)` | `.task(id: key)`. 키 없는 진입 효과(`LaunchedEffect(Unit)`)로 부수 효과를 내면 `.topEntryTask` — `.task` 는 덮인 화면에서 다시 돌 수 있다(`isTopStackEntry`) |
| `DisposableEffect` | `.onAppear` / `.onDisappear` 또는 `.task` 의 취소 |
| `LifecycleStartEffect` / `LifecycleResumeEffect` | `.lifecycleEffect(onStart:onStop:)` (`PresentationCore`) — 화면이 보임 **그리고** 앱이 전면일 때만 시작 상태 |
| `BackHandler` | `.moyeotaBackHandler(enabled:action:)` (`PresentationCore`, 스와이프 뒤로가기도 함께 막고 action 을 부른다) |
| `Scaffold` + 자체 상단바 | 시스템 내비게이션 바를 쓰지 않는다. 원본의 상단바 컴포넌트를 그대로 그린다 |
| `Column` / `Row` / `Box` / `LazyColumn` | `VStack(spacing: 0)` / `HStack(spacing: 0)` / `ZStack` / `ScrollView` + `LazyVStack` 또는 `List` |
| `Modifier.imePadding()` | SwiftUI 기본 키보드 회피. 맞지 않으면 `.ignoresSafeArea(.keyboard)` 와 조합 |
| `ModalBottomSheet`, `AlertDialog` | `.sheet`(detent) / 원본 시각 디자인을 살린 커스텀 오버레이. 문구·버튼 순서 유지 |
| `Icons.*` (머티리얼 아이콘) | 가장 가까운 SF Symbol. 원본이 Canvas/Path 로 그린 아이콘은 `Canvas`/`Path` 로 옮긴다 |
| `coil AsyncImage` | `SwiftUI.AsyncImage` 또는 `MoyeotaDesignSystem` 의 캐시 이미지 뷰 |
| Naver `MapView` | `NMFMapView` 를 감싼 `UIViewRepresentable`. `import NMapsMap` |
| `FusedLocationProviderClient` | `CLLocationManager` |
| `Intent(ACTION_VIEW/DIAL/SENDTO)` | `UIApplication.shared.open(URL)` — `@Environment(\.openURL)` |
| `MoyeotaColor.*`, `MoyeotaType.*`, dp/sp | `MoyeotaDesignSystem` 의 같은 이름. dp → pt 1:1, sp → pt 1:1 |
| `@Preview` | 옮기지 않는다 |

폰트는 원본처럼 시스템 기본 sans(SF + Apple SD Gothic Neo)를 쓴다. 다크 모드 없음(`UIUserInterfaceStyle=Light`). 세로 고정.

**화면은 원본과 같아 보여야 한다.** 여백·모서리·색·글자 크기 값을 원본에서 그대로 옮긴다. 참고 스크린샷: `_workspace/play-assets/*.png`, `_workspace/landing/assets/shots/*.webp`. 디자인 토큰: `DESIGN-moyeota.md`, `moyeota-figma-tokens.json`. 화면 이동 규칙의 근거: `docs/MODE-ROUTES.md`.

## 5. 빌드·테스트

```bash
scripts/check.sh core-build              # MoyeotaCore (macOS, swift build)
scripts/check.sh core-test [필터]         # MoyeotaCore 테스트
scripts/check.sh build FeatureHome       # UI 모듈 빌드 (시뮬레이터 대상)
scripts/check.sh test FeatureHome        # UI 모듈 테스트
scripts/check.sh app                     # 앱 전체
```

결과 줄만 출력되고 전체 로그 경로가 함께 나온다. 작업을 끝내기 전에 해당 모듈의 빌드와 테스트가 **실제로 통과한 출력**을 확인한다. 통과를 확인하지 못했으면 통과했다고 보고하지 않는다.

코드에서 쓰지 말 것: `git commit`, `git push`, 원본 저장소 수정, 서드파티 의존성 추가, 운영 서버(`api.moyeota.co.kr`)에 대한 쓰기 요청.

## 6. 코어 계층에서 정해진 것 (화면 포팅 때 지킬 것)

- `Diagnostics.report(site:throwable:httpStatus:)` 는 `throws` 다. 취소를 되던지기 때문이다 — `catch` 안에서 `try` 로 부른다.
- **조용히 끝내도 되는 것은 정말 취소된 태스크(`Task.isCancelled`)뿐이다.** `HttpClient` 는 태스크 취소를 `CancellationError` 로 바꾸므로 `URLError(.cancelled)` 가 그대로 올라왔다면 태스크는 살아 있다(세션 무효화·인증 챌린지 취소 등). 원본에서 이 값은 OkHttp `IOException("Canceled")`, 곧 네트워크 실패다. 화면 계층에서 `if isCancellation(throwable: error) { return }` 으로 끝내면 아무도 스피너·잠금을 풀어 주지 않는다. 원본의 `catch (e: CancellationException) { throw e }` 자리에는 `if Task.isCancelled { return }` 을 쓰고, 문구가 네트워크 실패로 갈리는 화면은 `failureOnLiveTask(error:transportCancelled:)`(`PresentationCore`, 인증은 `authFailureOnLiveTask`)로 같은 실패 값을 만든다. `isCancellation(throwable:)` 은 전송 실패를 분류하는 데이터 계층(`Diagnostics` 포함)의 판정이다 — `Diagnostics.report` 는 `URLError(.cancelled)` 도 되던지므로 살아 있는 태스크에서 실패로 남겨야 하면 `try?` 로 부른다.
- `for try await` 수집이 취소되면 오류 없이 루프가 끝난다(코루틴은 예외를 던진다). 루프 뒤 코드가 「스트림이 끝났다」를 뜻하면 그 앞에서 `try Task.checkCancellation()` 을 부른다. **`MatchWaitingRoute` 의 `streamEnded` 가 대표 사례다.**
- 프로토콜에 정적 멤버를 둘 수 없어 `ChatRepository.DEFAULT_PAGE_SIZE` 는 `ChatRepositoryDefaults.DEFAULT_PAGE_SIZE`, `RideRecordRepository` 도 같은 꼴이다.
- `LocalDate.of(_:_:_:)` 는 Java 처럼 던지고, `LocalDate(year:month:dayOfMonth:)` 는 실패 시 nil 이다(원본 `runCatching { LocalDate.of(...) }.getOrNull()` 자리). 파라미터 이름은 Kotlin 이름을 유지한다(`isOldEnough(birthDate:today:)`).
- 문자열 보조는 `MoyeotaDomain/Support/KotlinText.swift`(`String.trim()`, `isBlank`, Kotlin 문자 판정)를 쓴다. Swift 기본 동작과 다른 경우가 있어 임의로 대체하지 않는다.
- 서버 `Instant` 파싱은 소수 초 유무를 모두 받아야 한다. `ChatRoute.kt`·`RideHistoryDisplay.kt` 의 시간 표시를 옮길 때 원본과 같은 입력을 받는지 테스트한다.

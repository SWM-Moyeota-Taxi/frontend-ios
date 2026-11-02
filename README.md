# 모여타 iOS

합승 매칭 앱 모여타의 iOS 앱이다. Android 앱(`frontend`)을 SwiftUI 로 옮겼고, 화면·문구·규칙·서버 계약을 같게 두는 것이 목표다.

## 요구 사항

- Xcode 26.3 으로 빌드·테스트했다. 배포 대상은 iOS 17.0, 언어 모드는 Swift 6.
- `scripts/check.sh test` 는 iOS 26.3 시뮬레이터 런타임과 iPhone 17 기기 유형을 쓴다.
- 처음 빌드할 때 Swift 패키지(Firebase 13.1.1, 네이버 지도 3.23.3)를 받으므로 인터넷이 필요하다.

## 처음 설정

1. 비밀값 파일을 만든다. 이 파일은 git 에 올라가지 않는다.

   ```bash
   cp Config/Secrets.xcconfig.example Config/Secrets.xcconfig
   ```

2. `Config/Secrets.xcconfig` 를 채운다.
   - `NAVER_MAPS_CLIENT_ID`: 네이버 지도 NCP Key ID. 비어 있어도 빌드는 되고 지도만 런타임 인증에 실패한다.
   - `DEVELOPMENT_TEAM`: Apple Team ID. 실기기에 설치할 때 서명에 쓴다. 쓰지 않으면 예시 값을 남기지 말고 줄을 지운다.
3. (선택) Firebase 콘솔에서 받은 `GoogleService-Info.plist` 를 `Moyeota/GoogleService-Info.plist` 에 둔다. git 에 올라가지 않는다. 없어도 앱은 돌고 푸시·Crashlytics 만 꺼진다.

**기본 서버는 운영 서버다.** `Config/Base.xcconfig` 의 `MOYEOTA_BASE_URL` 이 `https://api.moyeota.co.kr/` 이므로, 로컬 서버를 쓰려면 아래 두 방법 중 하나로 바꾼다.

## 실행

`Moyeota.xcodeproj` 를 Xcode 로 열고 `Moyeota` 스킴을 실행한다.

## 서버 주소 바꾸기

- 빌드 설정: `Config/Secrets.xcconfig` 에 적는다. `//` 는 xcconfig 주석이라 `$()` 로 끊는다.

  ```
  MOYEOTA_BASE_URL = http:/$()/localhost:8080/
  ```

  평문 `http` 는 Debug 빌드에서만 허용되므로 Release 에서는 `https` 주소만 닿는다.

- Debug 실행 때만(다시 빌드하지 않음): 실행 인자나 환경 변수로 넘긴다. 저장되지 않으며, Release 바이너리에는 이 코드가 없다.

  ```bash
  xcrun simctl launch <기기> com.moyeota -MOYEOTA_BASE_URL_OVERRIDE http://localhost:8080/
  SIMCTL_CHILD_MOYEOTA_BASE_URL_OVERRIDE=http://localhost:8080/ xcrun simctl launch <기기> com.moyeota
  ```

## 테스트

```bash
scripts/check.sh core-build              # MoyeotaCore 빌드 (macOS)
scripts/check.sh core-test [필터]         # MoyeotaCore 테스트 (macOS)
scripts/check.sh build FeatureHome       # UI 모듈 빌드 (시뮬레이터)
scripts/check.sh test FeatureHome        # UI 모듈 테스트 (시뮬레이터)
scripts/check.sh test-all                # UI 전체 테스트, 빌드 한 번 (CI 와 같다)
scripts/check.sh app                     # 앱 전체 빌드
scripts/check.sh release                 # 실기기용 Release 빌드와 디버그 코드 제거 확인
```

오류·실패·결과 줄만 출력한다. 전체 로그와 빌드 산출물은 `~/Library/Caches/moyeota-ios-check` 에 있다(`MOYEOTA_CHECK_DIR` 로 바꿀 수 있다). 시뮬레이터는 `moyeota-check-<모듈>` 이름으로 알아서 만든다.

## 모듈

| 위치 | 내용 |
|---|---|
| `Moyeota/` | 앱 타깃. Firebase 는 여기서만 안다 |
| `Packages/MoyeotaCore` → `MoyeotaDomain` | 모델, 저장소 인터페이스, 세션, 진단 |
| `Packages/MoyeotaCore` → `MoyeotaData` | 네트워크(REST, SSE, STOMP), 저장소 구현, 로컬 저장 |
| `Packages/MoyeotaUI` → `MoyeotaDesignSystem` | 테마, 공통 컴포넌트, 네이버 지도 |
| `Packages/MoyeotaUI` → `PresentationCore` | 기능 모듈이 함께 쓰는 화면 계층 |
| `Packages/MoyeotaUI` → `AppNavigation` | 탭과 화면 이동 |
| `Packages/MoyeotaUI` → `FeatureAuth`, `FeatureOnboarding`, `FeatureHome`, `FeatureExplore`, `FeatureMatching`, `FeatureChat`, `FeatureMyPage` | 기능별 화면. 기능 모듈끼리는 서로 import 하지 않는다 |

## 문서

- [docs/PORTING.md](docs/PORTING.md): Android 에서 옮기는 규칙
- [docs/IOS-DIFFERENCES.md](docs/IOS-DIFFERENCES.md): 플랫폼 때문에 Android 와 다르게 동작하는 부분

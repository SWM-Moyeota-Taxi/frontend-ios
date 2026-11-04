# 행동 이벤트와 Mixpanel

앱이 어떤 사용자 행동을 기록하고, 그걸 Mixpanel 에서 어떻게 보는지 적는다. 기획 문서(PRD)의 「이벤트 목록」 자리이기도
하다 — 새 기능의 이벤트는 코드보다 먼저 **이 표에** 적고, 구현이 끝나면 `AnalyticsTest` 가 이름을 못 박는다.

배경은 2026-11-02 AB 테스트 특강 정리다. 요지는 「AB 테스트 전에 이벤트부터, 초기 서비스는 모수가 적으니 이벤트 분석 +
유저 인터뷰로 개선하라」였고, 모여타의 핵심 가치 퍼널을 **가입 → 매칭 신청 → 매칭 완료**로 잡았다.

## 구조

| 자리 | 파일 | 역할 |
|---|---|---|
| domain | `Packages/MoyeotaCore/Sources/MoyeotaDomain/Analytics/Analytics.swift` | 이벤트 정의(`AnalyticsEvent`), 전역 sink(`Analytics.track`), 지역·연령대 변환 |
| presentation | 각 ViewModel · `MainNavGraph` | 행동이 **성공한 자리**에서 `Analytics.track(...)` 한 줄 |
| app | `Moyeota/MixpanelAnalyticsReporter.swift` | Mixpanel SDK 초기화, sink 연결, 세션을 따라 `identify`/`reset` |

`Diagnostics`(Crashlytics non-fatal)와 같은 구조다. domain 은 Mixpanel 을 모르고, 테스트는 sink 를 녹음기로 바꿔 꽂는다.
Mixpanel 을 아는 파일은 리포터 하나라서 Amplitude 로 바꾸더라도 그 파일만 다시 쓴다.

## 이벤트 목록

이름은 특강에서 권한 **동작_대상** 꼴이고, 세부는 이름을 늘리지 않고 프로퍼티로 싣는다. 이름을 바꾸면 Mixpanel 보고서도
함께 고쳐야 하므로 `AnalyticsTest.eventNames` 가 전부를 고정한다.

### 핵심 퍼널

| 순서 | 이벤트 | 기록 시점 | 프로퍼티 |
|---|---|---|---|
| 1 | `complete_signup` | 12 매너 서약에서 가입 + 자동 로그인이 **모두** 끝났을 때 | `gender`(male/female/undisclosed), `age_band`(10s·20s·…·60s+) |
| 2 | `request_match` | 16 방 만들기 또는 20 합류가 서버에 받아들여졌을 때 | `method`(create/join), `capacity`, `origin_area`, `destination_area`, `estimated_fare` |
| 3 | `complete_match` | 21 매칭 대기가 방 상태를 정원 충족(MATCHED) 이상으로 처음 봤을 때 | `capacity`, `member_count`, `waited_seconds`(화면 진입 기준) |

### 나머지

| 종류 | 이벤트 | 기록 시점 | 프로퍼티 |
|---|---|---|---|
| View | `view_screen` | 내비게이션 스택의 맨 위가 바뀔 때마다 | `screen` = `Route.destination`(예: `home`, `matching/waiting`, `chat/room/{roomId}`) |
| Click | `click_create_party` | 16 「방 만들기」를 눌러 요청이 나감 | `capacity` |
| Click | `click_join_party` | 20 「합류하기」를 눌러 요청이 나감 | — |
| Action | `complete_login` | 04a 아이디 로그인 성공 | — |
| Action | `fail_match_request` | 방 만들기·합류가 거절됨 | `method`, `reason`(already_in_party·party_full·party_closed·party_not_found·already_joined·same_departure_destination·out_of_service_area·invalid_capacity·route_unavailable·network·unknown) |
| Action | `cancel_match` | 21 「그만 찾기」·「방 나가기」 성공 | `capacity`, `member_count` |
| Action | `finish_party` | 동승 모드 「합승 완료」 성공(방장) | `member_count` |
| Action | `finish_ride` | 택시 모드에서 운행 종료를 감지해 33 으로 넘어감 | — |
| Action | `trigger_emergency` | 27 긴급 신고 3초 홀드 완료 | — |
| Action | `delete_account` | 37 탈퇴가 204 를 받음 | — |

모든 이벤트에 리포터가 `build`(debug/release)를 super property 로 붙인다. Mixpanel SDK 가 OS·앱 버전·기기 모델을 알아서 붙인다.

### Click 과 Action 을 가르는 이유

「눌렀다」와 「됐다」는 다른 사실이다. `click_create_party` 만 세면 409 로 막힌 신청도 전환으로 보이고, `request_match` 만 세면
「누르긴 했는데 왜 안 됐나」를 볼 수 없다. 둘 사이의 차이가 곧 `fail_match_request` 의 `reason` 분포다.

## 보내지 않는 것

처리방침과 `MoyeotaApplication` 의 Crashlytics 주석이 정한 선을 그대로 지킨다.

- 실명·휴대폰·이메일·아이디·비밀번호·채팅 본문 — 어디에도 없다.
- 좌표·장소명·번지 — `origin_area`/`destination_area` 는 `administrativeArea` 가 **시/도 + 시/군/구**까지만 남긴 값이다
  (`"서울 관악구 남부순환로 1820"` → `"서울 관악구"`). 합류 쪽은 방 상세에 주소가 없어 지역을 싣지 않는다.
- 생년월일 — `ageBand` 가 10년 구간으로 접는다. 성별 + 연령대까지만.
- 방 id·동승자 식별자 — 프로퍼티에 넣지 않는다. 채팅방 화면 이름도 `chat/room/{roomId}` 패턴 그대로다.

### 사용자 식별은 한다 — Crashlytics 와 다른 결정

리포터가 `UserSession.authState` 를 구독해 로그인하면 서버 `publicId`(uuid)로 `identify`, 로그아웃·탈퇴·세션 만료면
`reset` 한다. Crashlytics 에는 일부러 `setUserID` 를 넣지 않았지만(`MoyeotaApplication` 주석), Mixpanel 은 사용자 단위
퍼널·리텐션이 목적이라 식별자 없이는 쓸 수 없다. 그래서 다음을 함께 해야 한다.

- **개인정보 처리방침**에 Mixpanel(미국, Mixpanel Inc.)로의 국외 이전과 수집 항목(기기 식별자·행동 기록·시/구 단위 지역·
  성별·연령대·회원 식별자)을 적는다.
- **App Store Connect 개인정보 라벨**을 `Moyeota/PrivacyInfo.xcprivacy` 와 같게 맞춘다(사용자 ID·기기 ID·제품 상호작용·
  대략적 위치·기타 데이터, 모두 「이용자와 연결됨」, 추적 아님).
- **탈퇴 요청**이 오면 서버뿐 아니라 Mixpanel 프로필도 지운다(Mixpanel 콘솔 Users → 프로필 → Delete, 또는 GDPR API).
  `delete_account` 이벤트가 그 사용자를 찾는 열쇠다.

## 설정

1. Mixpanel 프로젝트 토큰(Settings → Project Settings → Project Token)을 `Config/Secrets.xcconfig` 에 적는다.

   ```
   MIXPANEL_TOKEN = <프로젝트 토큰>
   ```

   지금은 프로젝트 **하나**(moyeota, 4080134)에 운영·개발이 같이 들어가고, 리포터가 붙이는 `build`(debug/release)로 가른다 —
   보고서에 Filter `build = release` 를 걸면 개발 중 찍은 가입·매칭이 빠진다. 완전히 나누고 싶으면 개발용 프로젝트를 하나 더
   만들고 `MIXPANEL_TOKEN[config=Debug] = <개발 프로젝트 토큰>` 한 줄을 더한다 — Debug 빌드만 그쪽으로 간다.

   비어 있으면 리포터가 SDK 를 켜지 않고 `Analytics.track` 은 무동작이다 — 토큰 없이 빌드한 앱이 깨지거나 남의 프로젝트로
   이벤트를 쏘지 않는다.
2. TestFlight 는 GitHub Secrets `MIXPANEL_TOKEN` 을 읽는다(`.github/workflows/testflight.yml`). 비어 있어도 업로드는 되고
   이벤트만 꺼진다.
3. Debug 빌드는 `loggingEnabled` 라 Xcode 콘솔에 보낸 이벤트가 찍힌다. Mixpanel 콘솔까지 가지 않고 심어졌는지 확인하는 길이다.

## Mixpanel 에서 볼 것

특강에서 짚은 지표를 Mixpanel 보고서로 옮기면 이렇다. 대시보드 하나에 네 장을 모아 둔다.

| 보고서 | 종류 | 설정 |
|---|---|---|
| 핵심 퍼널 | Funnels | `complete_signup` → `request_match` → `complete_match`, 전환 기간 **1일**(= 가입 당일 매칭 완료율). 2→3 이탈이 크면 「정원이 안 찬다」, 1→2 가 크면 「가입했는데 신청까지 못 간다」 |
| 재매칭 | Retention | 시작 이벤트·복귀 이벤트 모두 `complete_match`, 주간. 「핵심 가치를 다시 쓰는가」 |
| 신청 실패 사유 | Insights | `fail_match_request` 를 `reason` 으로 나눠 본다. `already_in_party` 가 많으면 유령 방 문제, `party_full` 이 많으면 공급 부족 |
| 어디서 모이나 | Insights | `request_match` 를 `origin_area`·`destination_area` 로 나눠 본다. 지역 한정 마케팅의 근거 |

보조로 `view_screen` 을 `screen` 으로 나눈 Flows(화면 흐름)와 `cancel_match` 의 `member_count` 분포(몇 명 모였을 때 포기하나)를 본다.

### MCP 로 묻기

Mixpanel 은 MCP 서버를 제공한다. Claude Code 에 연결하면 콘솔을 열지 않고 대시보드를 만들거나 질문할 수 있다.

```
claude mcp add --transport http mixpanel https://mcp.mixpanel.com/mcp
```

추가한 뒤 Claude Code 안에서 `/mcp` 를 실행해 Mixpanel OAuth 로그인을 끝낸다. 연결 뒤 프롬프트 예: 「complete_signup → request_match → complete_match 가 핵심 퍼널이다. 이 외에 핵심이라고 생각하는
플로우들을 대시보드로 구축해 줘」, 「지난 2주 fail_match_request 의 reason 분포와 그 원인 가설을 정리해 줘」.

## 이벤트를 더할 때

1. 이 문서의 표에 먼저 적는다(기획 문서가 있으면 그쪽에도). 이름은 `동작_대상`, 프로퍼티는 snake_case.
2. `AnalyticsEvent` 에 케이스를 더하고 `name`·`properties` 를 채운다 — `AnalyticsTest.eventNames` 표에도 한 줄.
3. 행동이 **성공한 자리**(서버 응답 뒤)에서 `Analytics.track(...)`. 버튼 탭 자체를 세고 싶으면 `click_*` 을 따로 둔다.
4. 프로퍼티에 사람을 특정할 수 있는 값이 들어가지 않는지 본다. 위 「보내지 않는 것」 절이 기준이다.
5. 그 ViewModel 테스트에 녹음기 sink 를 꽂아 「성공했을 때만, 한 번만」을 확인한다(`CreatePartyAnalyticsTest` 가 본보기).

## AB 테스트는 아직

특강의 결론과 같다 — 지금 모수로는 통계적으로 의미 있는 결과가 나오지 않는다. 먼저 위 퍼널을 몇 주 보고, 가설이 서면
Mixpanel Feature Flags + Experiments 로 간다. 그때 클라이언트 쪽은 리포터에 플래그 조회를 더하고 variant 를 super property 로
붙이면 되고, 유저 식별은 이미 `identify` 로 맞춰져 있어 같은 사람이 같은 군에 들어간다.

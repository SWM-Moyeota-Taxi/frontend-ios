#!/bin/bash
# 모듈 단위 빌드·테스트. 병렬 작업이 서로의 산출물을 건드리지 않도록 모듈마다 DerivedData·시뮬레이터를 따로 쓴다.
#
#   scripts/check.sh core-build                  MoyeotaCore 빌드 (macOS)
#   scripts/check.sh core-test [필터]            MoyeotaCore 테스트 (macOS)
#   scripts/check.sh build <모듈>                MoyeotaUI 모듈 빌드 (시뮬레이터)
#   scripts/check.sh test <모듈> [테스트타깃]     MoyeotaUI 모듈 테스트. 타깃 기본값은 <모듈>Tests
#   scripts/check.sh test-all                    MoyeotaUI 전체 테스트. 빌드를 한 번만 해 CI 에서 쓴다
#   scripts/check.sh app                         앱 전체 빌드
#   scripts/check.sh release                     실기기용 Release 빌드 + 디버그 전용 코드가 빠졌는지 확인
#
# 출력은 오류·실패·결과 줄만 남긴다. 전체 로그는 $WORK/log-<이름>.txt 에 있다.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${MOYEOTA_CHECK_DIR:-$HOME/Library/Caches/moyeota-ios-check}"
mkdir -p "$WORK"
CLONES="$WORK/clones-ui"
# Packages/MoyeotaUI/Package.resolved 가 앱 전체 의존성(Firebase 포함)을 잠근다. 자동 해석을 끄지 않으면
# 패키지 스킴으로 빌드할 때 이 파일을 UI 의존성만으로 다시 써, 잠금이 풀리고 추적 파일이 바뀐다.

# 설치된 iOS 런타임 중 최신. 러너와 개발 기기의 런타임 버전이 달라 고정하지 않는다.
latest_ios_runtime() {
  xcrun simctl list runtimes available | sed -n 's/^iOS .* - \(com\.apple\.CoreSimulator\.SimRuntime\.iOS-.*\)$/\1/p' | sort -V | tail -1
}

sim_for() {
  local name="moyeota-check-$1"
  local id
  id=$(xcrun simctl list devices available | sed -n "s/^ *$name (\([0-9A-F-]*\)).*/\1/p" | head -1)
  if [ -z "$id" ]; then
    id=$(xcrun simctl create "$name" "iPhone 17" "${MOYEOTA_SIM_RUNTIME:-$(latest_ios_runtime)}")
  fi
  echo "$id"
}

# 테스트 타깃 하나만 담은 스킴. 전체 스킴(MoyeotaUI-Package)은 모든 모듈을 빌드해,
# 다른 모듈이 작업 중이면 함께 깨진다.
write_test_scheme() {
  local target="$1"
  local dir="$ROOT/Packages/MoyeotaUI/.swiftpm/xcode/xcshareddata/xcschemes"
  mkdir -p "$dir"
  cat > "$dir/$target.xcscheme" <<SCHEME
<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2600" version = "1.7">
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "$target" BuildableName = "$target" BlueprintName = "$target" ReferencedContainer = "container:">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
</Scheme>
SCHEME
}

filter() {
  grep -v CHHapticPattern | grep -E "(error:|\*\* .* \*\*|Test run with|✘|Test .* failed|Suite .* failed|failed \(|Testing failed|executed .* tests)" | sort -u | head -"${1:-120}"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  core-build)
    LOG="$WORK/log-core-build.txt"
    (cd "$ROOT/Packages/MoyeotaCore" && swift build --scratch-path "$WORK/core-build" 2>&1) > "$LOG"
    rc=$?; filter < "$LOG"; [ $rc = 0 ] && echo "CORE BUILD OK" || echo "CORE BUILD FAILED (log: $LOG)"; exit $rc ;;
  core-test)
    LOG="$WORK/log-core-test.txt"
    args=(); [ $# -ge 1 ] && args=(--filter "$1")
    (cd "$ROOT/Packages/MoyeotaCore" && swift test --scratch-path "$WORK/core-build" ${args[@]+"${args[@]}"} 2>&1) > "$LOG"
    rc=$?; filter 200 < "$LOG"; [ $rc = 0 ] && echo "CORE TEST OK" || echo "CORE TEST FAILED (log: $LOG)"; exit $rc ;;
  build)
    mod="$1"; LOG="$WORK/log-build-$mod.txt"
    (cd "$ROOT/Packages/MoyeotaUI" && xcodebuild build -scheme "$mod" \
      -destination "generic/platform=iOS Simulator" \
      -derivedDataPath "$WORK/dd-$mod" -clonedSourcePackagesDirPath "$CLONES" \
      -skipPackagePluginValidation -skipMacroValidation -disableAutomaticPackageResolution \
      CODE_SIGNING_ALLOWED=NO 2>&1) > "$LOG"
    rc=$?; filter < "$LOG"; [ $rc = 0 ] && echo "BUILD OK: $mod" || echo "BUILD FAILED: $mod (log: $LOG)"; exit $rc ;;
  test)
    mod="$1"; target="${2:-${mod}Tests}"; LOG="$WORK/log-test-$mod.txt"
    sim=$(sim_for "$mod")
    write_test_scheme "$target"
    (cd "$ROOT/Packages/MoyeotaUI" && xcodebuild test -scheme "$target" \
      -destination "id=$sim" -parallel-testing-enabled NO \
      -derivedDataPath "$WORK/dd-test-$mod" -clonedSourcePackagesDirPath "$CLONES" \
      -skipPackagePluginValidation -skipMacroValidation -disableAutomaticPackageResolution \
      CODE_SIGNING_ALLOWED=NO 2>&1) > "$LOG"
    rc=$?; filter 200 < "$LOG"; [ $rc = 0 ] && echo "TEST OK: $target" || echo "TEST FAILED: $target (log: $LOG)"; exit $rc ;;
  test-all)
    LOG="$WORK/log-test-all.txt"
    sim=$(sim_for "all")
    (cd "$ROOT/Packages/MoyeotaUI" && xcodebuild test -scheme MoyeotaUI-Package \
      -destination "id=$sim" -parallel-testing-enabled NO \
      -derivedDataPath "$WORK/dd-test-all" -clonedSourcePackagesDirPath "$CLONES" \
      -skipPackagePluginValidation -skipMacroValidation -disableAutomaticPackageResolution \
      CODE_SIGNING_ALLOWED=NO 2>&1) > "$LOG"
    rc=$?; filter 200 < "$LOG"; [ $rc = 0 ] && echo "TEST OK: all UI modules" || echo "TEST FAILED: all UI modules (log: $LOG)"; exit $rc ;;
  app)
    LOG="$WORK/log-app.txt"
    (cd "$ROOT" && xcodebuild build -project Moyeota.xcodeproj -scheme Moyeota \
      -destination "generic/platform=iOS Simulator" \
      -derivedDataPath "$WORK/dd-app" -clonedSourcePackagesDirPath "$CLONES" \
      -skipPackagePluginValidation -skipMacroValidation -disableAutomaticPackageResolution \
      CODE_SIGNING_ALLOWED=NO 2>&1) > "$LOG"
    rc=$?; filter < "$LOG"; [ $rc = 0 ] && echo "APP BUILD OK" || echo "APP BUILD FAILED (log: $LOG)"; exit $rc ;;
  release)
    LOG="$WORK/log-release.txt"
    (cd "$ROOT" && xcodebuild build -project Moyeota.xcodeproj -scheme Moyeota -configuration Release \
      -destination "generic/platform=iOS" \
      -derivedDataPath "$WORK/dd-release" -clonedSourcePackagesDirPath "$CLONES" \
      -skipPackagePluginValidation -skipMacroValidation -disableAutomaticPackageResolution \
      CODE_SIGNING_ALLOWED=NO 2>&1) > "$LOG"
    rc=$?; filter < "$LOG"
    [ $rc = 0 ] || { echo "RELEASE BUILD FAILED (log: $LOG)"; exit $rc; }
    APP="$WORK/dd-release/Build/Products/Release-iphoneos/Moyeota.app"
    # 디버그 빌드에서만 허용한 서버 주소 변경과 평문 통신이 출시 빌드에 섞이면 안 된다.
    if grep -raq MOYEOTA_BASE_URL_OVERRIDE "$APP"; then
      echo "RELEASE CHECK FAILED: MOYEOTA_BASE_URL_OVERRIDE 가 Release 번들에 있다"; exit 1
    fi
    if /usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity' "$APP/Info.plist" >/dev/null 2>&1; then
      echo "RELEASE CHECK FAILED: Release Info.plist 에 ATS 예외가 있다"; exit 1
    fi
    echo "RELEASE BUILD OK"; exit 0 ;;
  *)
    sed -n 2,12p "$0"; exit 2 ;;
esac

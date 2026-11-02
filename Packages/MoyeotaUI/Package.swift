// swift-tools-version: 6.0
// iOS 전용 UI 계층. Android 의 :core:designsystem + :presentation 에 해당한다.
// presentation 을 기능별 모듈로 나눈 이유: 기능끼리 컴파일이 격리돼 병렬 작업이 서로를 깨뜨리지 않는다.
import PackageDescription

let features: [String] = []

let package = Package(
    name: "MoyeotaUI",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "MoyeotaDesignSystem", targets: ["MoyeotaDesignSystem"]),
        .library(name: "PresentationCore", targets: ["PresentationCore"]),
    ] + features.map { .library(name: $0, targets: [$0]) },
    dependencies: [
        .package(path: "../MoyeotaCore"),
        // Android 의 naverMapSdk 3.23.3 과 같은 버전으로 고정한다.
        .package(url: "https://github.com/navermaps/SPM-NMapsMap.git", exact: "3.23.3"),
    ],
    targets: [
        .target(
            name: "MoyeotaDesignSystem",
            dependencies: [.product(name: "NMapsMap", package: "SPM-NMapsMap")]
        ),
        .target(
            name: "PresentationCore",
            dependencies: [
                "MoyeotaDesignSystem",
                .product(name: "MoyeotaDomain", package: "MoyeotaCore"),
            ]
        ),
        .testTarget(name: "PresentationCoreTests", dependencies: ["PresentationCore"]),
    ]
        + features.map {
            .target(name: $0, dependencies: ["PresentationCore", "MoyeotaDesignSystem"])
        }
        + features.map {
            .testTarget(name: "\($0)Tests", dependencies: [.target(name: $0), "PresentationCore"])
        }
)

// swift-tools-version: 6.0
// 플랫폼 독립 계층(도메인·데이터). macOS 에서도 빌드돼 `swift test` 로 시뮬레이터 없이 검증한다.
import PackageDescription

let package = Package(
    name: "MoyeotaCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MoyeotaDomain", targets: ["MoyeotaDomain"]),
    ],
    targets: [
        .target(name: "MoyeotaDomain"),
        .testTarget(name: "MoyeotaDomainTests", dependencies: ["MoyeotaDomain"]),
    ]
)

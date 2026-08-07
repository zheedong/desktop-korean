// swift-tools-version: 5.9

import PackageDescription
let package = Package(
    name: "AhaKeyConfig",
    platforms: [
        .macOS("12.0")
    ],
    products: [
        .executable(name: "AhaKeyConfig", targets: ["AhaKeyConfig"]),
        .executable(name: "ahakeyconfig-agent", targets: ["AhaKeyConfigAgent"]),
        .executable(name: "PluginShowcase", targets: ["PluginShowcase"]),
        .library(name: "AhaKeyPluginKit", targets: ["AhaKeyPluginKit"]),
    ],

    targets: [
        .target(
            name: "AhaKeyPluginKit",
            path: "Sources/AhaKeyPluginKit"
        ),
        .executableTarget(
            name: "Plugin",
            dependencies: ["AhaKeyPluginKit"],
            path: "Sources/AhaKeyPlugin"
        ),
        .executableTarget(
            name: "PluginShowcase",
            dependencies: ["AhaKeyPluginKit"],
            path: "Sources/AhaKeyPluginShowcase"
        ),
        .executableTarget(
            name: "AhaKeyConfig",
            dependencies: ["AhaKeyPluginKit"],
            path: "Sources",
            exclude: ["Agent", "AhaKeyPlugin", "AhaKeyPluginKit", "AhaKeyPluginShowcase"],
            // scripts/build.sh의 Info.plist와 일치합니다. __info_plist 섹션으로 임베드하면 TCC가 인식할 수 있습니다.
            // 디버그는 별도의 plist를 사용합니다: 시스템 "개인정보 보호 및 보안" 목록에 "AhaKey Studio (디버그)"로 표시되어 정식 패키지와 구분됩니다.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Packaging/AhaKeyConfig-EmbeddedInfo-Debug.plist",
                ], .when(platforms: [.macOS], configuration: .debug)),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Packaging/AhaKeyConfig-EmbeddedInfo.plist",
                ], .when(platforms: [.macOS], configuration: .release)),
            ]
        ),
        .executableTarget(
            name: "AhaKeyConfigAgent",
            path: "Sources/Agent"
        ),
    ]
)

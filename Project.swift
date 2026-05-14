import ProjectDescription

let project = Project(
    name: "DontBlastMySound",
    targets: [
        .target(
            name: "DontBlastMySound",
            destinations: .macOS,
            product: .app,
            bundleId: "dev.tuist.DontBlastMySound",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "LSUIElement": true,
                "NSLocationWhenInUseUsageDescription": "Speaker Lock uses your current Wi-Fi network name to detect when you may have moved to a new environment.",
            ]),
            buildableFolders: [
                "DontBlastMySound/Sources",
                "DontBlastMySound/Resources",
            ],
            dependencies: []
        ),
        .target(
            name: "DontBlastMySoundTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "dev.tuist.DontBlastMySoundTests",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .default,
            buildableFolders: [
                "DontBlastMySound/Tests"
            ],
            dependencies: [.target(name: "DontBlastMySound")]
        ),
    ]
)

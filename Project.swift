import ProjectDescription

let project = Project(
    name: "Muzzle",
    targets: [
        .target(
            name: "Muzzle",
            destinations: .macOS,
            product: .app,
            bundleId: "dev.tuist.Muzzle",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "LSUIElement": true,
                "NSLocationWhenInUseUsageDescription": "Speaker Lock uses your current Wi-Fi network name to detect when you may have moved to a new environment.",
            ]),
            buildableFolders: [
                "Muzzle/Sources",
                "Muzzle/Resources",
            ],
            dependencies: []
        ),
        .target(
            name: "MuzzleTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "dev.tuist.MuzzleTests",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .default,
            buildableFolders: [
                "Muzzle/Tests"
            ],
            dependencies: [.target(name: "Muzzle")]
        ),
    ]
)

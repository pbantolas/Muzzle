import ProjectDescription

let project = Project(
    name: "Muzzle",
    targets: [
        .target(
            name: "Muzzle",
            destinations: .macOS,
            product: .app,
            bundleId: "dev.bantolas.Muzzle",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "LSUIElement": true,
                "NSLocationWhenInUseUsageDescription": "Speaker Lock uses your current Wi-Fi network name to detect when you may have moved to a new environment.",
            ]),
            buildableFolders: [
                "Muzzle/Sources",
                "Muzzle/Resources",
            ],
            dependencies: [],
            settings: .settings(base: [
                "MARKETING_VERSION": "0.1.0",
                "CURRENT_PROJECT_VERSION": "1",
            ])
        ),
        .target(
            name: "MuzzleTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "dev.bantolas.MuzzleTests",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .default,
            buildableFolders: [
                "Muzzle/Tests"
            ],
            dependencies: [.target(name: "Muzzle")]
        ),
    ]
)

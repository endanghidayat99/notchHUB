// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchHub",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/airbnb/lottie-spm.git", from: "4.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "NotchHub",
            dependencies: [
                .product(name: "Lottie", package: "lottie-spm"),
            ],
            path: "Sources/NotchHub",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("Metal"),
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)

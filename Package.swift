// swift-tools-version:5.9
// Build nhanh không cần XcodeGen:
//   swift build -c release
//   ./Scripts/make_app.sh  (đóng gói .app từ binary của SPM)
import PackageDescription

let package = Package(
    name: "OpenPhotobooth",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OpenPhotobooth",
            path: "Sources",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "OpenPhotoboothTests",
            dependencies: ["OpenPhotobooth"],
            path: "Tests",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)

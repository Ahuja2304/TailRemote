// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TailRemote",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .executable(
            name: "MacHost",
            targets: ["MacHost"]
        ),
        .library(
            name: "TailRemote",
            targets: ["TailRemote"]
        )
    ],
    targets: [
        .target(
            name: "TailRemote",
            path: "Sources/TailRemote"
        ),
        .executableTarget(
            name: "MacHost",
            dependencies: ["TailRemote"],
            path: "Sources/MacHost"
        )
    ]
)

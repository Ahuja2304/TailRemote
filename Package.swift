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
        )
    ],
    targets: [
        .executableTarget(
            name: "MacHost",
            path: "Sources",
            exclude: ["TailRemoteiOS"],
            sources: ["TailRemote", "MacHost"]
        )
    ]
)

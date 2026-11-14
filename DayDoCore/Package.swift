// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DayDoCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "DayDoCore", targets: ["DayDoCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.12.0"),
    ],
    targets: [
        .target(name: "DayDoCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "DayDoCoreTests", dependencies: ["DayDoCore"]),
    ]
)

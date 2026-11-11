// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FriendLedgerCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "FriendLedgerCore", targets: ["FriendLedgerCore"])],
    targets: [
        .target(name: "FriendLedgerCore"),
        .executableTarget(
            name: "LedgerCoreChecks",
            dependencies: ["FriendLedgerCore"],
            path: "Tests/LedgerCoreChecks"
        )
    ]
)

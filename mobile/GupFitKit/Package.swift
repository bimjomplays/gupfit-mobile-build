// swift-tools-version: 6.0
// GupFitKit: GupFit's plain logic (foods, nutrients, meal log, workouts, recipes, validation, repository protocols)
// and its SQLite storage, so it builds and tests on Linux in seconds (`swift test` here). The app target compiles these
// same files into the app (mobile/ios/project.yml), the way GupWorks' GupKit does, so nothing needs to be `public`.
// SQLite is the system library: Apple's SDK module `SQLite3` on iOS/macOS, `CSQLite` (libsqlite3) on Linux.
import PackageDescription

let package = Package(
    name: "GupFitKit",
    platforms: [.iOS("26.0"), .macOS(.v15)],
    products: [.library(name: "GupFitKit", targets: ["GupFitKit"])],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite", providers: [.apt(["libsqlite3-dev"])]),
        .target(name: "GupFitKit", dependencies: [.target(name: "CSQLite", condition: .when(platforms: [.linux]))]),
        .testTarget(name: "GupFitKitTests", dependencies: ["GupFitKit"]),
    ]
)

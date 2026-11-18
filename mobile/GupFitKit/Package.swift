// swift-tools-version: 6.0
// GupFitKit: GupFit's plain logic (foods, nutrients, meal log, workouts, recipes, validation, repository protocols),
// Foundation only, so it builds and tests on Linux in seconds (`swift test` here). The app target compiles these same
// files into the app (mobile/ios/project.yml), the way GupWorks' GupKit does, so nothing needs to be `public`.
import PackageDescription

let package = Package(
    name: "GupFitKit",
    platforms: [.iOS("26.0"), .macOS(.v15)],
    products: [.library(name: "GupFitKit", targets: ["GupFitKit"])],
    targets: [
        .target(name: "GupFitKit"),
        .testTarget(name: "GupFitKitTests", dependencies: ["GupFitKit"]),
    ]
)

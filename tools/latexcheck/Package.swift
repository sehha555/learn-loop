// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "latexcheck",
    platforms: [.macOS(.v13)],
    dependencies: [.package(url: "https://github.com/mgriebling/SwiftMath", exact: "1.7.3")],
    targets: [.executableTarget(name: "latexcheck", dependencies: ["SwiftMath"])]
)

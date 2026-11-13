// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PisaCore", platforms: [.macOS(.v15)], products: [.library(name: "PisaCore", targets: ["PisaCore"])], targets: [.target(name: "PisaCore", resources: [.process("Resources")]), .executableTarget(name: "PisaMCP", dependencies: ["PisaCore"]), .testTarget(name: "PisaCoreTests", dependencies: ["PisaCore"])], swiftLanguageModes: [.v5])

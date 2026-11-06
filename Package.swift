// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PisyaCore", platforms: [.macOS(.v15)], products: [.library(name: "PisyaCore", targets: ["PisyaCore"])], targets: [.target(name: "PisyaCore", resources: [.process("Resources")]), .executableTarget(name: "PisyaMCP", dependencies: ["PisyaCore"]), .testTarget(name: "PisyaCoreTests", dependencies: ["PisyaCore"])], swiftLanguageModes: [.v5])

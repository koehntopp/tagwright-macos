// swift-tools-version:5.9
import PackageDescription

let package = Package(
	name: "Tagwright",
	platforms: [.macOS("15.0")],
	targets: [
		.executableTarget(name: "Tagwright", path: "Sources/Tagwright"),
		.testTarget(name: "TagwrightTests", dependencies: ["Tagwright"], path: "Tests/TagwrightTests"),
	]
)

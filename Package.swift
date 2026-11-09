// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Galleria",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Galleria", targets: ["Galleria"])
    ],
    targets: [
        .executableTarget(
            name: "Galleria",
            path: "Sources/Galleria",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("CoreServices")
            ]
        )
    ]
)

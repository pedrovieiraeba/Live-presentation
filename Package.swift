// swift-tools-version:5.9
import PackageDescription

// Núcleo multiplataforma (compila e é testado também em Linux/CI) +
// aplicativo macOS (SwiftUI/AppKit), declarado apenas quando o host é macOS.

var products: [Product] = [
    .library(name: "PresentationCore", targets: ["PresentationCore"]),
    .library(name: "Persistence", targets: ["Persistence"]),
    .library(name: "Diagnostics", targets: ["Diagnostics"]),
]

var targets: [Target] = [
    .target(name: "Diagnostics"),
    .target(name: "PresentationCore", dependencies: ["Diagnostics"]),
    .systemLibrary(
        name: "CSQLite",
        path: "Sources/CSQLite",
        pkgConfig: "sqlite3",
        providers: [.apt(["libsqlite3-dev"])]
    ),
    .target(
        name: "Persistence",
        dependencies: [
            "PresentationCore",
            "Diagnostics",
            // No macOS o SQLite vem do SDK (módulo SQLite3); em Linux, do sistema.
            .target(name: "CSQLite", condition: .when(platforms: [.linux])),
        ]
    ),
    .testTarget(name: "DiagnosticsTests", dependencies: ["Diagnostics"]),
    .testTarget(name: "PresentationCoreTests", dependencies: ["PresentationCore"]),
    .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "PresentationCore"]),
]

#if os(macOS)
products.append(.executable(name: "LivePresentation", targets: ["LivePresentationApp"]))
targets.append(
    .executableTarget(
        name: "LivePresentationApp",
        dependencies: ["PresentationCore", "Persistence", "Diagnostics"]
    )
)
#endif

let package = Package(
    name: "LivePresentation",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)

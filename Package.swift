// swift-tools-version:5.9
import PackageDescription

// Núcleo multiplataforma (compila e é testado também em Linux/CI) +
// aplicativo macOS (SwiftUI/AppKit), declarado apenas quando o host é macOS.

var products: [Product] = [
    .library(name: "PresentationCore", targets: ["PresentationCore"]),
    .library(name: "Persistence", targets: ["Persistence"]),
    .library(name: "Diagnostics", targets: ["Diagnostics"]),
    .library(name: "MediaLibrary", targets: ["MediaLibrary"]),
    .library(name: "CompositionCore", targets: ["CompositionCore"]),
    .library(name: "NDIService", targets: ["NDIService"]),
]

var targets: [Target] = [
    .target(name: "Diagnostics"),
    .target(name: "PresentationCore", dependencies: ["Diagnostics"]),
    .target(name: "MediaLibrary", dependencies: ["Diagnostics"]),
    .target(name: "CompositionCore", dependencies: ["PresentationCore"]),
    // Ponte C para o NDI SDK carregado dinamicamente (o SDK não é dependência de build).
    .target(name: "CNDI", linkerSettings: [.linkedLibrary("dl", .when(platforms: [.linux]))]),
    .target(name: "NDIService", dependencies: ["CNDI", "Diagnostics"]),
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
            "MediaLibrary",
            "CompositionCore",
            "Diagnostics",
            // No macOS o SQLite vem do SDK (módulo SQLite3); em Linux, do sistema.
            .target(name: "CSQLite", condition: .when(platforms: [.linux])),
        ]
    ),
    .testTarget(name: "DiagnosticsTests", dependencies: ["Diagnostics"]),
    .testTarget(name: "PresentationCoreTests", dependencies: ["PresentationCore"]),
    .testTarget(name: "PersistenceTests",
                dependencies: ["Persistence", "PresentationCore", "MediaLibrary", "CompositionCore"]),
    .testTarget(name: "MediaLibraryTests", dependencies: ["MediaLibrary"]),
    .testTarget(name: "CompositionCoreTests", dependencies: ["CompositionCore", "PresentationCore"]),
    .testTarget(name: "NDIServiceTests", dependencies: ["NDIService", "CNDI"]),
]

#if os(macOS)
products.append(.executable(name: "LivePresentation", targets: ["LivePresentationApp"]))
targets.append(contentsOf: [
    // Motor de composição Metal (somente macOS).
    .target(
        name: "CompositionEngine",
        dependencies: ["CompositionCore", "MediaLibrary", "PresentationCore", "NDIService", "Diagnostics"]
    ),
    .executableTarget(
        name: "LivePresentationApp",
        dependencies: ["PresentationCore", "Persistence", "Diagnostics", "MediaLibrary",
                       "CompositionCore", "CompositionEngine", "NDIService"]
    ),
])
#endif

let package = Package(
    name: "LivePresentation",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)

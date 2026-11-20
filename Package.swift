// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "AgenticPDF",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AgenticPDF", targets: ["AgenticPDF"]),
    ],
    dependencies: [
        .package(url: "https://github.com/leviouwendijk/Agentic.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/AgenticIO.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/PDF.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Workspace.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Path.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Schema.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Macros.git", branch: "master")
    ],
    targets: [
        .target(name: "AgenticPDF", dependencies: [
            .product(name: "Agentic", package: "Agentic"),
            .product(name: "AgenticIO", package: "AgenticIO"),
            .product(name: "PDFCore", package: "PDF"),
            .product(name: "PDFApple", package: "PDF"),
            .product(name: "Workspace", package: "Workspace"),
            .product(name: "Path", package: "Path"),
            .product(name: "Schema", package: "Schema"),
            .product(name: "Macros", package: "Macros")
        ]),
    ],
    swiftLanguageModes: [.v6]
)

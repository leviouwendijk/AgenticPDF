// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "AgenticPDFTests",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "t_agentic_pdf", targets: ["AgenticPDFTests"])
    ],
    dependencies: [
        .package(url: "https://github.com/leviouwendijk/Agentic.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/PDF.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Workspace.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Path.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/IO.git", branch: "master"),,
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(name: "AgenticPDFTests", dependencies: [
            .product(name: "AgenticPDF", package: "AgenticPDF"),
            .product(name: "Agentic", package: "Agentic"),
            .product(name: "Workspace", package: "Workspace"),
            .product(name: "Path", package: "Path"),
            .product(name: "IO", package: "IO"),
            .product(name: "PDFCore", package: "PDF")
        ])
    ],
    swiftLanguageModes: [.v6]
)

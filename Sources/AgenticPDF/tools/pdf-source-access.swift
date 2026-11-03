import Agentic
import AgenticIO
import Path
import PDFApple
import PDFCore

/// Only URLs returned by workspace authorization may reach the PDF reader.
enum PDFSourceAccess {
    static func preflight(
        rootID: PathAccessRootIdentifier?,
        path: String,
        context: ToolContext,
        definition: ToolDefinition,
        identifier: String
    ) throws -> ToolPreflight {
        let selectedRoot = rootID ?? context.workspace?.rootIdentifier ?? .project
        let authorized = try FileToolAccess.authorize(
            workspace: context.workspace,
            rootID: selectedRoot,
            path: path,
            capability: .read,
            toolName: identifier,
            type: .file
        )
        let sensitivity = FileReadSensitivity.assess(authorized)
        let summary = "Read PDF evidence from \(authorized.presentationPath)."
        let description = sensitivity.summaryReason.map {
            "\(summary) Sensitive path: \($0)"
        } ?? summary

        return .init(
            tool: definition.identifier,
            risk: sensitivity.risk,
            summary: description,
            access: .init(
                targets: [authorized.presentationPath],
                roots: [authorized.rootIdentifier.rawValue],
                capabilities: [.read]
            ),
            estimates: .init(read: .init(files: 1)),
            policyChecks: [
                "workspace_required",
                "workspace_path_authorized",
                "read_only_pdf",
                "path_sensitivity_profile:agentic_conservative"
            ] + sensitivity.policyChecks,
            warnings: sensitivity.warnings
        )
    }

    static func read(
        rootID: PathAccessRootIdentifier?,
        path: String,
        recognition: Bool,
        context: ToolContext,
        identifier: String
    ) throws -> PDFDocumentSnapshot {
        let selectedRoot = rootID ?? context.workspace?.rootIdentifier ?? .project
        let authorized = try FileToolAccess.authorize(
            workspace: context.workspace,
            rootID: selectedRoot,
            path: path,
            capability: .read,
            toolName: identifier,
            type: .file
        )
        return try PDFDocumentReader().read(
            authorized.absoluteURL,
            recognition: recognition ? .vision : .none
        )
    }
}

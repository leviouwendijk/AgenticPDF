import Agentic
import AgenticIO
import Macros
import Path
import PDFCore
import Schema

public extension PDF.Tools {
    @Tool("pdf_inspect_page")
    struct InspectPage: Tool {
        @JSONSchema
        public struct Input: HashableSource {
            @JSONSchema
            public enum Evidence: String, Sendable, Codable, Hashable {
                case native
                case recognition
                case both
            }

            @Schema(required: false)
            public let rootID: PathAccessRootIdentifier?
            public let path: String
            public let pageIndex: Int
            @Schema(required: false)
            public let recognition: Bool?
            @Schema(required: false)
            public let evidence: Evidence?
            @Schema(required: false)
            public let offset: Int?
            @Schema(required: false)
            public let limit: Int?
            public let expectedFingerprint: String?

            public init(
                rootID: PathAccessRootIdentifier? = nil,
                path: String,
                pageIndex: Int,
                recognition: Bool? = nil,
                evidence: Evidence? = nil,
                offset: Int? = nil,
                limit: Int? = nil,
                expectedFingerprint: String? = nil
            ) {
                self.rootID = rootID
                self.path = path
                self.pageIndex = pageIndex
                self.recognition = recognition
                self.evidence = evidence
                self.offset = offset
                self.limit = limit
                self.expectedFingerprint = expectedFingerprint
            }

        }

        @JSONSchema
        public struct Output: HashableResult {
            public let sourceFingerprint: String
            public let pageIndex: Int
            public let totalLines: Int
            public let lines: [PDFLineEvidence]
            public let nextOffset: Int?
        }

        public enum Failure: Error, Sendable {
            case invalid_page(Int)
            case invalid_pagination
            case source_mismatch
            case recognition_required
        }

        private static func checkInput(_ input: Input) throws {
            guard (input.offset ?? 0) >= 0,
                  (1...100).contains(input.limit ?? 50) else {
                throw Failure.invalid_pagination
            }
            if (input.evidence ?? .native) != .native, input.recognition != true {
                throw Failure.recognition_required
            }
        }

        public static let purpose = "Inspect bounded PDF lines with exact source-specific text references, OCR confidence and page geometry."
        public static let risk: ActionRisk = .observe
        public init() {}

        public func preflight(_ input: Input, in context: ToolContext) async throws -> ToolPreflight {
            try Self.checkInput(input)
            return try PDFSourceAccess.preflight(
                rootID: input.rootID,
                path: input.path,
                context: context,
                definition: Self.definition,
                identifier: Self.identifier.rawValue
            )
        }

        public func call(_ input: Input, in context: ToolContext) async throws -> Output {
            let offset = input.offset ?? 0
            let limit = input.limit ?? 50
            try Self.checkInput(input)
            let document = try PDFSourceAccess.read(
                rootID: input.rootID,
                path: input.path,
                recognition: input.recognition ?? false,
                context: context,
                identifier: Self.identifier.rawValue
            )
            let fingerprint = document.source.fingerprint.description
            if let expected = input.expectedFingerprint, expected != fingerprint {
                throw Failure.source_mismatch
            }
            guard document.page(at: input.pageIndex) != nil else {
                throw Failure.invalid_page(input.pageIndex)
            }

            let all = document.lines(onPage: input.pageIndex).filter { observation in
                switch input.evidence ?? .native {
                case .native:
                    return observation.origin == .native
                case .recognition:
                    return observation.origin == .recognition
                case .both:
                    return observation.origin == .native || observation.origin == .recognition
                }
            }
            let selected = all.dropFirst(offset).prefix(limit)
            let selectedRoot = input.rootID?.rawValue ?? context.workspace?.rootIdentifier.rawValue ?? "project"
            let lines = selected.map {
                PDFLineEvidence(
                    observation: $0,
                    rootID: selectedRoot,
                    path: input.path,
                    sourceFingerprint: fingerprint
                )
            }
            let next = offset < all.count && lines.count < all.count - offset
                ? offset + lines.count : nil
            return Output(
                sourceFingerprint: fingerprint,
                pageIndex: input.pageIndex,
                totalLines: all.count,
                lines: Array(lines),
                nextOffset: next
            )
        }
    }
}

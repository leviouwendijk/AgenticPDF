import Agentic
import AgenticIO
import Macros
import Path
import PDFCore
import Schema

public extension PDF.Tools {
    @Tool("pdf_read_document")
    struct ReadDocument: Tool {
        @JSONSchema
        public struct Input: HashableSource {
            @Schema(required: false)
            public let rootID: PathAccessRootIdentifier?
            public let path: String
            @Schema(required: false)
            public let recognition: Bool?
            @Schema(required: false)
            public let offset: Int?
            @Schema(required: false)
            public let limit: Int?
            public let expectedFingerprint: String?

            public init(
                rootID: PathAccessRootIdentifier? = nil,
                path: String,
                recognition: Bool? = nil,
                offset: Int? = nil,
                limit: Int? = nil,
                expectedFingerprint: String? = nil
            ) {
                self.rootID = rootID
                self.path = path
                self.recognition = recognition
                self.offset = offset
                self.limit = limit
                self.expectedFingerprint = expectedFingerprint
            }

        }

        @JSONSchema
        public struct Output: HashableResult {
            @JSONSchema
            public struct PageSummary: HashableResult {
                public let index: Int
                public let width: Double
                public let height: Double
                public let nativeLines: Int
                public let recognizedLines: Int
            }

            public let sourceFingerprint: String
            public let byteCount: Int
            public let pageCount: Int
            public let pages: [PageSummary]
            public let pagesTruncated: Bool
            public let nextOffset: Int?
        }

        public enum Failure: Error, Sendable {
            case invalid_pagination
            case source_mismatch
        }

        private static func checkPagination(_ input: Input) throws {
            guard (input.offset ?? 0) >= 0,
                  (1...64).contains(input.limit ?? 32) else {
                throw Failure.invalid_pagination
            }
        }

        public static let purpose = "Inspect an authorized PDF and return bounded page metadata and extraction counts. OCR is opt-in."
        public static let risk: ActionRisk = .observe
        public init() {}

        public func preflight(_ input: Input, in context: ToolContext) async throws -> ToolPreflight {
            try Self.checkPagination(input)
            return try PDFSourceAccess.preflight(
                rootID: input.rootID,
                path: input.path,
                context: context,
                definition: Self.definition,
                identifier: Self.identifier.rawValue
            )
        }

        public func call(_ input: Input, in context: ToolContext) async throws -> Output {
            try Self.checkPagination(input)
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
            let offset = input.offset ?? 0
            let pages = document.pages.dropFirst(offset).prefix(input.limit ?? 32)
            let summaries = pages.map { page in
                let lines = document.lines(onPage: page.index)
                return Output.PageSummary(
                    index: page.index,
                    width: page.bounds.width,
                    height: page.bounds.height,
                    nativeLines: lines.filter { $0.origin == .native }.count,
                    recognizedLines: lines.filter { $0.origin == .recognition }.count
                )
            }
            let nextOffset = offset + summaries.count < document.pages.count
                ? offset + summaries.count : nil
            return Output(
                sourceFingerprint: fingerprint,
                byteCount: document.source.byteCount,
                pageCount: document.pages.count,
                pages: Array(summaries),
                pagesTruncated: nextOffset != nil,
                nextOffset: nextOffset
            )
        }
    }
}

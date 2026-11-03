import Foundation
import Agentic
import AgenticIO
import Macros
import Path
import PDFCore
import Schema

public extension PDF.Tools {
    @Tool("pdf_read_text")
    struct ReadText: Tool {
        @JSONSchema
        public struct Input: HashableSource {
            @JSONSchema
            public enum Source: String, Sendable, Codable, Hashable {
                case native
                case recognition
            }

            @Schema(required: false)
            public let rootID: PathAccessRootIdentifier?
            public let path: String
            public let pageIndex: Int
            @Schema(required: false)
            public let source: Source?
            @Schema(required: false)
            public let recognition: Bool?
            @Schema(required: false)
            public let offsetUTF16: Int?
            @Schema(required: false)
            public let maxUTF16: Int?
            public let expectedFingerprint: String?

            public init(
                rootID: PathAccessRootIdentifier? = nil,
                path: String,
                pageIndex: Int,
                source: Source? = nil,
                recognition: Bool? = nil,
                offsetUTF16: Int? = nil,
                maxUTF16: Int? = nil,
                expectedFingerprint: String? = nil
            ) {
                self.rootID = rootID
                self.path = path
                self.pageIndex = pageIndex
                self.source = source
                self.recognition = recognition
                self.offsetUTF16 = offsetUTF16
                self.maxUTF16 = maxUTF16
                self.expectedFingerprint = expectedFingerprint
            }
        }

        @JSONSchema
        public struct Output: HashableResult {
            public let source: String
            public let text: String
            public let reference: PDFEvidenceReference
            public let totalUTF16: Int
            public let nextOffsetUTF16: Int?
        }

        public enum Failure: Error, Sendable {
            case invalid_page(Int)
            case invalid_range
            case missing_snapshot(String)
            case source_mismatch
            case recognition_required
        }

        public static let purpose = "Read a bounded range from an exact PDF page text snapshot, retaining source identity and UTF-16 offsets."
        public static let risk: ActionRisk = .observe
        public init() {}

        private static func checkInput(_ input: Input) throws {
            guard input.pageIndex >= 0,
                  (input.offsetUTF16 ?? 0) >= 0,
                  (2...4096).contains(input.maxUTF16 ?? 2048) else {
                throw Failure.invalid_range
            }
            if input.source == .recognition && input.recognition != true {
                throw Failure.recognition_required
            }
        }

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
            guard let page = document.page(at: input.pageIndex) else {
                throw Failure.invalid_page(input.pageIndex)
            }

            let source = input.source ?? .native
            let snapshotID: String
            switch source {
            case .native:
                snapshotID = "native"
            case .recognition:
                snapshotID = "vision"
            }
            guard let snapshot = page.textSnapshots.first(where: { $0.id == snapshotID }) else {
                throw Failure.missing_snapshot(snapshotID)
            }

            let offset = input.offsetUTF16 ?? 0
            guard offset <= snapshot.utf16Count else {
                throw Failure.invalid_range
            }
            var end = min(snapshot.utf16Count, offset + (input.maxUTF16 ?? 2048))
            var resolved: String?

            // Never split a UTF-16 surrogate pair. Every returned range must
            // be resolvable by PDFCore against the exact text snapshot.
            while end >= offset {
                let reference = try PDFTextReference(
                    pageIndex: page.index,
                    snapshotID: snapshot.id,
                    snapshotFingerprint: snapshot.fingerprint,
                    start: .init(offset),
                    end: .init(end)
                )
                if let text = try? document.resolve(reference) {
                    resolved = text
                    break
                }
                if end == offset { break }
                end -= 1
            }
            guard let text = resolved,
                  end > offset || offset == snapshot.utf16Count else {
                throw Failure.invalid_range
            }

            let evidence = PDFEvidenceReference(
                rootID: input.rootID?.rawValue ?? context.workspace?.rootIdentifier.rawValue ?? "project",
                path: input.path,
                sourceFingerprint: fingerprint,
                pageIndex: page.index,
                snapshotID: snapshot.id,
                snapshotFingerprint: snapshot.fingerprint.description,
                startUTF16: offset,
                endUTF16: end
            )
            return Output(
                source: source.rawValue,
                text: text,
                reference: evidence,
                totalUTF16: snapshot.utf16Count,
                nextOffsetUTF16: end < snapshot.utf16Count ? end : nil
            )
        }
    }
}

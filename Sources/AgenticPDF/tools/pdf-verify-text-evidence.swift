import Agentic
import AgenticIO
import Macros
import Path
import PDFCore
import Schema

public extension PDF.Tools {
    /// Resolves purported PDF line quotations against the currently authorized source.
    @Tool("pdf_verify_text_evidence")
    struct VerifyTextEvidence: Tool {
        @JSONSchema
        public struct Input: HashableSource {
            @JSONSchema
            public struct Claim: HashableSource {
                public let lineID: String
                public let lineReference: PDFEvidenceReference
                public let quote: String
                public let startUTF16: Int
                public let endUTF16: Int

                public init(
                    lineID: String,
                    lineReference: PDFEvidenceReference,
                    quote: String,
                    startUTF16: Int,
                    endUTF16: Int
                ) {
                    self.lineID = lineID
                    self.lineReference = lineReference
                    self.quote = quote
                    self.startUTF16 = startUTF16
                    self.endUTF16 = endUTF16
                }
            }

            @Schema(required: false)
            public let rootID: PathAccessRootIdentifier?
            public let path: String
            public let expectedFingerprint: String
            @Schema(required: false)
            public let recognition: Bool?
            public let claims: [Claim]

            public init(
                rootID: PathAccessRootIdentifier? = nil,
                path: String,
                expectedFingerprint: String,
                recognition: Bool? = nil,
                claims: [Claim]
            ) {
                self.rootID = rootID
                self.path = path
                self.expectedFingerprint = expectedFingerprint
                self.recognition = recognition
                self.claims = claims
            }
        }

        @JSONSchema
        public struct Output: HashableResult {
            public let sourceFingerprint: String
            /// Only includes claims whose line identity and exact quote were checked.
            public let verified: [Input.Claim]
        }

        public enum Failure: Error, Sendable {
            case empty_claims
            case too_many_claims(Int)
            case invalid_claim(String)
            case mixed_source(String)
            case recognition_required
            case source_mismatch
            case missing_line(String)
            case stale_line(String)
            case invalid_quote_span(String)
            case quote_mismatch(String)
        }

        public static let purpose = "Resolve source-bound PDF line quotations against the current authorized PDF bytes and exact text snapshots; reject stale, invented, or mismatched evidence."
        public static let risk: ActionRisk = .observe
        public init() {}

        private static func checkInput(_ input: Input, in context: ToolContext) throws {
            guard !input.claims.isEmpty else { throw Failure.empty_claims }
            guard input.claims.count <= 128 else {
                throw Failure.too_many_claims(input.claims.count)
            }
            let root = (input.rootID ?? context.workspace?.rootIdentifier ?? .project).rawValue
            for claim in input.claims {
                let reference = claim.lineReference
                guard !claim.lineID.isEmpty, !claim.quote.isEmpty,
                      reference.pageIndex >= 0, reference.startUTF16 >= 0,
                      reference.endUTF16 > reference.startUTF16 else {
                    throw Failure.invalid_claim(claim.lineID)
                }
                guard reference.rootID == root,
                      reference.path == input.path,
                      reference.sourceFingerprint == input.expectedFingerprint else {
                    throw Failure.mixed_source(claim.lineID)
                }
                guard claim.startUTF16 >= reference.startUTF16,
                      claim.endUTF16 <= reference.endUTF16,
                      claim.endUTF16 > claim.startUTF16,
                      claim.endUTF16 - claim.startUTF16 == claim.quote.utf16.count else {
                    throw Failure.invalid_quote_span(claim.lineID)
                }
                if reference.snapshotID == "vision" && input.recognition != true {
                    throw Failure.recognition_required
                }
            }
        }

        public func preflight(_ input: Input, in context: ToolContext) async throws -> ToolPreflight {
            try Self.checkInput(input, in: context)
            return try PDFSourceAccess.preflight(
                rootID: input.rootID,
                path: input.path,
                context: context,
                definition: Self.definition,
                identifier: Self.identifier.rawValue
            )
        }

        public func call(_ input: Input, in context: ToolContext) async throws -> Output {
            try Self.checkInput(input, in: context)
            let document = try PDFSourceAccess.read(
                rootID: input.rootID,
                path: input.path,
                recognition: input.recognition ?? false,
                context: context,
                identifier: Self.identifier.rawValue
            )
            let fingerprint = document.source.fingerprint.description
            guard fingerprint == input.expectedFingerprint else {
                throw Failure.source_mismatch
            }

            for claim in input.claims {
                let expected = claim.lineReference
                guard let line = document.lines(onPage: expected.pageIndex).first(where: {
                    $0.id == claim.lineID
                }) else {
                    throw Failure.missing_line(claim.lineID)
                }
                guard let anchor = line.textReferences.first(where: {
                    $0.pageIndex == expected.pageIndex &&
                    $0.snapshotID == expected.snapshotID &&
                    $0.snapshotFingerprint.description == expected.snapshotFingerprint &&
                    $0.start.offset == expected.startUTF16 &&
                    $0.end.offset == expected.endUTF16
                }),
                let fullText = try? document.resolve(anchor),
                fullText == line.text else {
                    throw Failure.stale_line(claim.lineID)
                }

                let quoteReference = try PDFTextReference(
                    pageIndex: anchor.pageIndex,
                    snapshotID: anchor.snapshotID,
                    snapshotFingerprint: anchor.snapshotFingerprint,
                    start: .init(claim.startUTF16),
                    end: .init(claim.endUTF16)
                )
                guard let actual = try? document.resolve(quoteReference),
                      actual == claim.quote else {
                    throw Failure.quote_mismatch(claim.lineID)
                }
            }
            return Output(sourceFingerprint: fingerprint, verified: input.claims)
        }
    }
}

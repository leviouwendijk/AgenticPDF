import Agentic
import AgenticIO
import Macros
import Path
import PDFCore
import Schema

public extension PDF.Tools {
    @Tool("pdf_inspect_region")
    struct InspectRegion: Tool {
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
            public let x: Double
            public let y: Double
            public let width: Double
            public let height: Double
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
                x: Double,
                y: Double,
                width: Double,
                height: Double,
                recognition: Bool? = nil,
                evidence: Evidence? = nil,
                offset: Int? = nil,
                limit: Int? = nil,
                expectedFingerprint: String? = nil
            ) {
                self.rootID = rootID
                self.path = path
                self.pageIndex = pageIndex
                self.x = x
                self.y = y
                self.width = width
                self.height = height
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
            public let region: PDFLineEvidence.Region
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

        public static let purpose = "Inspect complete PDF lines whose page geometry intersects a bounded rectangle, preserving text evidence references and OCR provenance. Coordinates use PDF page space."
        public static let risk: ActionRisk = .observe
        public init() {}

        private static func queryRegion(_ input: Input) throws -> PDFPageRegion {
            guard input.pageIndex >= 0 else {
                throw Failure.invalid_page(input.pageIndex)
            }
            guard (input.offset ?? 0) >= 0,
                  (1...100).contains(input.limit ?? 50) else {
                throw Failure.invalid_pagination
            }
            if (input.evidence ?? .native) != .native && input.recognition != true {
                throw Failure.recognition_required
            }
            return try PDFPageRegion(
                pageIndex: input.pageIndex,
                rectangle: PDFRectangle(
                    x: input.x,
                    y: input.y,
                    width: input.width,
                    height: input.height
                )
            )
        }

        public func preflight(_ input: Input, in context: ToolContext) async throws -> ToolPreflight {
            _ = try Self.queryRegion(input)
            return try PDFSourceAccess.preflight(
                rootID: input.rootID,
                path: input.path,
                context: context,
                definition: Self.definition,
                identifier: Self.identifier.rawValue
            )
        }

        public func call(_ input: Input, in context: ToolContext) async throws -> Output {
            let region = try Self.queryRegion(input)
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

            let all = document.lines(overlapping: region).filter { observation in
                switch input.evidence ?? .native {
                case .native:
                    return observation.origin == .native
                case .recognition:
                    return observation.origin == .recognition
                case .both:
                    return observation.origin == .native || observation.origin == .recognition
                }
            }
            let offset = input.offset ?? 0
            let selectedRoot = input.rootID?.rawValue ?? context.workspace?.rootIdentifier.rawValue ?? "project"
            let lines = all.dropFirst(offset).prefix(input.limit ?? 50).map {
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
                region: .init(x: region.rectangle.x, y: region.rectangle.y,
                              width: region.rectangle.width, height: region.rectangle.height),
                totalLines: all.count,
                lines: Array(lines),
                nextOffset: next
            )
        }
    }
}

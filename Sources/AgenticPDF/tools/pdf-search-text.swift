import Foundation
import Agentic
import AgenticIO
import Macros
import Path
import PDFCore
import Schema

public extension PDF.Tools {
    @Tool("pdf_search_text")
    struct SearchText: Tool {
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
            public let query: String
            @Schema(required: false)
            public let pageIndex: Int?
            @Schema(required: false)
            public let source: Source?
            @Schema(required: false)
            public let recognition: Bool?
            @Schema(required: false)
            public let caseSensitive: Bool?
            @Schema(required: false)
            public let offset: Int?
            @Schema(required: false)
            public let limit: Int?
            public let expectedFingerprint: String?

            public init(
                rootID: PathAccessRootIdentifier? = nil,
                path: String,
                query: String,
                pageIndex: Int? = nil,
                source: Source? = nil,
                recognition: Bool? = nil,
                caseSensitive: Bool? = nil,
                offset: Int? = nil,
                limit: Int? = nil,
                expectedFingerprint: String? = nil
            ) {
                self.rootID = rootID
                self.path = path
                self.query = query
                self.pageIndex = pageIndex
                self.source = source
                self.recognition = recognition
                self.caseSensitive = caseSensitive
                self.offset = offset
                self.limit = limit
                self.expectedFingerprint = expectedFingerprint
            }
        }

        @JSONSchema
        public struct Output: HashableResult {
            @JSONSchema
            public struct Match: HashableResult {
                public let text: String
                public let reference: PDFEvidenceReference
            }

            public let sourceFingerprint: String
            public let totalMatches: Int
            public let matches: [Match]
            public let nextOffset: Int?
        }

        public enum Failure: Error, Sendable {
            case invalid_query
            case invalid_pagination
            case invalid_page(Int)
            case recognition_required
            case source_mismatch
        }

        public static let purpose = "Search exact PDF text snapshots and return bounded, source-specific matches with resolvable UTF-16 evidence references."
        public static let risk: ActionRisk = .observe
        public init() {}

        private static func checkInput(_ input: Input) throws {
            guard !input.query.isEmpty, input.query.utf8.count <= 256 else {
                throw Failure.invalid_query
            }
            guard (input.offset ?? 0) >= 0,
                  (1...50).contains(input.limit ?? 20) else {
                throw Failure.invalid_pagination
            }
            if let index = input.pageIndex, index < 0 {
                throw Failure.invalid_page(index)
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

            let pages: [PDFPageRecord]
            if let index = input.pageIndex {
                guard let page = document.page(at: index) else {
                    throw Failure.invalid_page(index)
                }
                pages = [page]
            } else {
                pages = document.pages
            }

            let snapshotID = (input.source ?? .native) == .native ? "native" : "vision"
            let options: NSString.CompareOptions = (input.caseSensitive ?? false) ? [] : [.caseInsensitive]
            let offset = input.offset ?? 0
            let limit = input.limit ?? 20
            let selectedRoot = input.rootID?.rawValue ?? context.workspace?.rootIdentifier.rawValue ?? "project"
            var totalMatches = 0
            var matches: [Output.Match] = []

            for page in pages {
                guard let snapshot = page.textSnapshots.first(where: { $0.id == snapshotID }) else {
                    continue
                }
                let string = snapshot.text as NSString
                var position = 0
                while position < string.length {
                    let range = NSRange(location: position, length: string.length - position)
                    let found = string.range(of: input.query, options: options, range: range)
                    guard found.location != NSNotFound else { break }
                    let end = found.location + found.length
                    if totalMatches >= offset && matches.count < limit {
                        let reference = try PDFTextReference(
                            pageIndex: page.index,
                            snapshotID: snapshot.id,
                            snapshotFingerprint: snapshot.fingerprint,
                            start: .init(found.location),
                            end: .init(end)
                        )
                        let text = try document.resolve(reference)
                        let evidence = PDFEvidenceReference(
                            rootID: selectedRoot,
                            path: input.path,
                            sourceFingerprint: fingerprint,
                            pageIndex: page.index,
                            snapshotID: snapshot.id,
                            snapshotFingerprint: snapshot.fingerprint.description,
                            startUTF16: found.location,
                            endUTF16: end
                        )
                        matches.append(Output.Match(text: text, reference: evidence))
                    }
                    totalMatches += 1
                    position = end
                }
            }

            let next = offset + matches.count < totalMatches ? offset + matches.count : nil
            return Output(
                sourceFingerprint: fingerprint,
                totalMatches: totalMatches,
                matches: matches,
                nextOffset: next
            )
        }
    }
}

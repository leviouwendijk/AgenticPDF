import Agentic
import Macros
import PDFCore
import Schema

/// Complete line evidence, projected from the canonical PDFCore observation.
/// Result count is paginated by the requesting tool; line text is never clipped.
@JSONSchema
public struct PDFLineEvidence: HashableResult {
    @JSONSchema
    public struct Region: HashableResult {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
    }

    public let id: String
    public let text: String?
    public let origin: String
    public let confidence: Double?
    public let snapshotID: String?
    public let snapshotFingerprint: String?
    public let startUTF16: Int?
    public let endUTF16: Int?
    public let reference: PDFEvidenceReference?
    public let region: Region?
}

public extension PDFLineEvidence {
    /// Preserves complete text. The reference, when present, describes that
    /// complete text range, not a shortened excerpt.
    init(
        observation: PDFLineObservation,
        rootID: String,
        path: String,
        sourceFingerprint: String
    ) {
        let reference = observation.textReferences.first
        let rectangle = observation.regions.first?.rectangle
        let region = rectangle.map {
            Region(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        }
        self.init(
            id: observation.id,
            text: observation.text,
            origin: observation.origin.rawValue,
            confidence: observation.confidence,
            snapshotID: reference?.snapshotID,
            snapshotFingerprint: reference?.snapshotFingerprint.description,
            startUTF16: reference?.start.offset,
            endUTF16: reference?.end.offset,
            reference: reference.map { anchor in
                PDFEvidenceReference(
                    rootID: rootID,
                    path: path,
                    sourceFingerprint: sourceFingerprint,
                    pageIndex: anchor.pageIndex,
                    snapshotID: anchor.snapshotID,
                    snapshotFingerprint: anchor.snapshotFingerprint.description,
                    startUTF16: anchor.start.offset,
                    endUTF16: anchor.end.offset
                )
            },
            region: region
        )
    }
}

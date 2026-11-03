import Agentic
import Macros
import Schema

/// Identifies evidence within one exact PDF source and text snapshot version.
/// A reference is a claim of identity, not proof of authenticity; consumers
/// must resolve it against an authorized document before trusting its text.
@JSONSchema
public struct PDFEvidenceReference: HashableResult {
    public let rootID: String
    public let path: String
    public let sourceFingerprint: String
    public let pageIndex: Int
    public let snapshotID: String
    public let snapshotFingerprint: String
    public let startUTF16: Int
    public let endUTF16: Int
}

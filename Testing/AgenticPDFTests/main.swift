import Agentic
import AgenticPDF
import CoreGraphics
import CoreText
import Foundation
import Path
import PDFCore
import Workspace

private enum Failure: Error { case assertion(String) }

@main
struct AgenticPDFTests {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agentic-pdf-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("synthetic.pdf")
        try makePDF().write(to: path)
        try makePDF(pageCount: 35).write(to: directory.appendingPathComponent("many-pages.pdf"))

        let read = PDF.Tools.ReadDocument()
        let page = PDF.Tools.InspectPage()
        let text = PDF.Tools.ReadText()
        let search = PDF.Tools.SearchText()
        let region = PDF.Tools.InspectRegion()
        guard PDF.Tools.ReadDocument.definition.identifier.rawValue == "pdf_read_document",
              PDF.Tools.InspectPage.definition.identifier.rawValue == "pdf_inspect_page" else {
            throw Failure.assertion("tool identifiers")
        }
        let context = try fixtureContext(root: directory, capabilities: [.read])
        let input = PDF.Tools.ReadDocument.Input(path: "synthetic.pdf")
        let decodedRead = try JSONDecoder().decode(
            PDF.Tools.ReadDocument.Input.self,
            from: Data(#"{"path":"synthetic.pdf"}"#.utf8)
        )
        guard decodedRead.rootID == nil, decodedRead.recognition == nil else {
            throw Failure.assertion("omitted document options")
        }
        let decodedPage = try JSONDecoder().decode(
            PDF.Tools.InspectPage.Input.self,
            from: Data(#"{"path":"synthetic.pdf","pageIndex":0}"#.utf8)
        )
        guard decodedPage.rootID == nil, decodedPage.recognition == nil,
              decodedPage.offset == nil, decodedPage.limit == nil else {
            throw Failure.assertion("omitted page options")
        }
        let preflight = try await read.preflight(input, in: context)
        let alternate = try fixtureContext(
            root: directory,
            capabilities: [.read],
            rootID: PathAccessRootIdentifier(rawValue: "pdf_fixture")
        )
        let alternateRead = try await read.call(decodedRead, in: alternate)
        guard alternateRead.pageCount == 1 else {
            throw Failure.assertion("selected workspace root")
        }
        guard preflight.risk == .observe else { throw Failure.assertion("tool risk") }
        let summary = try await read.call(decodedRead, in: context)
        guard summary.pageCount == 1, summary.pages.count == 1,
              summary.pages[0].nativeLines > 0 else { throw Failure.assertion("native PDF") }
        guard PDF.Tools.ReadText.definition.identifier.rawValue == "pdf_read_text" else {
            throw Failure.assertion("read text tool identifier")
        }
        let textPreflight = try await text.preflight(.init(
            path: "synthetic.pdf", pageIndex: 0
        ), in: context)
        guard textPreflight.risk == .observe else {
            throw Failure.assertion("read text risk")
        }
        let textPart = try await text.call(.init(
            path: "synthetic.pdf", pageIndex: 0,
            maxUTF16: 8, expectedFingerprint: summary.sourceFingerprint
        ), in: context)
        guard !textPart.text.isEmpty,
              textPart.reference.snapshotID == "native",
              textPart.reference.sourceFingerprint == summary.sourceFingerprint,
              textPart.reference.startUTF16 == 0,
              textPart.reference.endUTF16 > 0,
              textPart.reference.endUTF16 <= 8,
              textPart.nextOffsetUTF16 != nil else {
            throw Failure.assertion("bounded native text evidence")
        }
        if let next = textPart.nextOffsetUTF16 {
            let continuation = try await text.call(.init(
                path: "synthetic.pdf", pageIndex: 0,
                offsetUTF16: next, maxUTF16: 8,
                expectedFingerprint: summary.sourceFingerprint
            ), in: context)
            guard continuation.reference.startUTF16 == next,
                  continuation.reference.snapshotFingerprint == textPart.reference.snapshotFingerprint,
                  !continuation.text.isEmpty else {
                throw Failure.assertion("text continuation")
            }
        }
        var rejectedTextSource = false
        do {
            _ = try await text.call(.init(
                path: "synthetic.pdf", pageIndex: 0,
                expectedFingerprint: "stale"
            ), in: context)
        } catch PDF.Tools.ReadText.Failure.source_mismatch {
            rejectedTextSource = true
        }
        guard rejectedTextSource else {
            throw Failure.assertion("text source fingerprint")
        }
        var rejectedTextRecognition = false
        do {
            _ = try await text.preflight(.init(
                path: "synthetic.pdf", pageIndex: 0,
                source: .recognition
            ), in: context)
        } catch PDF.Tools.ReadText.Failure.recognition_required {
            rejectedTextRecognition = true
        }
        guard rejectedTextRecognition else {
            throw Failure.assertion("read text OCR preflight")
        }

        guard PDF.Tools.SearchText.definition.identifier.rawValue == "pdf_search_text" else {
            throw Failure.assertion("search tool identifier")
        }
        let searchPreflight = try await search.preflight(.init(
            path: "synthetic.pdf", query: "DOCUMENT"
        ), in: context)
        guard searchPreflight.risk == .observe else {
            throw Failure.assertion("search risk")
        }
        let found = try await search.call(.init(
            path: "synthetic.pdf", query: "DOCUMENT",
            expectedFingerprint: summary.sourceFingerprint
        ), in: context)
        guard found.totalMatches == 1, found.matches.count == 1,
              found.matches[0].text == "DOCUMENT",
              found.matches[0].reference.snapshotID == "native",
              found.matches[0].reference.sourceFingerprint == summary.sourceFingerprint,
              found.matches[0].reference.pageIndex == 0,
              found.matches[0].reference.endUTF16 - found.matches[0].reference.startUTF16 == 8 else {
            throw Failure.assertion("native search evidence")
        }
        let searchBatch = try await search.call(.init(
            path: "many-pages.pdf", query: "synthetic", limit: 4
        ), in: context)
        guard searchBatch.totalMatches == 35, searchBatch.matches.count == 4,
              searchBatch.matches.first?.reference.pageIndex == 0,
              searchBatch.nextOffset == 4 else {
            throw Failure.assertion("document-wide search pagination")
        }
        let nextSearchBatch = try await search.call(.init(
            path: "many-pages.pdf", query: "synthetic", offset: 4, limit: 4,
            expectedFingerprint: searchBatch.sourceFingerprint
        ), in: context)
        guard nextSearchBatch.matches.first?.reference.pageIndex == 4,
              nextSearchBatch.nextOffset == 8 else {
            throw Failure.assertion("search pagination continuation")
        }
        let absent = try await search.call(.init(
            path: "synthetic.pdf", query: "NOT PRESENT"
        ), in: context)
        guard absent.totalMatches == 0, absent.matches.isEmpty,
              absent.nextOffset == nil else {
            throw Failure.assertion("missing search results")
        }
        var rejectedSearchRecognition = false
        do {
            _ = try await search.preflight(.init(
                path: "synthetic.pdf", query: "DOCUMENT", source: .recognition
            ), in: context)
        } catch PDF.Tools.SearchText.Failure.recognition_required {
            rejectedSearchRecognition = true
        }
        guard rejectedSearchRecognition else {
            throw Failure.assertion("search recognition preflight")
        }

        let firstPageBatch = try await read.call(.init(
            path: "many-pages.pdf", limit: 32
        ), in: context)
        guard firstPageBatch.pageCount == 35, firstPageBatch.pages.count == 32,
              firstPageBatch.pagesTruncated, firstPageBatch.nextOffset == 32 else {
            throw Failure.assertion("document pagination first batch")
        }
        let secondPageBatch = try await read.call(.init(
            path: "many-pages.pdf", offset: 32, limit: 32,
            expectedFingerprint: firstPageBatch.sourceFingerprint
        ), in: context)
        guard secondPageBatch.pages.count == 3, secondPageBatch.pages.first?.index == 32,
              secondPageBatch.nextOffset == nil, !secondPageBatch.pagesTruncated else {
            throw Failure.assertion("document pagination second batch")
        }

        let defaultPage = try await page.call(decodedPage, in: context)
        guard defaultPage.totalLines > 0 else {
            throw Failure.assertion("page defaults")
        }
        let inspected = try await page.call(.init(
            path: "synthetic.pdf", pageIndex: 0, limit: 1, expectedFingerprint: summary.sourceFingerprint
        ), in: context)
        guard inspected.totalLines > 0, inspected.lines.count == 1,
              inspected.lines[0].origin == "native",
              inspected.lines[0].snapshotID == "native",
              inspected.lines[0].startUTF16 != nil,
              inspected.lines[0].region != nil,
              inspected.lines[0].reference?.snapshotID == "native",
              inspected.lines[0].reference?.sourceFingerprint == summary.sourceFingerprint else {
            throw Failure.assertion("anchored native line")
        }
        let anchored = inspected.lines[0]
        guard let nativeReference = anchored.reference,
              let nativeText = anchored.text else {
            throw Failure.assertion("native line text and reference")
        }
        let nativeLength = nativeReference.endUTF16 - nativeReference.startUTF16
        guard (2...4096).contains(nativeLength) else {
            throw Failure.assertion("native fixture reference range")
        }
        let resolvedLine = try await text.call(.init(
            path: "synthetic.pdf",
            pageIndex: nativeReference.pageIndex,
            source: .native,
            offsetUTF16: nativeReference.startUTF16,
            maxUTF16: nativeLength,
            expectedFingerprint: nativeReference.sourceFingerprint
        ), in: context)
        guard resolvedLine.text == nativeText,
              resolvedLine.reference.startUTF16 == nativeReference.startUTF16,
              resolvedLine.reference.endUTF16 == nativeReference.endUTF16,
              resolvedLine.reference.snapshotFingerprint == nativeReference.snapshotFingerprint else {
            throw Failure.assertion("line text equals full source-bound range")
        }
        if let next = inspected.nextOffset {
            let continued = try await page.call(.init(path: "synthetic.pdf", pageIndex: 0, offset: next), in: context)
            guard continued.lines.first?.id != inspected.lines.first?.id else {
                throw Failure.assertion("pagination")
            }
        }
        let recognized = try await read.call(.init(path: "synthetic.pdf", recognition: true), in: context)
        let nativeFromIntegrated = try await page.call(.init(
            path: "synthetic.pdf", pageIndex: 0, recognition: true, evidence: .native
        ), in: context)
        guard nativeFromIntegrated.totalLines == inspected.totalLines,
              nativeFromIntegrated.lines.allSatisfy({ $0.origin == "native" }) else {
            throw Failure.assertion("native evidence filtering")
        }
        let both = try await page.call(.init(
            path: "synthetic.pdf", pageIndex: 0, recognition: true, evidence: .both
        ), in: context)
        guard both.totalLines >= nativeFromIntegrated.totalLines else {
            throw Failure.assertion("combined evidence filtering")
        }
        var rejectedRecognition = false
        do {
            _ = try await page.preflight(.init(
                path: "synthetic.pdf", pageIndex: 0, evidence: .recognition
            ), in: context)
        } catch PDF.Tools.InspectPage.Failure.recognition_required {
            rejectedRecognition = true
        }
        guard rejectedRecognition else {
            throw Failure.assertion("recognition required for OCR evidence")
        }
        guard recognized.sourceFingerprint == summary.sourceFingerprint,
              recognized.pageCount == summary.pageCount else { throw Failure.assertion("OCR source") }

        var rejectedSummaryMismatch = false
        do {
            _ = try await read.call(.init(
                path: "synthetic.pdf", expectedFingerprint: "invalid"
            ), in: context)
        } catch PDF.Tools.ReadDocument.Failure.source_mismatch {
            rejectedSummaryMismatch = true
        }
        guard rejectedSummaryMismatch else {
            throw Failure.assertion("summary fingerprint mismatch")
        }

        var rejectedMismatch = false
        do {
            _ = try await page.call(.init(path: "synthetic.pdf", pageIndex: 0, expectedFingerprint: "invalid"), in: context)
        } catch PDF.Tools.InspectPage.Failure.source_mismatch { rejectedMismatch = true }
        guard rejectedMismatch else { throw Failure.assertion("fingerprint mismatch") }

        var denied = false
        do {
            let scanOnly = try fixtureContext(root: directory, capabilities: [.scan])
            _ = try await read.call(input, in: scanOnly)
        } catch { denied = true }
        guard denied else { throw Failure.assertion("read grant required") }

        guard PDF.Tools.InspectRegion.definition.identifier.rawValue == "pdf_inspect_region" else {
            throw Failure.assertion("region tool identifier")
        }
        let regionPreflight = try await region.preflight(.init(
            path: "synthetic.pdf", pageIndex: 0,
            x: 0, y: 0, width: 612, height: 792
        ), in: context)
        guard regionPreflight.risk == .observe else {
            throw Failure.assertion("region risk")
        }
        let fullRegion = try await region.call(.init(
            path: "synthetic.pdf", pageIndex: 0,
            x: 0, y: 0, width: 612, height: 792,
            expectedFingerprint: summary.sourceFingerprint
        ), in: context)
        guard fullRegion.totalLines == inspected.totalLines,
              fullRegion.lines.count == inspected.totalLines,
              fullRegion.lines.first?.reference == inspected.lines.first?.reference,
              fullRegion.region.width == 612 else {
            throw Failure.assertion("whole-page geometry and line evidence")
        }
        let emptyRegion = try await region.call(.init(
            path: "synthetic.pdf", pageIndex: 0,
            x: 0, y: 0, width: 10, height: 10
        ), in: context)
        guard emptyRegion.totalLines == 0, emptyRegion.lines.isEmpty,
              emptyRegion.nextOffset == nil else {
            throw Failure.assertion("nonoverlapping region")
        }
        let bothRegion = try await region.call(.init(
            path: "synthetic.pdf", pageIndex: 0,
            x: 0, y: 0, width: 612, height: 792,
            recognition: true, evidence: .both
        ), in: context)
        guard bothRegion.totalLines >= fullRegion.totalLines else {
            throw Failure.assertion("combined region evidence")
        }
        var rejectedRegionRecognition = false
        do {
            _ = try await region.preflight(.init(
                path: "synthetic.pdf", pageIndex: 0,
                x: 0, y: 0, width: 612, height: 792,
                evidence: .recognition
            ), in: context)
        } catch PDF.Tools.InspectRegion.Failure.recognition_required {
            rejectedRegionRecognition = true
        }
        guard rejectedRegionRecognition else {
            throw Failure.assertion("region OCR preflight")
        }
        var rejectedRegionGeometry = false
        do {
            _ = try await region.preflight(.init(
                path: "synthetic.pdf", pageIndex: 0,
                x: 0, y: 0, width: 0, height: 792
            ), in: context)
        } catch {
            rejectedRegionGeometry = true
        }
        guard rejectedRegionGeometry else {
            throw Failure.assertion("invalid region geometry")
        }
        var rejectedRegionFingerprint = false
        do {
            _ = try await region.call(.init(
                path: "synthetic.pdf", pageIndex: 0,
                x: 0, y: 0, width: 612, height: 792,
                expectedFingerprint: "stale"
            ), in: context)
        } catch PDF.Tools.InspectRegion.Failure.source_mismatch {
            rejectedRegionFingerprint = true
        }
        guard rejectedRegionFingerprint else {
            throw Failure.assertion("region fingerprint mismatch")
        }

        try testCompleteLineEvidence()

        print("t_agentic_pdf: passed")
    }

    private static func testCompleteLineEvidence() throws {
        let fullText = String(repeating: "invoice_number=2026-123; amount=1234.50; ", count: 180)
        guard fullText.utf8.count > 4096 else {
            throw Failure.assertion("long-line fixture")
        }
        let node = PDFStructureGraph.Node(
            id: "synthetic-long-line",
            value: try PDFElement(kind: .line, text: fullText, origin: .native, anchors: [])
        )
        guard let observation = PDFLineObservation(node: node) else {
            throw Failure.assertion("canonical line projection")
        }
        let projected = PDFLineEvidence(
            observation: observation,
            rootID: "project",
            path: "long-line.pdf",
            sourceFingerprint: "fixture"
        )
        guard projected.text == fullText,
              projected.text?.utf8.count == fullText.utf8.count,
              projected.reference == nil else {
            throw Failure.assertion("complete line preserved beyond former 4096-byte cap")
        }
        let serialized = try JSONEncoder().encode(projected)
        let decoded = try JSONDecoder().decode(PDFLineEvidence.self, from: serialized)
        guard decoded == projected else {
            throw Failure.assertion("line evidence JSON roundtrip")
        }

        let emptyNode = PDFStructureGraph.Node(
            id: "synthetic-unreadable-line",
            value: try PDFElement(kind: .line, origin: .native, anchors: [])
        )
        guard let emptyObservation = PDFLineObservation(node: emptyNode) else {
            throw Failure.assertion("empty line observation")
        }
        let emptyEvidence = PDFLineEvidence(
            observation: emptyObservation,
            rootID: "project",
            path: "empty-line.pdf",
            sourceFingerprint: "fixture"
        )
        guard emptyEvidence.text == nil else {
            throw Failure.assertion("missing text must remain distinct from empty text")
        }
    }

    private static func fixtureContext(
        root: URL,
        capabilities: Set<WorkspaceCapability>,
        rootID: PathAccessRootIdentifier = .project
    ) throws -> ToolContext {
        let installed = PathAccessRoot(
            id: rootID,
            label: "Synthetic PDF workspace",
            scope: try PathAccessScope(root: root, policy: .defaults.workspace),
            isDefault: true
        )
        let grant = try WorkspaceGrant(
            id: WorkspaceGrantIdentifier("agentic-pdf-fixture"),
            rootIdentifier: rootID,
            capabilities: capabilities
        )
        let workspace = try Workspace(root: installed, grants: [grant])
        return ToolContext(workspace: try workspace.context(
            execution: .init(io: .blocking, mutations: .immediate)
        ))
    }

    private static func makePDF(pageCount: Int = 1) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw Failure.assertion("PDF consumer")
        }
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let pdf = CGContext(consumer: consumer, mediaBox: &bounds, nil) else {
            throw Failure.assertion("PDF context")
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 22, nil)
        let text = NSAttributedString(string: "SYNTHETIC DOCUMENT 4242", attributes: [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font
        ])
        for _ in 0..<pageCount {
            pdf.beginPDFPage(nil)
            pdf.textPosition = CGPoint(x: 80, y: 690)
            CTLineDraw(CTLineCreateWithAttributedString(text), pdf)
            pdf.endPDFPage()
        }
        pdf.closePDF()
        return data as Data
    }
}

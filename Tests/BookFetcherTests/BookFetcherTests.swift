import Foundation
import XCTest
@testable import BookFetcherCore

final class BookFetcherTests: XCTestCase {
    func testFormatDetectionUsesFilename() {
        XCTAssertEqual(BookFormat.detect(fileName: "book.EPUB", mimeType: nil), .epub)
        XCTAssertEqual(BookFormat.detect(fileName: "manual.pdf", mimeType: "text/plain"), .pdf)
        XCTAssertEqual(BookFormat.detect(fileName: "novel.azw3", mimeType: nil), .azw3)
        XCTAssertEqual(BookFormat.detect(fileName: "book-pack.ZIP", mimeType: nil), .zip)
    }

    func testFormatDetectionFallsBackToMimeType() {
        XCTAssertEqual(
            BookFormat.detect(fileName: "download", mimeType: "application/epub+zip; charset=binary"),
            .epub
        )
        XCTAssertEqual(BookFormat.detect(fileName: "download", mimeType: "application/pdf"), .pdf)
        XCTAssertEqual(BookFormat.detect(fileName: "download", mimeType: "text/plain"), .txt)
        XCTAssertEqual(BookFormat.detect(fileName: "novel.TXT", mimeType: "application/octet-stream"), .txt)
        XCTAssertEqual(BookFormat.detect(fileName: "manuscript.docx", mimeType: nil), .docx)
        XCTAssertEqual(BookFormat.detect(fileName: "download", mimeType: "application/zip"), .zip)
    }

    func testZIPExtractorFindsSupportedBooksAndSkipsOtherFiles() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("book-fetcher-zip-test-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let archiveURL = root.appendingPathComponent("books.zip")
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Data("First stored book".utf8).write(to: source.appendingPathComponent("First Book.txt"))
        try Data("# Second stored book".utf8).write(to: source.appendingPathComponent("Second Book.md"))
        try Data([0, 1, 2]).write(to: source.appendingPathComponent("ignore.bin"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", source.path, archiveURL.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let downloaded = DownloadedBook(
            localURL: archiveURL,
            originalFilename: "books.zip",
            format: .zip,
            sourceURL: URL(string: "https://example.com/books.zip")!
        )
        let extracted = try BookArchiveExtractor().extract(downloaded)
        defer { extracted.remove() }

        XCTAssertEqual(Set(extracted.books.map(\.format)), Set([.txt, .md]))
        XCTAssertTrue(extracted.skippedFiles.contains { $0.hasSuffix("ignore.bin") })
    }

    func testBatchImportReportDescribesSkippedFiles() {
        let record = ImportRecord(
            title: "Book",
            format: .azw3,
            importedAt: Date(),
            sourceHost: "Stored file",
            localURL: URL(fileURLWithPath: "/tmp/book.azw3")
        )
        XCTAssertEqual(
            BookImportReport(records: [record], skippedFiles: ["ignore.bin"]).message,
            "Added 1 book. Skipped 1 unsupported or unreadable file."
        )
    }

    func testURLValidationAllowsOnlyWebLinks() throws {
        XCTAssertNoThrow(try DownloadService.validatedURL(from: "https://example.com/book.epub"))
        XCTAssertNoThrow(try DownloadService.validatedURL(from: "http://example.com/book.pdf"))
        XCTAssertThrowsError(try DownloadService.validatedURL(from: "file:///tmp/book.epub"))
        XCTAssertThrowsError(try DownloadService.validatedURL(from: "not a url"))
    }

    func testFilenameSanitizerRemovesPathAndForbiddenCharacters() {
        let result = FilenameSanitizer.sanitize("../A:Book.epub", format: .epub)
        XCTAssertEqual(result, "A_Book.epub")
    }

    func testFilenameSanitizerAddsRequiredExtension() {
        XCTAssertEqual(FilenameSanitizer.sanitize("Untitled", format: .txt), "Untitled.txt")
    }

    func testTextMetadataUsesDownloadFilenameInsteadOfFirstHeading() {
        let filename = "The Eye of the World -- Jordan, Robert -- The Wheel of Time, 1 -- abcdef0123456789abcdef0123456789 -- Anna's Archive.txt"
        XCTAssertEqual(BookMetadataInferrer.title(from: filename), "The Eye of the World")
        XCTAssertEqual(BookMetadataInferrer.authors(from: filename), "Robert Jordan")
        XCTAssertTrue(BookMetadataInferrer.shouldOverrideEmbeddedMetadata(for: .txt))
        XCTAssertFalse(BookMetadataInferrer.shouldOverrideEmbeddedMetadata(for: .epub))
    }

    func testPrivateAddressDetection() {
        XCTAssertTrue(NetworkAddressResolver.isPrivateIPv4("192.168.1.10"))
        XCTAssertTrue(NetworkAddressResolver.isPrivateIPv4("10.2.3.4"))
        XCTAssertTrue(NetworkAddressResolver.isPrivateIPv4("172.31.2.4"))
        XCTAssertFalse(NetworkAddressResolver.isPrivateIPv4("172.32.2.4"))
        XCTAssertFalse(NetworkAddressResolver.isPrivateIPv4("8.8.8.8"))
    }

    func testPDFValidation() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("book-fetcher-test-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("%PDF-1.7\n".utf8).write(to: url)
        XCTAssertNoThrow(try BookValidator().validate(url, as: .pdf))
    }

    func testSummaryPreparationCopiesPDFWithoutChangingTheSource() throws {
        let fileManager = FileManager.default
        let source = fileManager.temporaryDirectory
            .appendingPathComponent("book-fetcher-summary-\(UUID().uuidString).pdf")
        let sourceData = Data("%PDF-1.7\nsummary fixture".utf8)
        try sourceData.write(to: source)
        defer { try? fileManager.removeItem(at: source) }
        let summaries = fileManager.temporaryDirectory
            .appendingPathComponent("book-fetcher-summaries-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: summaries) }

        let prepared = try BookSummaryService(summariesDirectory: summaries).preparePDF(from: source)
        defer { try? fileManager.removeItem(at: prepared) }

        XCTAssertNotEqual(prepared, source)
        XCTAssertEqual(try Data(contentsOf: source), sourceData)
        XCTAssertEqual(try Data(contentsOf: prepared), sourceData)
        XCTAssertEqual(prepared.deletingLastPathComponent(), summaries)
    }

    func testSummaryPreparationConvertsDRMFreeEPUBToPDF() throws {
        guard FileManager.default.isExecutableFile(atPath: AppConfiguration.ebookConvert.path) else {
            throw XCTSkip("Calibre is not installed.")
        }
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("book-fetcher-epub-summary-\(UUID().uuidString)", isDirectory: true)
        let meta = root.appendingPathComponent("META-INF", isDirectory: true)
        let content = root.appendingPathComponent("OEBPS", isDirectory: true)
        let epub = root.appendingPathComponent("Summary Fixture.epub")
        try fileManager.createDirectory(at: meta, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: content, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Data("application/epub+zip".utf8).write(to: root.appendingPathComponent("mimetype"))
        try Data(#"<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#.utf8)
            .write(to: meta.appendingPathComponent("container.xml"))
        try Data(#"<?xml version="1.0" encoding="UTF-8"?><package version="2.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="book-id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Summary Fixture</dc:title><dc:identifier id="book-id">summary-fixture</dc:identifier><dc:language>en</dc:language></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="chapter"/></spine></package>"#.utf8)
            .write(to: content.appendingPathComponent("content.opf"))
        try Data(#"<html xmlns="http://www.w3.org/1999/xhtml"><body><h1>Summary Fixture</h1><p>This DRM-free chapter verifies EPUB to PDF conversion for PDFPivot.</p></body></html>"#.utf8)
            .write(to: content.appendingPathComponent("chapter.xhtml"))

        try runProcess("/usr/bin/zip", ["-X0", epub.lastPathComponent, "mimetype"], in: root)
        try runProcess("/usr/bin/zip", ["-Xr9D", epub.lastPathComponent, "META-INF", "OEBPS"], in: root)

        let summaries = root.appendingPathComponent("Summaries", isDirectory: true)
        let prepared: URL
        do {
            prepared = try BookSummaryService(summariesDirectory: summaries).preparePDF(from: epub)
        } catch ProcessRunnerError.nonZeroExit(_, 6, let output)
            where output.contains("ThermalStateObserverMac unable to register") {
            throw XCTSkip("Calibre's PDF renderer is blocked by the test environment.")
        }
        defer { try? fileManager.removeItem(at: prepared) }
        XCTAssertNoThrow(try BookValidator().validate(prepared, as: .pdf))
        XCTAssertTrue((try Data(contentsOf: prepared)).starts(with: Data("%PDF-".utf8)))
    }

    func testSummaryLibraryListsOnlyEPUBAndPDFRecursively() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = root.appendingPathComponent("Author/Book", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["Second.pdf", "First.epub", "Ignored.azw3"] {
            _ = FileManager.default.createFile(
                atPath: nested.appendingPathComponent(name).path,
                contents: Data("fixture".utf8)
            )
        }

        let books = BookSummaryService().availableLibraryBooks(in: root)
        XCTAssertEqual(books.map(\.lastPathComponent), ["First.epub", "Second.pdf"])
    }

    private func runProcess(_ executable: String, _ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testMOBIValidation() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("book-fetcher-test-\(UUID().uuidString).azw3")
        defer { try? FileManager.default.removeItem(at: url) }
        var data = Data(repeating: 0, count: 68)
        data.replaceSubrange(60..<68, with: Data("BOOKMOBI".utf8))
        try data.write(to: url)
        XCTAssertNoThrow(try BookValidator().validate(url, as: .azw3))
    }

    func testCatalogCoverRequiresExactTitleAndAuthor() throws {
        let json = #"{"docs":[{"title":"The Eye of the World","author_name":["Robert Jordan"],"cover_i":980232},{"title":"The Eye of the World Companion","author_name":["Robert Jordan"],"cover_i":1}]}"#
        let id = CatalogCoverService.bestCoverID(
            in: Data(json.utf8),
            title: "The Eye of the World",
            author: "Robert Jordan"
        )
        XCTAssertEqual(id, 980232)
        XCTAssertNil(CatalogCoverService.bestCoverID(
            in: Data(json.utf8),
            title: "The Eye of the World",
            author: "Brandon Sanderson"
        ))
    }

    func testCoverRepairReportMessage() {
        XCTAssertEqual(
            CoverRepairReport(scanned: 36, missing: 1, repaired: 1, unmatchedTitles: []).message,
            "Repaired 1 cover thumbnail."
        )
    }

    func testLiveCoverRepairWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["BOOK_FETCHER_LIVE_COVER_TEST"] == "1" else {
            throw XCTSkip("Set BOOK_FETCHER_LIVE_COVER_TEST=1 to repair the configured Calibre library.")
        }
        let report = try LibraryService().repairMissingCovers()
        XCTAssertGreaterThan(report.scanned, 0)
        XCTAssertEqual(report.repaired, report.missing)
    }
}

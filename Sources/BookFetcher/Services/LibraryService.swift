import Darwin
import Foundation

public enum LibraryServiceError: LocalizedError {
    case calibreMissing
    case libraryMissing
    case launchAgentMissing
    case serverStopFailed
    case serverRestartFailed(String)
    case batchImportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .calibreMissing:
            return "Calibre is not installed in /Applications."
        case .libraryMissing:
            return "The Book LAN Library could not be found."
        case .launchAgentMissing:
            return "The e-reader LAN server configuration could not be found."
        case .serverStopFailed:
            return "The e-reader LAN server did not stop in time. Please try again."
        case .serverRestartFailed(let detail):
            return "The book was imported, but the LAN server could not restart: \(detail)"
        case .batchImportFailed(let detail):
            return detail
        }
    }
}

public struct LibraryService: Sendable {
    private let runner = ProcessRunner()
    private let validator = BookValidator()
    private let coverCatalog = CatalogCoverService()

    private struct LibraryBook: Decodable {
        let id: Int
        let title: String
        let authors: String
        let formats: [String]
        let cover: String?
    }

    private struct CoverRepairTarget {
        let book: LibraryBook
        let missingEmbeddedCoverPaths: [String]
        let existingCoverData: Data?
    }

    public init() {}

    public func importBooks(_ book: DownloadedBook) throws -> BookImportReport {
        guard book.format == .zip else {
            return BookImportReport(records: [try importBook(book)])
        }

        let extracted = try BookArchiveExtractor().extract(book)
        defer { extracted.remove() }

        let stager = StoredBookService()
        var records: [ImportRecord] = []
        var failed: [String] = []

        for candidate in extracted.books {
            do {
                let staged = try stager.stage(
                    candidate.localURL,
                    originalFilename: candidate.originalFilename,
                    sourceAttributionURL: book.sourceURL
                )
                records.append(try importBook(staged))
            } catch {
                failed.append("\(candidate.originalFilename): \(error.localizedDescription)")
            }
        }

        guard !records.isEmpty else {
            let detail = failed.first ?? "No books in the ZIP could be imported."
            throw LibraryServiceError.batchImportFailed(detail)
        }
        return BookImportReport(
            records: records,
            skippedFiles: extracted.skippedFiles,
            failedFiles: failed
        )
    }

    public func importBook(_ book: DownloadedBook) throws -> ImportRecord {
        let fileManager = FileManager.default

        guard fileManager.isExecutableFile(atPath: AppConfiguration.ebookConvert.path),
              fileManager.isExecutableFile(atPath: AppConfiguration.calibreDatabase.path) else {
            throw LibraryServiceError.calibreMissing
        }
        guard fileManager.fileExists(atPath: AppConfiguration.library.path) else {
            throw LibraryServiceError.libraryMissing
        }
        guard fileManager.fileExists(atPath: AppConfiguration.launchAgent.path) else {
            throw LibraryServiceError.launchAgentMissing
        }

        let inferredTitle = BookMetadataInferrer.title(from: book.originalFilename)
        let inferredAuthors = BookMetadataInferrer.authors(from: book.originalFilename)
        let catalogCover = automaticCover(
            for: book,
            title: inferredTitle,
            authors: inferredAuthors
        )
        let catalogCoverURL = try catalogCover.map { try temporaryCover(containing: $0) }
        defer {
            if let catalogCoverURL { try? fileManager.removeItem(at: catalogCoverURL) }
        }

        let importURL: URL
        let importedFormat: BookFormat

        if book.format != .azw3 {
            try fileManager.createDirectory(
                at: AppConfiguration.ready,
                withIntermediateDirectories: true
            )
            let stem = book.localURL.deletingPathExtension().lastPathComponent
            let outputName = FilenameSanitizer.sanitize("\(stem).azw3", format: .azw3)
            let convertedURL = FilenameSanitizer.uniqueDestination(
                in: AppConfiguration.ready,
                filename: outputName
            )

            var conversionArguments = [
                book.localURL.path,
                convertedURL.path,
                "--output-profile", "generic_eink",
                "--prefer-metadata-cover"
            ]
            if BookMetadataInferrer.shouldOverrideEmbeddedMetadata(for: book.format) {
                conversionArguments.append(contentsOf: [
                    "--title", inferredTitle
                ])
                if let authors = inferredAuthors {
                    conversionArguments.append(contentsOf: ["--authors", authors])
                }
            }
            if let catalogCoverURL {
                conversionArguments.append(contentsOf: ["--cover", catalogCoverURL.path])
            }

            _ = try runner.run(
                executable: AppConfiguration.ebookConvert.path,
                arguments: conversionArguments
            )
            try validator.validate(convertedURL, as: .azw3)
            importURL = convertedURL
            importedFormat = .azw3
        } else {
            importURL = book.localURL
            importedFormat = book.format
        }

        try stopServerAndWait()

        do {
            let addResult = try runner.run(
                executable: AppConfiguration.calibreDatabase.path,
                arguments: [
                    "add",
                    "--duplicates",
                    "--library-path", AppConfiguration.library.path,
                    importURL.path
                ]
            )
            if let catalogCoverURL,
               let bookID = addedBookID(from: addResult.output) {
                try setCalibreCover(bookID: bookID, coverURL: catalogCoverURL)
            }
        } catch {
            try? restartServer()
            throw error
        }

        do {
            try restartServer()
        } catch {
            throw LibraryServiceError.serverRestartFailed(error.localizedDescription)
        }

        return ImportRecord(
            title: inferredTitle,
            format: importedFormat,
            importedAt: Date(),
            sourceHost: book.sourceURL.isFileURL ? "Stored file" : (book.sourceURL.host ?? "Website"),
            localURL: importURL
        )
    }

    public func repairMissingCovers() throws -> CoverRepairReport {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: AppConfiguration.calibreDatabase.path),
              fileManager.isExecutableFile(atPath: AppConfiguration.calibreDebug.path),
              fileManager.isExecutableFile(atPath: AppConfiguration.ebookConvert.path),
              fileManager.isExecutableFile(atPath: AppConfiguration.ebookMetadata.path) else {
            throw LibraryServiceError.calibreMissing
        }

        try stopServerAndWait()
        do {
            let result = try runner.run(
                executable: AppConfiguration.calibreDatabase.path,
                arguments: [
                    "list",
                    "--library-path", AppConfiguration.library.path,
                    "--fields", "id,title,authors,formats,cover",
                    "--for-machine"
                ]
            )
            let books = try JSONDecoder().decode([LibraryBook].self, from: Data(result.output.utf8))
            let targets = books.compactMap { book -> CoverRepairTarget? in
                let coverData = validCoverData(at: book.cover)
                let missingEmbedded = book.formats.filter {
                    $0.lowercased().hasSuffix(".azw3") && embeddedCoverData(from: $0) == nil
                }
                guard coverData == nil || !missingEmbedded.isEmpty else { return nil }
                return CoverRepairTarget(
                    book: book,
                    missingEmbeddedCoverPaths: missingEmbedded,
                    existingCoverData: coverData
                )
            }

            var repaired = 0
            var unmatched: [String] = []
            for target in targets {
                let book = target.book
                let extractedCover = book.formats.lazy.compactMap { embeddedCoverData(from: $0) }.first
                guard let data = target.existingCoverData
                    ?? extractedCover
                    ?? (try? coverCatalog.cover(title: book.title, author: book.authors)) else {
                    unmatched.append(book.title)
                    continue
                }
                let coverURL = try temporaryCover(containing: data)
                defer { try? fileManager.removeItem(at: coverURL) }

                for formatPath in target.missingEmbeddedCoverPaths {
                    try rebuildAZW3(at: formatPath, coverURL: coverURL)
                }
                try setCalibreCover(bookID: book.id, coverURL: coverURL)
                repaired += 1
            }

            try restartServer()
            return CoverRepairReport(
                scanned: books.count,
                missing: targets.count,
                repaired: repaired,
                unmatchedTitles: unmatched
            )
        } catch {
            try? restartServer()
            throw error
        }
    }

    private func validCoverData(at path: String?) -> Data? {
        guard let path,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              data.count >= 10_000 else {
            return nil
        }
        return data
    }

    private func embeddedCoverData(from formatPath: String) -> Data? {
        guard formatPath.lowercased().hasSuffix(".azw3") else { return nil }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("book-fetcher-embedded-cover-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        _ = try? runner.run(
            executable: AppConfiguration.ebookMetadata.path,
            arguments: [formatPath, "--get-cover", outputURL.path],
            allowFailure: true
        )
        return validCoverData(at: outputURL.path)
    }

    private func rebuildAZW3(at path: String, coverURL: URL) throws {
        let sourceURL = URL(fileURLWithPath: path)
        let rebuiltURL = sourceURL.deletingLastPathComponent()
            .appendingPathComponent(".book-fetcher-\(UUID().uuidString).azw3")
        defer { try? FileManager.default.removeItem(at: rebuiltURL) }

        _ = try runner.run(
            executable: AppConfiguration.ebookConvert.path,
            arguments: [
                sourceURL.path,
                rebuiltURL.path,
                "--cover", coverURL.path,
                "--output-profile", "generic_eink"
            ]
        )
        try validator.validate(rebuiltURL, as: .azw3)
        _ = try FileManager.default.replaceItemAt(sourceURL, withItemAt: rebuiltURL)
    }

    private func automaticCover(for book: DownloadedBook, title: String, authors: String?) -> Data? {
        guard BookMetadataInferrer.shouldOverrideEmbeddedMetadata(for: book.format),
              let authors,
              !authors.isEmpty else {
            return nil
        }
        return try? coverCatalog.cover(title: title, author: authors)
    }

    private func temporaryCover(containing data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("book-fetcher-cover-\(UUID().uuidString).jpg")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func addedBookID(from output: String) -> Int? {
        guard let range = output.range(of: #"Added book ids?:\s*(\d+)"#, options: .regularExpression) else {
            return nil
        }
        return output[range]
            .split(whereSeparator: { !$0.isNumber })
            .last
            .flatMap { Int($0) }
    }

    private func setCalibreCover(bookID: Int, coverURL: URL) throws {
        let libraryLiteral = jsonString(AppConfiguration.library.path)
        let coverLiteral = jsonString(coverURL.path)
        let code = "from calibre.db.legacy import LibraryDatabase; db=LibraryDatabase(\(libraryLiteral)); db.set_cover(\(bookID), open(\(coverLiteral), 'rb').read())"
        _ = try runner.run(
            executable: AppConfiguration.calibreDebug.path,
            arguments: ["-c", code]
        )
    }

    private func jsonString(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let data = try? encoder.encode(value)
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    private func stopServerAndWait() throws {
        let domain = "gui/\(getuid())/\(AppConfiguration.launchLabel)"
        _ = try? runner.run(
            executable: "/bin/launchctl",
            arguments: ["bootout", domain],
            allowFailure: true
        )
        for _ in 0..<50 {
            let result = try runner.run(
                executable: "/usr/bin/pgrep",
                arguments: ["-f", "calibre-server \(AppConfiguration.library.path)"],
                allowFailure: true
            )
            if result.terminationStatus != 0 { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw LibraryServiceError.serverStopFailed
    }

    private func restartServer() throws {
        let userDomain = "gui/\(getuid())"
        let serviceDomain = "\(userDomain)/\(AppConfiguration.launchLabel)"
        var lastOutput = "Unknown launchd error"

        for _ in 1...5 {
            let result = try runner.run(
                executable: "/bin/launchctl",
                arguments: ["bootstrap", userDomain, AppConfiguration.launchAgent.path],
                allowFailure: true
            )
            if result.terminationStatus == 0 {
                _ = try? runner.run(
                    executable: "/bin/launchctl",
                    arguments: ["enable", serviceDomain],
                    allowFailure: true
                )
                return
            }
            lastOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            Thread.sleep(forTimeInterval: 0.5)
        }

        throw LibraryServiceError.serverRestartFailed(lastOutput)
    }
}

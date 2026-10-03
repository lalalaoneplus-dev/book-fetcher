import Foundation

public enum StoredBookError: LocalizedError {
    case unsupported(String)
    case tooLarge(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let name):
            return "\(name) is not a supported book or ZIP archive."
        case .tooLarge(let name):
            return "\(name) exceeds the 500 MB safety limit."
        }
    }
}

public struct StoredBookService: Sendable {
    private let validator = BookValidator()

    public init() {}

    public func stage(
        _ sourceURL: URL,
        originalFilename: String? = nil,
        sourceAttributionURL: URL? = nil
    ) throws -> DownloadedBook {
        let fileName = originalFilename ?? sourceURL.lastPathComponent
        guard let format = BookFormat.detect(fileName: fileName, mimeType: nil) else {
            throw StoredBookError.unsupported(fileName)
        }

        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw StoredBookError.unsupported(fileName)
        }
        if (values.fileSize ?? 0) > 500 * 1_024 * 1_024 {
            throw StoredBookError.tooLarge(fileName)
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: AppConfiguration.originals, withIntermediateDirectories: true)
        let safeName = FilenameSanitizer.sanitize(fileName, format: format)
        let destination = FilenameSanitizer.uniqueDestination(
            in: AppConfiguration.originals,
            filename: safeName
        )
        try fileManager.copyItem(at: sourceURL, to: destination)

        do {
            try validator.validate(destination, as: format)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }

        return DownloadedBook(
            localURL: destination,
            originalFilename: safeName,
            format: format,
            sourceURL: sourceAttributionURL ?? sourceURL
        )
    }
}

enum BookArchiveError: LocalizedError {
    case unsafeEntry(String)
    case tooManyFiles
    case expandedTooLarge
    case noSupportedBooks

    var errorDescription: String? {
        switch self {
        case .unsafeEntry(let name):
            return "The ZIP contains an unsafe path: \(name)."
        case .tooManyFiles:
            return "The ZIP contains more than 1,000 files."
        case .expandedTooLarge:
            return "The ZIP expands beyond the 1 GB safety limit."
        case .noSupportedBooks:
            return "The ZIP does not contain any supported book files."
        }
    }
}

struct ExtractedBookArchive {
    let directoryURL: URL
    let books: [DownloadedBook]
    let skippedFiles: [String]

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

struct BookArchiveExtractor: Sendable {
    private let runner = ProcessRunner()
    private let validator = BookValidator()

    func extract(_ archive: DownloadedBook) throws -> ExtractedBookArchive {
        let listing = try runner.run(
            executable: "/usr/bin/unzip",
            arguments: ["-Z1", archive.localURL.path]
        )
        for entry in listing.output.components(separatedBy: .newlines) where !entry.isEmpty {
            let normalized = entry.replacingOccurrences(of: "\\", with: "/")
            let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
            if normalized.hasPrefix("/") || components.contains("..") {
                throw BookArchiveError.unsafeEntry(entry)
            }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("book-fetcher-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        do {
            _ = try runner.run(
                executable: "/usr/bin/ditto",
                arguments: ["-x", "-k", archive.localURL.path, root.path]
            )

            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else {
                throw BookArchiveError.noSupportedBooks
            }

            var books: [DownloadedBook] = []
            var skipped: [String] = []
            var fileCount = 0
            var expandedSize = 0

            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: keys)
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                fileCount += 1
                expandedSize += values.fileSize ?? 0
                guard fileCount <= 1_000 else { throw BookArchiveError.tooManyFiles }
                guard expandedSize <= 1_024 * 1_024 * 1_024 else { throw BookArchiveError.expandedTooLarge }

                let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")
                guard !relativePath.hasPrefix("__MACOSX/") else { continue }
                guard let format = BookFormat.detect(fileName: url.lastPathComponent, mimeType: nil),
                      format != .zip else {
                    skipped.append(relativePath)
                    continue
                }

                do {
                    try validator.validate(url, as: format)
                    books.append(DownloadedBook(
                        localURL: url,
                        originalFilename: url.lastPathComponent,
                        format: format,
                        sourceURL: archive.sourceURL
                    ))
                } catch {
                    skipped.append(relativePath)
                }
            }

            guard !books.isEmpty else { throw BookArchiveError.noSupportedBooks }
            return ExtractedBookArchive(directoryURL: root, books: books, skippedFiles: skipped)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}

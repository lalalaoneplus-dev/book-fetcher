import Foundation

public enum BookSummaryError: LocalizedError {
    case unsupported(String)
    case calibreMissing

    public var errorDescription: String? {
        switch self {
        case .unsupported(let name):
            return "Choose a DRM-free EPUB or PDF. \(name) is not supported for summarization."
        case .calibreMissing:
            return "Calibre is required to convert EPUB books to PDF."
        }
    }
}

public struct BookSummaryService: Sendable {
    private let runner = ProcessRunner()
    private let validator = BookValidator()
    private let summariesDirectory: URL

    public init(summariesDirectory: URL = AppConfiguration.summaries) {
        self.summariesDirectory = summariesDirectory
    }

    public func availableLibraryBooks() -> [URL] {
        availableLibraryBooks(in: AppConfiguration.library)
    }

    public func availableLibraryBooks(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return enumerator.compactMap { $0 as? URL }.filter {
            ["epub", "pdf"].contains($0.pathExtension.lowercased())
        }.sorted {
            $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveCompare(
                $1.deletingPathExtension().lastPathComponent
            ) == .orderedAscending
        }
    }

    public func preparePDF(from sourceURL: URL) throws -> URL {
        guard let format = BookFormat.detect(fileName: sourceURL.lastPathComponent, mimeType: nil),
              format == .epub || format == .pdf else {
            throw BookSummaryError.unsupported(sourceURL.lastPathComponent)
        }
        try validator.validate(sourceURL, as: format)

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: summariesDirectory,
            withIntermediateDirectories: true
        )
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let filename = FilenameSanitizer.sanitize("\(stem).pdf", format: .pdf)
        let destination = FilenameSanitizer.uniqueDestination(
            in: summariesDirectory,
            filename: filename
        )

        if format == .pdf {
            try fileManager.copyItem(at: sourceURL, to: destination)
        } else {
            guard fileManager.isExecutableFile(atPath: AppConfiguration.ebookConvert.path) else {
                throw BookSummaryError.calibreMissing
            }
            _ = try runner.run(
                executable: AppConfiguration.ebookConvert.path,
                arguments: [sourceURL.path, destination.path]
            )
        }

        do {
            try validator.validate(destination, as: .pdf)
            return destination
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }
}

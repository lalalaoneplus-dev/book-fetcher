import Foundation

public enum TransferState: Equatable {
    case idle
    case downloading
    case processing
    case success(String)
    case failure(String)
}

public struct DownloadedBook: Sendable {
    public let localURL: URL
    public let originalFilename: String
    public let format: BookFormat
    public let sourceURL: URL

    public init(localURL: URL, originalFilename: String, format: BookFormat, sourceURL: URL) {
        self.localURL = localURL
        self.originalFilename = originalFilename
        self.format = format
        self.sourceURL = sourceURL
    }
}

public struct ImportRecord: Identifiable, Sendable {
    public let id = UUID()
    public let title: String
    public let format: BookFormat
    public let importedAt: Date
    public let sourceHost: String
    public let localURL: URL

    public init(title: String, format: BookFormat, importedAt: Date, sourceHost: String, localURL: URL) {
        self.title = title
        self.format = format
        self.importedAt = importedAt
        self.sourceHost = sourceHost
        self.localURL = localURL
    }
}

public struct BookImportReport: Sendable {
    public let records: [ImportRecord]
    public let skippedFiles: [String]
    public let failedFiles: [String]

    public init(records: [ImportRecord], skippedFiles: [String] = [], failedFiles: [String] = []) {
        self.records = records
        self.skippedFiles = skippedFiles
        self.failedFiles = failedFiles
    }

    public var message: String {
        let added = records.count
        let noun = added == 1 ? "book" : "books"
        let skipped = skippedFiles.count + failedFiles.count
        if skipped == 0 {
            return "Added \(added) \(noun) to the Book LAN Library."
        }
        return "Added \(added) \(noun). Skipped \(skipped) unsupported or unreadable \(skipped == 1 ? "file" : "files")."
    }
}

public struct CoverRepairReport: Sendable, Equatable {
    public let scanned: Int
    public let missing: Int
    public let repaired: Int
    public let unmatchedTitles: [String]

    public init(scanned: Int, missing: Int, repaired: Int, unmatchedTitles: [String]) {
        self.scanned = scanned
        self.missing = missing
        self.repaired = repaired
        self.unmatchedTitles = unmatchedTitles
    }

    public var message: String {
        if missing == 0 {
            return "All \(scanned) books already have cover thumbnails."
        }
        if repaired == missing {
            return "Repaired \(repaired) cover \(repaired == 1 ? "thumbnail" : "thumbnails")."
        }
        return "Repaired \(repaired) of \(missing) cover issues. \(unmatchedTitles.count) could not be matched safely."
    }
}

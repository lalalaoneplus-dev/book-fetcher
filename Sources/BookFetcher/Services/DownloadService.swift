import Foundation

public enum DownloadServiceError: LocalizedError {
    case invalidURL
    case unsupportedScheme
    case badResponse
    case httpStatus(Int)
    case unsupportedContent(fileName: String, mimeType: String?)
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Paste a complete direct download URL."
        case .unsupportedScheme:
            return "Only HTTP and HTTPS download links are supported."
        case .badResponse:
            return "The website returned an invalid response."
        case .httpStatus(let status):
            return "The website returned HTTP \(status). The link may have expired or require a browser login."
        case .unsupportedContent(let fileName, let mimeType):
            let type = mimeType ?? "unknown content type"
            return "The link returned \(fileName) (\(type)), not a format Calibre can convert. Use the website's direct book download link."
        case .tooLarge:
            return "The downloaded file exceeds the 500 MB safety limit."
        }
    }
}

public final class DownloadService: @unchecked Sendable {
    private let session: URLSession
    private let validator = BookValidator()

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.httpAdditionalHeaders = [
            "User-Agent": "BookFetcher/1.0 (macOS)"
        ]
        session = URLSession(configuration: configuration)
    }

    public static func validatedURL(from input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.host != nil else {
            throw DownloadServiceError.invalidURL
        }
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw DownloadServiceError.unsupportedScheme
        }
        return url
    }

    public func download(from url: URL) async throws -> DownloadedBook {
        let (temporaryURL, response) = try await session.download(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DownloadServiceError.badResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw DownloadServiceError.httpStatus(httpResponse.statusCode)
        }

        let suggestedName = response.suggestedFilename
        let redirectedName = response.url?.lastPathComponent.removingPercentEncoding
            ?? response.url?.lastPathComponent
        let urlName = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let mimeType = response.mimeType

        let format = BookFormat.detect(fileName: suggestedName, mimeType: mimeType)
            ?? BookFormat.detect(fileName: redirectedName, mimeType: mimeType)
            ?? BookFormat.detect(fileName: urlName, mimeType: mimeType)
        let fileName = [suggestedName, redirectedName, urlName]
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? "download"

        guard let format else {
            throw DownloadServiceError.unsupportedContent(
                fileName: fileName.isEmpty ? "an unnamed response" : fileName,
                mimeType: mimeType
            )
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: AppConfiguration.originals,
            withIntermediateDirectories: true
        )

        let safeName = FilenameSanitizer.sanitize(fileName, format: format)
        let destination = FilenameSanitizer.uniqueDestination(
            in: AppConfiguration.originals,
            filename: safeName
        )

        let attributes = try fileManager.attributesOfItem(atPath: temporaryURL.path)
        if let size = attributes[.size] as? NSNumber,
           size.int64Value > 500 * 1_024 * 1_024 {
            throw DownloadServiceError.tooLarge
        }

        try fileManager.moveItem(at: temporaryURL, to: destination)

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
            sourceURL: url
        )
    }
}

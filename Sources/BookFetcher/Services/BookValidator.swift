import Foundation

public enum BookValidationError: LocalizedError {
    case invalidEPUB
    case invalidPDF
    case invalidEReaderBook
    case invalidZIP

    public var errorDescription: String? {
        switch self {
        case .invalidEPUB:
            return "The download is not a valid EPUB file. It may be a webpage, an incomplete download, or DRM-protected content."
        case .invalidPDF:
            return "The download is not a valid PDF file."
        case .invalidEReaderBook:
            return "The download is not a valid MOBI or AZW3 book."
        case .invalidZIP:
            return "The ZIP archive is damaged or unreadable."
        }
    }
}

public struct BookValidator: Sendable {
    private let runner = ProcessRunner()

    public init() {}

    public func validate(_ url: URL, as format: BookFormat) throws {
        switch format {
        case .epub:
            let result = try runner.run(
                executable: "/usr/bin/unzip",
                arguments: ["-p", url.path, "mimetype"],
                allowFailure: true
            )
            let mime = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.terminationStatus == 0, mime == "application/epub+zip" else {
                throw BookValidationError.invalidEPUB
            }

        case .pdf:
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.starts(with: Data("%PDF-".utf8)) else {
                throw BookValidationError.invalidPDF
            }

        case .azw3, .mobi, .azw, .prc:
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 68) ?? Data()
            guard data.count >= 68,
                  String(decoding: data[60..<68], as: UTF8.self) == "BOOKMOBI" else {
                throw BookValidationError.invalidEReaderBook
            }

        case .zip:
            let result = try runner.run(
                executable: "/usr/bin/unzip",
                arguments: ["-tq", url.path],
                allowFailure: true
            )
            guard result.terminationStatus == 0 else {
                throw BookValidationError.invalidZIP
            }

        default:
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
    }
}

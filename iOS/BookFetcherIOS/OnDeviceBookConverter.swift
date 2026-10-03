import Foundation
import ZIPFoundation

struct ConvertedBookPayload: Sendable {
    let title: String
    let author: String
    let fileExtension: String
    let data: Data
    let cover: Data?
}

enum OnDeviceConversionError: LocalizedError {
    case unsupported(String)
    case invalidArchive
    case unsafeArchive
    case emptyArchive
    case invalidEPUB
    case downloadFailed
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .unsupported(let ext): return "On-device conversion does not yet support .\(ext)."
        case .invalidArchive: return "The ZIP file is damaged or unreadable."
        case .unsafeArchive: return "The ZIP contains unsafe paths or exceeds the extraction safety limits."
        case .emptyArchive: return "The ZIP does not contain a supported book."
        case .invalidEPUB: return "The EPUB structure is incomplete or unreadable."
        case .downloadFailed: return "The book could not be downloaded from that link."
        case .tooLarge: return "The book exceeds the 500 MB on-device safety limit."
        }
    }
}

struct OnDeviceBookConverter: Sendable {
    private static let maximumBytes: UInt64 = 500 * 1_024 * 1_024
    private static let maximumArchiveEntries = 1_000

    func downloadAndConvert(_ text: String) async throws -> [ConvertedBookPayload] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else {
            throw IntakeError.invalidBookURL
        }
        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OnDeviceConversionError.downloadFailed
        }
        var suggested = response.suggestedFilename ?? url.lastPathComponent
        if URL(fileURLWithPath: suggested).pathExtension.isEmpty,
           let mime = response.mimeType?.lowercased() {
            let inferred = [
                "application/epub+zip": "epub", "text/plain": "txt",
                "text/html": "html", "application/xhtml+xml": "xhtml",
                "application/pdf": "pdf", "application/rtf": "rtf",
                "application/x-mobipocket-ebook": "mobi"
            ][mime]
            if let inferred { suggested += ".\(inferred)" }
        }
        let namedURL = temporaryURL.deletingLastPathComponent().appendingPathComponent(
            suggested.isEmpty ? "download" : suggested
        )
        try? FileManager.default.removeItem(at: namedURL)
        try FileManager.default.moveItem(at: temporaryURL, to: namedURL)
        defer { try? FileManager.default.removeItem(at: namedURL) }
        return try convert(namedURL)
    }

    func convert(_ sourceURL: URL) throws -> [ConvertedBookPayload] {
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw IntakeError.invalidStoredFile }
        guard UInt64(values.fileSize ?? 0) <= Self.maximumBytes else {
            throw OnDeviceConversionError.tooLarge
        }

        let ext = sourceURL.pathExtension.lowercased()
        switch ext {
        case "zip", "htmlz", "txtz", "fbz": return try convertBundle(sourceURL)
        case "epub": return [try convertEPUB(sourceURL)]
        case "txt", "text": return [try convertText(sourceURL)]
        case "md", "markdown": return [try convertMarkdown(sourceURL)]
        case "html", "htm", "xhtml": return [try convertHTML(sourceURL)]
        case "rtf": return [try convertRTF(sourceURL)]
        case "docx", "docm": return [try convertDOCX(sourceURL)]
        case "odt": return [try convertODT(sourceURL)]
        case "fb2": return [try convertFB2(sourceURL)]
        case "cbz": return [try convertComicArchive(sourceURL)]
        case "mobi", "azw", "azw3", "pdf": return [try passThrough(sourceURL)]
        default: throw OnDeviceConversionError.unsupported(ext.isEmpty ? "unknown" : ext)
        }
    }

    private func passThrough(_ url: URL) throws -> ConvertedBookPayload {
        ConvertedBookPayload(
            title: inferredTitle(url), author: "Unknown",
            fileExtension: url.pathExtension.lowercased(),
            data: try Data(contentsOf: url, options: .mappedIfSafe), cover: nil
        )
    }

    private func convertText(_ url: URL) throws -> ConvertedBookPayload {
        let text = try decodedText(at: url)
        let paragraphs = text.components(separatedBy: "\n\n").map {
            "<p>\(Self.escape($0).replacingOccurrences(of: "\n", with: "<br/>"))</p>"
        }.joined(separator: "\n")
        return try mobi(title: inferredTitle(url), author: "Unknown", html: paragraphs)
    }

    private func convertMarkdown(_ url: URL) throws -> ConvertedBookPayload {
        let text = try decodedText(at: url)
        let lines = text.components(separatedBy: .newlines)
        var html: [String] = []
        var paragraph: [String] = []
        func flush() {
            guard !paragraph.isEmpty else { return }
            html.append("<p>\(Self.inlineMarkdown(paragraph.joined(separator: " ")))</p>")
            paragraph.removeAll()
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); continue }
            if let match = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush()
                let level = min(6, trimmed[match].filter { $0 == "#" }.count)
                html.append("<h\(level)>\(Self.inlineMarkdown(String(trimmed[match.upperBound...])))</h\(level)>")
            } else {
                paragraph.append(trimmed)
            }
        }
        flush()
        return try mobi(title: inferredTitle(url), author: "Unknown", html: html.joined(separator: "\n"))
    }

    private func convertHTML(_ url: URL) throws -> ConvertedBookPayload {
        let html = try decodedText(at: url)
        return try mobi(title: Self.htmlTitle(html) ?? inferredTitle(url), author: "Unknown", html: html)
    }

    private func convertRTF(_ url: URL) throws -> ConvertedBookPayload {
        let data = try Data(contentsOf: url)
        let attributed = try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
        let body = attributed.string.components(separatedBy: "\n\n").map {
            "<p>\(Self.escape($0).replacingOccurrences(of: "\n", with: "<br/>"))</p>"
        }.joined(separator: "\n")
        return try mobi(title: inferredTitle(url), author: "Unknown", html: body)
    }

    private func convertDOCX(_ url: URL) throws -> ConvertedBookPayload {
        let folder = try extractArchive(url)
        defer { try? FileManager.default.removeItem(at: folder) }
        let documentURL = folder.appendingPathComponent("word/document.xml")
        guard let xml = try? decodedText(at: documentURL) else {
            throw OnDeviceConversionError.unsupported("docx")
        }
        var text = xml
            .replacingOccurrences(of: #"<w:tab\b[^>]*/>"#, with: "\t", options: .regularExpression)
            .replacingOccurrences(of: #"<w:br\b[^>]*/>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"</w:p\s*>"#, with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        text = Self.decodeEntities(text)
        let core = try? String(contentsOf: folder.appendingPathComponent("docProps/core.xml"), encoding: .utf8)
        let title = core.flatMap { Self.firstCapture(#"(?is)<dc:title[^>]*>(.*?)</dc:title>"#, in: $0) }
        let author = core.flatMap { Self.firstCapture(#"(?is)<dc:creator[^>]*>(.*?)</dc:creator>"#, in: $0) }
        return try mobi(
            title: title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? inferredTitle(url),
            author: author?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Unknown",
            html: Self.paragraphHTML(text)
        )
    }

    private func convertODT(_ url: URL) throws -> ConvertedBookPayload {
        let folder = try extractArchive(url)
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let xml = try? decodedText(at: folder.appendingPathComponent("content.xml")) else {
            throw OnDeviceConversionError.unsupported("odt")
        }
        let text = Self.decodeEntities(xml
            .replacingOccurrences(of: #"</text:(p|h)\s*>"#, with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: #"<text:tab\b[^>]*/>"#, with: "\t", options: .regularExpression)
            .replacingOccurrences(of: #"<text:line-break\b[^>]*/>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
        let meta = try? String(contentsOf: folder.appendingPathComponent("meta.xml"), encoding: .utf8)
        let title = meta.flatMap { Self.firstCapture(#"(?is)<dc:title[^>]*>(.*?)</dc:title>"#, in: $0) }
        let author = meta.flatMap { Self.firstCapture(#"(?is)<dc:creator[^>]*>(.*?)</dc:creator>"#, in: $0) }
        return try mobi(
            title: title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? inferredTitle(url),
            author: author?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Unknown",
            html: Self.paragraphHTML(text)
        )
    }

    private func convertFB2(_ url: URL) throws -> ConvertedBookPayload {
        let xml = try decodedText(at: url)
        let title = Self.firstCapture(#"(?is)<book-title[^>]*>(.*?)</book-title>"#, in: xml)
            .map { Self.plainXMLText($0) } ?? inferredTitle(url)
        let first = Self.firstCapture(#"(?is)<first-name[^>]*>(.*?)</first-name>"#, in: xml).map(Self.plainXMLText)
        let last = Self.firstCapture(#"(?is)<last-name[^>]*>(.*?)</last-name>"#, in: xml).map(Self.plainXMLText)
        let author = [first, last].compactMap { $0 }.joined(separator: " ").nilIfEmpty ?? "Unknown"
        let body = Self.firstCapture(#"(?is)<body\b[^>]*>(.*?)</body>"#, in: xml) ?? xml
        let html = body
            .replacingOccurrences(of: #"(?is)<title\b[^>]*>"#, with: "<h2>", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)</title>"#, with: "</h2>", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<section\b[^>]*>"#, with: "<div>", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)</section>"#, with: "</div><mbp:pagebreak/>", options: .regularExpression)
        return try mobi(title: title, author: author, html: html)
    }

    private func convertComicArchive(_ url: URL) throws -> ConvertedBookPayload {
        let folder = try extractArchive(url)
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { throw OnDeviceConversionError.invalidArchive }
        let imageURLs = (enumerator.allObjects as? [URL] ?? []).filter {
            ["jpg", "jpeg", "png", "gif"].contains($0.pathExtension.lowercased())
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let images = try imageURLs.map { try Data(contentsOf: $0) }
        guard !images.isEmpty else { throw OnDeviceConversionError.emptyArchive }
        let pages = images.indices.map {
            "<div><img recindex=\"\(String(format: "%05d", $0 + 1))\"/></div><mbp:pagebreak/>"
        }.joined(separator: "\n")
        return try mobi(
            title: inferredTitle(url), author: "Unknown", html: pages,
            images: images, coverIndex: 0, cover: images.first
        )
    }

    private func mobi(
        title: String,
        author: String,
        html: String,
        images: [Data] = [],
        coverIndex: Int? = nil,
        cover: Data? = nil
    ) throws -> ConvertedBookPayload {
        let data = try MOBIWriter().makeBook(MOBIBookInput(
            title: title, author: author, html: html, images: images, coverImageIndex: coverIndex
        ))
        return ConvertedBookPayload(
            title: title, author: author, fileExtension: "mobi", data: data, cover: cover
        )
    }

    private func convertBundle(_ url: URL) throws -> [ConvertedBookPayload] {
        let folder = try extractArchive(url)
        defer { try? FileManager.default.removeItem(at: folder) }
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { throw OnDeviceConversionError.invalidArchive }

        var books: [ConvertedBookPayload] = []
        for case let item as URL in enumerator {
            guard (try? item.resourceValues(forKeys: keys).isRegularFile) == true else { continue }
            let ext = item.pathExtension.lowercased()
            guard ext != "zip" else { continue }
            if let converted = try? convert(item) { books.append(contentsOf: converted) }
        }
        guard !books.isEmpty else { throw OnDeviceConversionError.emptyArchive }
        return books
    }

    private func convertEPUB(_ url: URL) throws -> ConvertedBookPayload {
        let folder = try extractArchive(url)
        defer { try? FileManager.default.removeItem(at: folder) }
        let container = folder.appendingPathComponent("META-INF/container.xml")
        guard let containerXML = try? String(contentsOf: container, encoding: .utf8),
              let rootPath = Self.firstCapture(#"full-path\s*=\s*[\"']([^\"']+)[\"']"#, in: containerXML) else {
            throw OnDeviceConversionError.invalidEPUB
        }
        let packageURL = folder.appendingPathComponent(rootPath).standardizedFileURL
        let parser = EPUBPackageParser()
        guard let package = parser.parse(packageURL), !package.spine.isEmpty else {
            throw OnDeviceConversionError.invalidEPUB
        }
        let base = packageURL.deletingLastPathComponent()

        var imageItems = package.manifest.values.filter {
            ["image/jpeg", "image/png", "image/gif"].contains($0.mediaType.lowercased())
        }
        if let coverID = package.coverID,
           let index = imageItems.firstIndex(where: { $0.id == coverID }) {
            let cover = imageItems.remove(at: index)
            imageItems.insert(cover, at: 0)
        } else if let index = imageItems.firstIndex(where: { $0.properties.contains("cover-image") }) {
            let cover = imageItems.remove(at: index)
            imageItems.insert(cover, at: 0)
        }

        var imageData: [Data] = []
        var imageIndices: [String: Int] = [:]
        for item in imageItems {
            let imageURL = base.appendingPathComponent(item.href).standardizedFileURL
            if let data = try? Data(contentsOf: imageURL), !data.isEmpty {
                imageIndices[imageURL.path] = imageData.count + 1
                imageData.append(data)
            }
        }

        var chapters: [String] = []
        for id in package.spine {
            guard let item = package.manifest[id] else { continue }
            let chapterURL = base.appendingPathComponent(item.href).standardizedFileURL
            guard let chapter = try? decodedText(at: chapterURL) else { continue }
            let body = Self.bodyContents(chapter)
            chapters.append(Self.rewriteImages(body, chapterURL: chapterURL, imageIndices: imageIndices))
            chapters.append("<mbp:pagebreak/>")
        }
        guard !chapters.isEmpty else { throw OnDeviceConversionError.invalidEPUB }
        let cover = imageData.first
        return try mobi(
            title: package.title ?? inferredTitle(url),
            author: package.author ?? "Unknown",
            html: chapters.joined(separator: "\n"),
            images: imageData,
            coverIndex: cover == nil ? nil : 0,
            cover: cover
        )
    }

    private func extractArchive(_ url: URL) throws -> URL {
        guard let archive = Archive(url: url, accessMode: .read) else {
            throw OnDeviceConversionError.invalidArchive
        }
        let entries = Array(archive)
        guard entries.count <= Self.maximumArchiveEntries,
              entries.reduce(UInt64(0), { $0 + $1.uncompressedSize }) <= Self.maximumBytes else {
            throw OnDeviceConversionError.unsafeArchive
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("book-fetcher-unzip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            for entry in entries {
                let relative = entry.path.replacingOccurrences(of: "\\", with: "/")
                guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
                    throw OnDeviceConversionError.unsafeArchive
                }
                let output = destination.appendingPathComponent(relative).standardizedFileURL
                guard output.path.hasPrefix(destination.path + "/") || output == destination else {
                    throw OnDeviceConversionError.unsafeArchive
                }
                try archive.extract(entry, to: output)
            }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func decodedText(at url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        for encoding in [String.Encoding.utf8, .utf16, .windowsCP1252, .isoLatin1] {
            if let value = String(data: data, encoding: encoding) { return value }
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }

    private func inferredTitle(_ url: URL) -> String {
        let raw = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Book" : raw
    }

    private static func bodyContents(_ html: String) -> String {
        firstCapture(#"(?is)<body\b[^>]*>(.*)</body>"#, in: html) ?? html
    }

    private static func htmlTitle(_ html: String) -> String? {
        firstCapture(#"(?is)<title\b[^>]*>(.*?)</title>"#, in: html)?
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func rewriteImages(_ html: String, chapterURL: URL, imageIndices: [String: Int]) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?is)(<img\b[^>]*?)\s+src\s*=\s*[\"']([^\"']+)[\"']"#
        ) else { return html }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var result = html
        for match in expression.matches(in: html, range: range).reversed() {
            guard let full = Range(match.range(at: 0), in: html),
                  let prefix = Range(match.range(at: 1), in: html),
                  let source = Range(match.range(at: 2), in: html) else { continue }
            let path = String(html[source]).split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            let resolved = chapterURL.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
            guard let index = imageIndices[resolved.path] else { continue }
            result.replaceSubrange(full, with: "\(html[prefix]) recindex=\"\(String(format: "%05d", index))\"")
        }
        return result
    }

    private static func firstCapture(_ pattern: String, in value: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    private static func inlineMarkdown(_ value: String) -> String {
        var output = escape(value)
        output = output.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "<b>$1</b>", options: .regularExpression)
        output = output.replacingOccurrences(of: #"\*([^*]+)\*"#, with: "<i>$1</i>", options: .regularExpression)
        output = output.replacingOccurrences(of: #"`([^`]+)`"#, with: "<code>$1</code>", options: .regularExpression)
        return output
    }

    private static func paragraphHTML(_ text: String) -> String {
        text.components(separatedBy: "\n\n").map {
            "<p>\(escape($0.trimmingCharacters(in: .whitespacesAndNewlines)).replacingOccurrences(of: "\n", with: "<br/>"))</p>"
        }.joined(separator: "\n")
    }

    private static func plainXMLText(_ value: String) -> String {
        decodeEntities(value.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ value: String) -> String {
        value.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private struct EPUBPackage {
    struct Item {
        let id: String
        let href: String
        let mediaType: String
        let properties: String
    }
    let title: String?
    let author: String?
    let coverID: String?
    let manifest: [String: Item]
    let spine: [String]
}

private final class EPUBPackageParser: NSObject, XMLParserDelegate {
    private var title: String?
    private var author: String?
    private var coverID: String?
    private var manifest: [String: EPUBPackage.Item] = [:]
    private var spine: [String] = []
    private var capture: String?
    private var text = ""

    func parse(_ url: URL) -> EPUBPackage? {
        guard let parser = XMLParser(contentsOf: url) else { return nil }
        parser.delegate = self
        guard parser.parse() else { return nil }
        return EPUBPackage(title: title, author: author, coverID: coverID, manifest: manifest, spine: spine)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? elementName.lowercased()
        if name == "title" || name == "creator" { capture = name; text = "" }
        if name == "item", let id = attributeDict["id"], let href = attributeDict["href"] {
            manifest[id] = EPUBPackage.Item(
                id: id, href: href,
                mediaType: attributeDict["media-type"] ?? "",
                properties: attributeDict["properties"] ?? ""
            )
        }
        if name == "itemref", let id = attributeDict["idref"] { spine.append(id) }
        if name == "meta", attributeDict["name"]?.lowercased() == "cover" {
            coverID = attributeDict["content"]
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capture != nil { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? elementName.lowercased()
        guard capture == name else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "title", title == nil, !value.isEmpty { title = value }
        if name == "creator", author == nil, !value.isEmpty { author = value }
        capture = nil
        text = ""
    }
}

import Foundation

/// A MOBI 6 writer for DRM-free books.
///
/// MOBI 6 is intentionally used for the on-device path: it is reflowable and is
/// understood by older e-readers without requiring Calibre, a desktop converter, a
/// Python runtime, or downloaded executable code.
struct MOBIBookInput: Sendable {
    let title: String
    let author: String
    let html: String
    var images: [Data] = []
    var coverImageIndex: Int? = nil
}

enum MOBIWriterError: LocalizedError {
    case emptyBook
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .emptyBook: return "The book does not contain readable text."
        case .tooLarge: return "The converted book is too large for the on-device e-reader writer."
        }
    }
}

struct MOBIWriter: Sendable {
    private static let textRecordSize = 4_096
    private static let null = UInt32.max

    func makeBook(_ input: MOBIBookInput) throws -> Data {
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled Book" : input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = input.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Unknown" : input.author.trimmingCharacters(in: .whitespacesAndNewlines)
        let document = Self.normalizedDocument(input.html, title: title)
        let text = Data(document.utf8)
        guard !text.isEmpty else { throw MOBIWriterError.emptyBook }
        guard text.count <= Int(UInt32.max) else { throw MOBIWriterError.tooLarge }

        var records: [Data] = [Data()]
        records.append(contentsOf: Self.textRecords(text))
        let textRecordCount = records.count - 1
        let firstNonTextRecord = records.count

        let firstImageRecord: Int?
        if input.images.isEmpty {
            firstImageRecord = nil
        } else {
            firstImageRecord = records.count
            records.append(contentsOf: input.images)
        }
        let lastContentRecord = max(1, records.count - 1)

        let flisRecord = records.count
        records.append(Self.flis)
        let fcisRecord = records.count
        records.append(Self.fcis(textLength: text.count))
        records.append(Data([0xE9, 0x8E, 0x0D, 0x0A]))

        let exth = Self.exth(
            title: title,
            author: author,
            coverOffset: input.coverImageIndex
        )
        records[0] = Self.recordZero(
            title: title,
            textLength: text.count,
            textRecordCount: textRecordCount,
            firstNonTextRecord: firstNonTextRecord,
            firstImageRecord: firstImageRecord ?? records.count,
            lastContentRecord: lastContentRecord,
            flisRecord: flisRecord,
            fcisRecord: fcisRecord,
            exth: exth
        )
        return try Self.palmDatabase(title: title, records: records)
    }

    private static func normalizedDocument(_ body: String, title: String) -> String {
        if body.range(of: "<html", options: [.caseInsensitive]) != nil {
            return body
        }
        return """
        <html><head><meta http-equiv="Content-Type" content="text/html; charset=utf-8"/><title>\(escape(title))</title></head><body>\(body)</body></html>
        """
    }

    private static func textRecords(_ text: Data) -> [Data] {
        var result: [Data] = []
        var start = 0
        while start < text.count {
            var end = min(start + textRecordSize, text.count)
            while end > start, end < text.count, (text[end] & 0xC0) == 0x80 { end -= 1 }
            if end == start { end = min(start + textRecordSize, text.count) }
            result.append(text.subdata(in: start..<end))
            start = end
        }
        return result
    }

    private static func recordZero(
        title: String,
        textLength: Int,
        textRecordCount: Int,
        firstNonTextRecord: Int,
        firstImageRecord: Int,
        lastContentRecord: Int,
        flisRecord: Int,
        fcisRecord: Int,
        exth: Data
    ) -> Data {
        let titleData = Data(title.utf8)
        var data = Data()

        // PalmDOC header (16 bytes), uncompressed UTF-8 records.
        data.appendBE(UInt16(1))
        data.appendBE(UInt16(0))
        data.appendBE(UInt32(textLength))
        data.appendBE(UInt16(textRecordCount))
        data.appendBE(UInt16(textRecordSize))
        data.appendBE(UInt16(0))
        data.appendBE(UInt16(0))

        // MOBI header, version 6, length 0xE8.
        data.append(Data("MOBI".utf8))
        data.appendBE(UInt32(0xE8))
        data.appendBE(UInt32(2))
        data.appendBE(UInt32(65_001))
        data.appendBE(UInt32.random(in: 1...UInt32.max - 1))
        data.appendBE(UInt32(6))
        data.appendByte(0xFF, count: 8)
        data.appendBE(null)
        data.appendByte(0xFF, count: 28)
        data.appendBE(UInt32(firstNonTextRecord))
        data.appendBE(UInt32(0xE8 + 16 + exth.count))
        data.appendBE(UInt32(titleData.count))
        data.append(Data([0x00, 0x00, 0x00, 0x09])) // English; UTF-8 is still used for text.
        data.appendByte(0, count: 8)
        data.appendBE(UInt32(6))
        data.appendBE(UInt32(firstImageRecord))
        data.appendByte(0, count: 16)
        data.appendBE(UInt32(0x50)) // EXTH is present.
        data.appendByte(0, count: 32)
        data.appendBE(null)
        data.appendBE(null)
        data.appendBE(UInt32(0))
        data.appendBE(UInt32(0))
        data.appendByte(0, count: 12)
        data.appendBE(UInt16(1))
        data.appendBE(UInt16(lastContentRecord))
        data.append(Data([0, 0, 0, 1]))
        data.appendBE(UInt32(fcisRecord))
        data.appendBE(UInt32(1))
        data.appendBE(UInt32(flisRecord))
        data.appendBE(UInt32(1))
        data.appendByte(0, count: 8)
        data.appendBE(null)
        data.appendBE(UInt32(0))
        data.appendBE(null)
        data.appendBE(null)
        data.appendBE(UInt32(0)) // no trailing-record flags
        data.appendBE(null) // no NCX index
        data.append(exth)
        data.append(titleData)
        data.appendByte(0, count: 8 * 1_024)
        while data.count % 4 != 0 { data.append(0) }
        return data
    }

    private static func exth(title: String, author: String, coverOffset: Int?) -> Data {
        var records: [Data] = []
        records.append(exthRecord(code: 100, data: Data(author.utf8)))
        records.append(exthRecord(code: 503, data: Data(title.utf8)))
        records.append(exthRecord(code: 524, data: Data("en".utf8)))
        records.append(exthRecord(code: 112, data: Data("book-fetcher:\(UUID().uuidString)".utf8)))
        records.append(exthRecord(code: 106, data: Data(ISO8601DateFormatter().string(from: Date()).utf8)))
        records.append(exthRecord(code: 501, data: Data("EBOK".utf8)))
        if let coverOffset {
            var value = Data()
            value.appendBE(UInt32(coverOffset))
            records.append(exthRecord(code: 201, data: value))
            var realCover = Data()
            realCover.appendBE(UInt32(0))
            records.append(exthRecord(code: 203, data: realCover))
        }
        for (code, value) in [(204, 201), (205, 1), (206, 2), (207, 33_307)] {
            var data = Data()
            data.appendBE(UInt32(value))
            records.append(exthRecord(code: UInt32(code), data: data))
        }

        let payload = records.reduce(into: Data()) { $0.append($1) }
        var result = Data("EXTH".utf8)
        result.appendBE(UInt32(payload.count + 12))
        result.appendBE(UInt32(records.count))
        result.append(payload)
        let padding = 4 - (payload.count % 4)
        result.appendByte(0, count: padding)
        return result
    }

    private static func exthRecord(code: UInt32, data: Data) -> Data {
        var result = Data()
        result.appendBE(code)
        result.appendBE(UInt32(data.count + 8))
        result.append(data)
        return result
    }

    private static func palmDatabase(title: String, records: [Data]) throws -> Data {
        guard records.count <= Int(UInt16.max) else { throw MOBIWriterError.tooLarge }
        var result = Data()
        let ascii = title.folding(options: .diacriticInsensitive, locale: .current)
            .data(using: .ascii, allowLossyConversion: true) ?? Data("Book".utf8)
        result.append(ascii.prefix(31))
        if result.count < 32 { result.appendByte(0, count: 32 - result.count) }

        let now = UInt32(Date().timeIntervalSince1970)
        result.appendBE(UInt16(0))
        result.appendBE(UInt16(0))
        result.appendBE(now)
        result.appendBE(now)
        result.appendBE(UInt32(0))
        result.appendBE(UInt32(0))
        result.appendBE(UInt32(0))
        result.appendBE(UInt32(0))
        result.append(Data("BOOK".utf8))
        result.append(Data("MOBI".utf8))
        result.appendBE(UInt32((2 * records.count) - 1))
        result.appendBE(UInt32(0))
        result.appendBE(UInt16(records.count))

        var offset = 78 + (8 * records.count) + 2
        for (index, record) in records.enumerated() {
            result.appendBE(UInt32(offset))
            result.append(0)
            let uid = UInt32(index * 2)
            result.append(UInt8((uid >> 16) & 0xFF))
            result.append(UInt8((uid >> 8) & 0xFF))
            result.append(UInt8(uid & 0xFF))
            offset += record.count
        }
        result.append(contentsOf: [0, 0])
        records.forEach { result.append($0) }
        return result
    }

    private static let flis = Data([
        0x46, 0x4C, 0x49, 0x53, 0, 0, 0, 8, 0, 0x41, 0, 0, 0, 0, 0, 0,
        0xFF, 0xFF, 0xFF, 0xFF, 0, 1, 0, 3, 0, 0, 0, 3, 0, 0, 0, 1,
        0xFF, 0xFF, 0xFF, 0xFF
    ])

    private static func fcis(textLength: Int) -> Data {
        var data = Data([
            0x46, 0x43, 0x49, 0x53, 0, 0, 0, 0x14, 0, 0, 0, 0x10,
            0, 0, 0, 1, 0, 0, 0, 0
        ])
        data.appendBE(UInt32(textLength))
        data.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0x20, 0, 0, 0, 8, 0, 1, 0, 1, 0, 0, 0, 0])
        return data
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendByte(_ value: UInt8, count: Int) {
        append(contentsOf: repeatElement(value, count: count))
    }
}

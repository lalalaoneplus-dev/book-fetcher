import Foundation

struct LocalLibraryService: Sendable {
    func add(_ payloads: [ConvertedBookPayload], to current: CachedLibrary) throws -> CachedLibrary {
        guard !payloads.isEmpty else { return current }
        try FileManager.default.createDirectory(at: CachedLibraryPaths.root, withIntermediateDirectories: true)
        var books = current.books
        var nextID = max(1, (books.map(\.id).max() ?? 0) + 1)
        for payload in payloads {
            let ext = Self.safeExtension(payload.fileExtension)
            let bookFilename = "book-\(nextID).\(ext)"
            try payload.data.write(to: CachedLibraryPaths.book(bookFilename), options: .atomic)
            var coverFilename: String?
            if let cover = payload.cover, !cover.isEmpty {
                let filename = "cover-\(nextID).jpg"
                try cover.write(to: CachedLibraryPaths.cover(filename), options: .atomic)
                coverFilename = filename
            }
            books.append(CachedBook(
                id: nextID, title: payload.title, author: payload.author,
                bookFilename: bookFilename, coverFilename: coverFilename, format: ext, origin: "iphone"
            ))
            nextID += 1
        }
        let library = CachedLibrary(books: books, syncedAt: current.syncedAt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(library).write(to: CachedLibraryPaths.metadata, options: .atomic)
        return library
    }

    private static func safeExtension(_ value: String) -> String {
        let lowered = value.lowercased().filter { $0.isLetter || $0.isNumber }
        return lowered.isEmpty ? "mobi" : lowered
    }
}

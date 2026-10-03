import Foundation

struct CachedBook: Codable, Identifiable, Sendable {
    let id: Int
    let title: String
    let author: String
    let bookFilename: String
    let coverFilename: String?
    let format: String?
    let origin: String?

    init(id: Int, title: String, author: String, bookFilename: String,
         coverFilename: String?, format: String? = nil, origin: String? = nil) {
        self.id = id
        self.title = title
        self.author = author
        self.bookFilename = bookFilename
        self.coverFilename = coverFilename
        self.format = format
        self.origin = origin
    }

    var downloadExtension: String {
        format ?? URL(fileURLWithPath: bookFilename).pathExtension.lowercased()
    }
}

struct CachedLibrary: Codable, Sendable {
    var books: [CachedBook]
    var syncedAt: Date?

    static let empty = CachedLibrary(books: [], syncedAt: nil)
}

enum CachedLibraryPaths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Book Fetcher/Library", isDirectory: true)
    }()

    static var metadata: URL { root.appendingPathComponent("library.json") }
    static func book(_ filename: String) -> URL { root.appendingPathComponent(filename) }
    static func cover(_ filename: String) -> URL { root.appendingPathComponent(filename) }
}

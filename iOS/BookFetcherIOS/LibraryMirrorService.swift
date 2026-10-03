import Foundation

enum LibraryMirrorError: LocalizedError {
    case invalidServer
    case publicServer
    case unavailable
    case emptyLibrary
    case invalidBook(Int)

    var errorDescription: String? {
        switch self {
        case .invalidServer:
            return "Enter the Mac address shown in the Mac app."
        case .publicServer:
            return "The Mac address must be a private local IPv4 address."
        case .unavailable:
            return "The Mac library website could not be reached. Keep the Mac and iPhone on the same Wi-Fi."
        case .emptyLibrary:
            return "The Mac library does not contain any downloadable AZW3 books."
        case .invalidBook(let id):
            return "Book \(id) could not be downloaded from the Mac library."
        }
    }
}

struct LibraryMirrorService: Sendable {
    private struct Page: Decodable {
        let books: [RemoteBook]
        let total: Int
        let page: Int
        let pages: Int
    }

    private struct RemoteBook: Decodable {
        let id: Int
        let title: String
        let author: String
        let cover: String
        let download: String
    }

    func loadCachedLibrary() -> CachedLibrary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: CachedLibraryPaths.metadata),
              let library = try? decoder.decode(CachedLibrary.self, from: data) else {
            return .empty
        }
        return library
    }

    func sync(from serverText: String, preserving current: CachedLibrary = .empty) async throws -> CachedLibrary {
        let baseURL = try validatedServer(serverText)
        let remoteBooks = try await fetchAllBooks(from: baseURL)
        guard !remoteBooks.isEmpty else { throw LibraryMirrorError.emptyLibrary }

        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("book-fetcher-ios-sync-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        var cached: [CachedBook] = []
        for remote in remoteBooks {
            try Task.checkCancellation()
            let bookFilename = "book-\(remote.id).azw3"
            let bookData = try await download(path: remote.download, relativeTo: baseURL)
            guard bookData.count >= 68 else { throw LibraryMirrorError.invalidBook(remote.id) }
            try bookData.write(to: staging.appendingPathComponent(bookFilename), options: .atomic)

            var coverFilename: String?
            if let coverData = try? await download(path: remote.cover, relativeTo: baseURL),
               !coverData.isEmpty {
                let filename = "cover-\(remote.id).jpg"
                try coverData.write(to: staging.appendingPathComponent(filename), options: .atomic)
                coverFilename = filename
            }
            cached.append(CachedBook(
                id: remote.id,
                title: remote.title,
                author: remote.author,
                bookFilename: bookFilename,
                coverFilename: coverFilename,
                format: "azw3",
                origin: "mac"
            ))
        }

        var nextID = max((cached.map(\.id).max() ?? 0) + 1, 1)
        for local in current.books where local.origin == "iphone" {
            let ext = local.downloadExtension
            let bookFilename = "book-\(nextID).\(ext)"
            let oldBook = CachedLibraryPaths.book(local.bookFilename)
            guard fileManager.fileExists(atPath: oldBook.path) else { continue }
            try fileManager.copyItem(at: oldBook, to: staging.appendingPathComponent(bookFilename))
            var coverFilename: String?
            if let oldCoverName = local.coverFilename {
                let oldCover = CachedLibraryPaths.cover(oldCoverName)
                if fileManager.fileExists(atPath: oldCover.path) {
                    let filename = "cover-\(nextID).jpg"
                    try fileManager.copyItem(at: oldCover, to: staging.appendingPathComponent(filename))
                    coverFilename = filename
                }
            }
            cached.append(CachedBook(
                id: nextID, title: local.title, author: local.author,
                bookFilename: bookFilename, coverFilename: coverFilename,
                format: ext, origin: "iphone"
            ))
            nextID += 1
        }

        let library = CachedLibrary(books: cached, syncedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(library).write(
            to: staging.appendingPathComponent("library.json"),
            options: .atomic
        )
        try replaceCache(with: staging)
        return library
    }

    private func fetchAllBooks(from baseURL: URL) async throws -> [RemoteBook] {
        var all: [RemoteBook] = []
        var pageNumber = 1
        var pageCount = 1
        repeat {
            var components = URLComponents(
                url: baseURL.appendingPathComponent("api/books"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [URLQueryItem(name: "page", value: String(pageNumber))]
            guard let url = components.url else { throw LibraryMirrorError.invalidServer }
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let page = try? JSONDecoder().decode(Page.self, from: data) else {
                throw LibraryMirrorError.unavailable
            }
            all.append(contentsOf: page.books)
            pageCount = page.pages
            pageNumber += 1
        } while pageNumber <= pageCount
        return all
    }

    private func download(path: String, relativeTo baseURL: URL) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw LibraryMirrorError.unavailable
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw LibraryMirrorError.unavailable
        }
        return data
    }

    private func replaceCache(with staging: URL) throws {
        let fileManager = FileManager.default
        let root = CachedLibraryPaths.root
        let parent = root.deletingLastPathComponent()
        let backup = parent.appendingPathComponent("Library-backup-\(UUID().uuidString)")
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: root.path) {
            try fileManager.moveItem(at: root, to: backup)
        }
        do {
            try fileManager.moveItem(at: staging, to: root)
            try? fileManager.removeItem(at: backup)
        } catch {
            if fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: root)
            }
            throw error
        }
    }

    private func validatedServer(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "http",
              let host = url.host, url.port != nil else {
            throw LibraryMirrorError.invalidServer
        }
        guard WiFiAddressResolver.isPrivateIPv4(host) else {
            throw LibraryMirrorError.publicServer
        }
        return url
    }
}

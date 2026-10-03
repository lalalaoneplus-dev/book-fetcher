import Foundation

enum CatalogCoverServiceError: LocalizedError {
    case requestFailed

    var errorDescription: String? {
        "The cover catalog could not be reached."
    }
}

struct CatalogCoverService: Sendable {
    private struct SearchResponse: Decodable {
        let docs: [SearchDocument]
    }

    private struct SearchDocument: Decodable {
        let title: String
        let authorName: [String]?
        let coverID: Int?

        enum CodingKeys: String, CodingKey {
            case title
            case authorName = "author_name"
            case coverID = "cover_i"
        }
    }

    func cover(title: String, author: String) throws -> Data? {
        guard var components = URLComponents(string: "https://openlibrary.org/search.json") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "author", value: author),
            URLQueryItem(name: "fields", value: "title,author_name,cover_i"),
            URLQueryItem(name: "limit", value: "8")
        ]
        guard let searchURL = components.url,
              let searchData = try request(searchURL),
              let coverID = Self.bestCoverID(in: searchData, title: title, author: author),
              let coverURL = URL(string: "https://covers.openlibrary.org/b/id/\(coverID)-L.jpg"),
              let coverData = try request(coverURL),
              Self.looksLikeUsableImage(coverData) else {
            return nil
        }
        return coverData
    }

    static func bestCoverID(in data: Data, title: String, author: String) -> Int? {
        guard let response = try? JSONDecoder().decode(SearchResponse.self, from: data) else {
            return nil
        }
        let expectedTitle = normalized(title)
        let expectedAuthor = normalized(author)

        return response.docs.first { document in
            guard document.coverID != nil,
                  normalized(document.title) == expectedTitle else {
                return false
            }
            return document.authorName?.contains {
                normalized($0) == expectedAuthor
            } == true
        }?.coverID
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func looksLikeUsableImage(_ data: Data) -> Bool {
        guard data.count >= 10_000 else { return false }
        let bytes = [UInt8](data.prefix(8))
        let isJPEG = bytes.count >= 3 && bytes[0...2] == [0xFF, 0xD8, 0xFF]
        let isPNG = bytes == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        return isJPEG || isPNG
    }

    private func request(_ url: URL) throws -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("BookFetcher/1.0 (personal Calibre cover repair)", forHTTPHeaderField: "User-Agent")

        let session = URLSession(configuration: .ephemeral)
        let result = SynchronousRequestResult()
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            result.set(data: data, response: response, error: error)
            semaphore.signal()
        }
        task.resume()

        guard semaphore.wait(timeout: .now() + 12) == .success else {
            task.cancel()
            throw CatalogCoverServiceError.requestFailed
        }
        let snapshot = result.snapshot()
        guard snapshot.error == nil,
              let response = snapshot.response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              let data = snapshot.data,
              data.count <= 10_000_000 else {
            return nil
        }
        return data
    }
}

private final class SynchronousRequestResult: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var response: URLResponse?
    private var error: Error?

    func set(data: Data?, response: URLResponse?, error: Error?) {
        lock.lock()
        self.data = data
        self.response = response
        self.error = error
        lock.unlock()
    }

    func snapshot() -> (data: Data?, response: URLResponse?, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (data, response, error)
    }
}

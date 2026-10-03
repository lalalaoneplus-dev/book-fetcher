import Foundation
import BookFetcherCore
import Network

private struct ImportRequest: Decodable { let url: String }
private struct ImportResponse: Encodable {
    let ok: Bool
    let message: String
    let title: String?
    let format: String?
}

private struct CalibreSearchResponse: Decodable {
    let totalNum: Int
    let bookIDs: [Int]

    enum CodingKeys: String, CodingKey {
        case totalNum = "total_num"
        case bookIDs = "book_ids"
    }
}

private struct CalibreBookResponse: Decodable {
    struct FormatInfo: Decodable { let path: String }

    let title: String
    let authors: [String]
    let lastModified: String
    let mainFormat: [String: String]
    let otherFormats: [String: String]
    let formatMetadata: [String: FormatInfo]

    enum CodingKeys: String, CodingKey {
        case title, authors
        case lastModified = "last_modified"
        case mainFormat = "main_format"
        case otherFormats = "other_formats"
        case formatMetadata = "format_metadata"
    }
}

private struct LibraryBookResponse: Encodable {
    let id: Int
    let title: String
    let author: String
    let cover: String
    let download: String
}

private struct LibraryPageResponse: Encodable {
    let books: [LibraryBookResponse]
    let total: Int
    let page: Int
    let pages: Int
}

private actor ImportCoordinator {
    private let downloader = DownloadService()
    private let importer = LibraryService()

    func importURL(_ text: String) async throws -> BookImportReport {
        let sourceURL = try DownloadService.validatedURL(from: text)
        let book = try await downloader.download(from: sourceURL)
        return try importer.importBooks(book)
    }

    func importUploadedFile(at url: URL, filename: String) throws -> BookImportReport {
        let staged = try StoredBookService().stage(url, originalFilename: filename)
        return try importer.importBooks(staged)
    }

    func repairCovers() throws -> CoverRepairReport {
        try importer.repairMissingCovers()
    }
}

private actor LibraryCatalog {
    private let calibreBaseURL: URL
    private let pageSize = 10

    init(address: String) {
        calibreBaseURL = URL(string: "http://\(address):8080")!
    }

    func page(query: String, requestedPage: Int) async throws -> LibraryPageResponse {
        var components = URLComponents(
            url: calibreBaseURL.appendingPathComponent("ajax/search"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "library_id", value: AppConfiguration.calibreLibraryID),
            URLQueryItem(name: "sort", value: "timestamp"),
            URLQueryItem(name: "sort_order", value: "desc"),
            URLQueryItem(name: "num", value: String(pageSize)),
            URLQueryItem(name: "offset", value: String(max(0, requestedPage - 1) * pageSize))
        ]

        let (searchData, searchResponse) = try await URLSession.shared.data(from: components.url!)
        guard let http = searchResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let result = try JSONDecoder().decode(CalibreSearchResponse.self, from: searchData)
        let pageCount = max(1, Int(ceil(Double(result.totalNum) / Double(pageSize))))
        let currentPage = min(max(1, requestedPage), pageCount)

        var books: [LibraryBookResponse] = []
        for id in result.bookIDs {
            let url = calibreBaseURL
                .appendingPathComponent("ajax/book/\(id)")
                .appending(queryItems: [
                    URLQueryItem(name: "library_id", value: AppConfiguration.calibreLibraryID)
                ])
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { continue }
            let metadata = try JSONDecoder().decode(CalibreBookResponse.self, from: data)
            guard metadata.mainFormat["azw3"] != nil || metadata.otherFormats["azw3"] != nil else { continue }
            let coverVersion = metadata.lastModified.filter { $0.isLetter || $0.isNumber }
            books.append(LibraryBookResponse(
                id: id,
                title: metadata.title,
                author: metadata.authors.isEmpty ? "Unknown" : metadata.authors.joined(separator: " & "),
                cover: "/cover/\(id)?v=\(coverVersion)",
                download: "/download/\(id)"
            ))
        }

        return LibraryPageResponse(
            books: books,
            total: result.totalNum,
            page: currentPage,
            pages: pageCount
        )
    }

    func cover(id: Int) async throws -> (Data, String) {
        let coverURL = calibreBaseURL.appendingPathComponent(
            "get/cover/\(id)/\(AppConfiguration.calibreLibraryID)"
        )
        if let (data, response) = try? await URLSession.shared.data(from: coverURL),
           let http = response as? HTTPURLResponse,
           (200..<300).contains(http.statusCode), !data.isEmpty {
            return (data, http.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg")
        }

        let thumbnailURL = calibreBaseURL.appendingPathComponent(
            "get/thumb/\(id)/\(AppConfiguration.calibreLibraryID)"
        )
        if let (data, response) = try? await URLSession.shared.data(from: thumbnailURL),
           let http = response as? HTTPURLResponse,
           (200..<300).contains(http.statusCode), !data.isEmpty {
            return (data, http.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg")
        }
        throw URLError(.badServerResponse)
    }

    func downloadURL(id: Int) -> URL {
        calibreBaseURL.appendingPathComponent(
            "get/azw3/\(id)/\(AppConfiguration.calibreLibraryID)"
        )
    }
}

private final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let token: String
    private let coordinator: ImportCoordinator
    private let catalog: LibraryCatalog
    private var buffer = Data()
    private var requestHead: RequestHead?
    private var expectedBodyLength = 0
    private var receivedBodyLength = 0
    private var bodyURL: URL?
    private var bodyHandle: FileHandle?
    private var isFinished = false

    private static let maximumHeaderSize = 64 * 1_024
    private static let maximumBodySize = 500 * 1_024 * 1_024

    init(connection: NWConnection, token: String, coordinator: ImportCoordinator, catalog: LibraryCatalog) {
        self.connection = connection
        self.token = token
        self.coordinator = coordinator
        self.catalog = catalog
    }

    func start() {
        connection.start(queue: .global(qos: .userInitiated))
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [self] data, _, complete, error in
            guard !isFinished else { return }
            do {
                if let data, !data.isEmpty {
                    try consume(data)
                }
                guard !isFinished else { return }
                if complete || error != nil {
                    failRequest(message: "The upload ended before the complete request was received.")
                } else {
                    receive()
                }
            } catch {
                failRequest(message: error.localizedDescription)
            }
        }
    }

    private struct RequestHead {
        let method: String
        let path: String
        let headers: [String: String]
        let contentLength: Int
    }

    private struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let bodyURL: URL?
    }

    private func consume(_ data: Data) throws {
        if requestHead == nil {
            buffer.append(data)
            guard buffer.count <= Self.maximumHeaderSize || buffer.range(of: Data("\r\n\r\n".utf8)) != nil else {
                throw CocoaError(.fileReadTooLarge)
            }
            guard let head = parseRequestHead() else { return }
            requestHead = head
            expectedBodyLength = head.contentLength

            if requiresAuthentication(head), head.headers["x-book-fetcher-token"] != token {
                isFinished = true
                respondJSON(status: 401, payload: ImportResponse(
                    ok: false,
                    message: "Pairing token is incorrect.",
                    title: nil,
                    format: nil
                ))
                return
            }

            guard expectedBodyLength <= Self.maximumBodySize else {
                throw StoredBookError.tooLarge("The uploaded file")
            }
            if expectedBodyLength > 0 {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("book-fetcher-upload-\(UUID().uuidString)")
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                bodyURL = url
                bodyHandle = try FileHandle(forWritingTo: url)
            }

            let remaining = buffer
            buffer.removeAll(keepingCapacity: false)
            if !remaining.isEmpty {
                try consumeBody(remaining)
            } else if expectedBodyLength == 0 {
                finishRequest()
            }
            return
        }

        try consumeBody(data)
    }

    private func parseRequestHead() -> RequestHead? {
        let marker = Data("\r\n\r\n".utf8)
        guard let headerRange = buffer.range(of: marker) else { return nil }
        let headerData = buffer[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<separator]).lowercased()] = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
        }

        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0 else { return nil }
        buffer.removeSubrange(..<headerRange.upperBound)
        return RequestHead(
            method: String(parts[0]),
            path: String(parts[1]),
            headers: headers,
            contentLength: length
        )
    }

    private func consumeBody(_ data: Data) throws {
        let remaining = expectedBodyLength - receivedBodyLength
        guard data.count <= remaining else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try bodyHandle?.write(contentsOf: data)
        receivedBodyLength += data.count
        if receivedBodyLength == expectedBodyLength {
            finishRequest()
        }
    }

    private func finishRequest() {
        guard let head = requestHead else { return }
        isFinished = true
        try? bodyHandle?.close()
        bodyHandle = nil
        handle(Request(
            method: head.method,
            path: head.path,
            headers: head.headers,
            bodyURL: bodyURL
        ))
    }

    private func requiresAuthentication(_ request: RequestHead) -> Bool {
        !(request.method == "GET" && (
            request.path == "/" || request.path == "/library"
                || request.path.hasPrefix("/api/books")
                || request.path.hasPrefix("/cover/")
                || request.path.hasPrefix("/download/")
        ))
    }

    private func failRequest(message: String) {
        guard !isFinished else { return }
        isFinished = true
        try? bodyHandle?.close()
        if let bodyURL { try? FileManager.default.removeItem(at: bodyURL) }
        respondJSON(status: 400, payload: ImportResponse(ok: false, message: message, title: nil, format: nil))
    }

    private func handle(_ request: Request) {
        if request.method == "GET", request.path == "/" || request.path == "/library" {
            serveLibraryPage()
            return
        }

        if request.method == "GET", request.path.hasPrefix("/api/books") {
            serveBooks(request.path)
            return
        }

        if request.method == "GET", let id = routeID(in: request.path, prefix: "/cover/") {
            serveCover(id: id)
            return
        }

        if request.method == "GET", let id = routeID(in: request.path, prefix: "/download/") {
            Task {
                let location = await catalog.downloadURL(id: id).absoluteString
                respondData(status: 302, contentType: "text/plain; charset=utf-8", body: Data(), headers: ["Location": location])
            }
            return
        }

        guard request.headers["x-book-fetcher-token"] == token else {
            respondJSON(status: 401, payload: ImportResponse(ok: false, message: "Pairing token is incorrect.", title: nil, format: nil))
            return
        }
        if request.method == "GET", request.path == "/health" {
            respondJSON(status: 200, payload: ImportResponse(ok: true, message: "Book Fetcher is ready.", title: nil, format: nil))
            return
        }

        if request.method == "POST", request.path == "/repair-covers" {
            Task {
                do {
                    let report = try await coordinator.repairCovers()
                    respondJSON(status: 200, payload: ImportResponse(
                        ok: true,
                        message: report.message,
                        title: nil,
                        format: nil
                    ))
                } catch {
                    respondJSON(status: 422, payload: ImportResponse(
                        ok: false,
                        message: error.localizedDescription,
                        title: nil,
                        format: nil
                    ))
                }
            }
            return
        }

        if request.method == "POST", request.path == "/upload" {
            guard let bodyURL = request.bodyURL,
                  let encodedName = request.headers["x-book-fetcher-filename"],
                  let nameData = Data(base64Encoded: encodedName),
                  let filename = String(data: nameData, encoding: .utf8),
                  !filename.isEmpty, filename.utf8.count <= 1_024 else {
                if let bodyURL = request.bodyURL { try? FileManager.default.removeItem(at: bodyURL) }
                respondJSON(status: 400, payload: ImportResponse(
                    ok: false,
                    message: "The upload is missing a valid filename.",
                    title: nil,
                    format: nil
                ))
                return
            }

            Task {
                defer { try? FileManager.default.removeItem(at: bodyURL) }
                do {
                    let report = try await coordinator.importUploadedFile(at: bodyURL, filename: filename)
                    let record = report.records.count == 1 ? report.records.first : nil
                    respondJSON(status: 200, payload: ImportResponse(
                        ok: true,
                        message: report.message,
                        title: record?.title,
                        format: record?.format.displayName
                    ))
                } catch {
                    respondJSON(status: 422, payload: ImportResponse(
                        ok: false,
                        message: error.localizedDescription,
                        title: nil,
                        format: nil
                    ))
                }
            }
            return
        }

        let bodyData = request.bodyURL.flatMap { try? Data(contentsOf: $0) }
        if let bodyURL = request.bodyURL { try? FileManager.default.removeItem(at: bodyURL) }
        guard request.method == "POST", request.path == "/import",
              let bodyData,
              let decoded = try? JSONDecoder().decode(ImportRequest.self, from: bodyData) else {
            respondJSON(status: 400, payload: ImportResponse(ok: false, message: "Send a JSON body containing a direct book URL.", title: nil, format: nil))
            return
        }

        Task {
            do {
                let report = try await coordinator.importURL(decoded.url)
                let record = report.records.count == 1 ? report.records.first : nil
                respondJSON(status: 200, payload: ImportResponse(
                    ok: true,
                    message: report.message,
                    title: record?.title,
                    format: record?.format.displayName
                ))
            } catch {
                respondJSON(status: 422, payload: ImportResponse(ok: false, message: error.localizedDescription, title: nil, format: nil))
            }
        }
    }

    private func serveLibraryPage() {
        let url = AppConfiguration.intakeSupport.appendingPathComponent("book-library.html")
        guard let body = try? Data(contentsOf: url) else {
            respondData(status: 500, contentType: "text/plain; charset=utf-8", body: Data("Library page is missing.".utf8))
            return
        }
        respondData(
            status: 200,
            contentType: "text/html; charset=utf-8",
            body: body,
            headers: [
                "Cache-Control": "no-store",
                "Content-Security-Policy": "default-src 'self'; img-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'"
            ]
        )
    }

    private func serveBooks(_ path: String) {
        let components = URLComponents(string: "http://localhost\(path)")
        let items = components?.queryItems ?? []
        let page = Int(items.first(where: { $0.name == "page" })?.value ?? "1") ?? 1
        let query = items.first(where: { $0.name == "query" })?.value ?? ""
        Task {
            do {
                let payload = try await catalog.page(query: query, requestedPage: page)
                let body = try JSONEncoder().encode(payload)
                respondData(status: 200, contentType: "application/json; charset=utf-8", body: body, headers: ["Cache-Control": "no-store"])
            } catch {
                respondData(status: 502, contentType: "application/json; charset=utf-8", body: Data("{\"error\":\"Calibre library unavailable\"}".utf8))
            }
        }
    }

    private func serveCover(id: Int) {
        Task {
            do {
                let (body, contentType) = try await catalog.cover(id: id)
                respondData(
                    status: 200,
                    contentType: contentType,
                    body: body,
                    headers: ["Cache-Control": "no-store, max-age=0"]
                )
            } catch {
                fputs("Cover \(id) failed: \(error)\n", stderr)
                respondData(status: 404, contentType: "text/plain; charset=utf-8", body: Data("Cover unavailable".utf8))
            }
        }
    }

    private func routeID(in path: String, prefix: String) -> Int? {
        guard path.hasPrefix(prefix) else { return nil }
        return Int(path.dropFirst(prefix.count).split(separator: "?", maxSplits: 1).first ?? "")
    }

    private func respondJSON(status: Int, payload: ImportResponse) {
        let body = (try? JSONEncoder().encode(payload)) ?? Data()
        respondData(status: status, contentType: "application/json; charset=utf-8", body: body)
    }

    private func respondData(status: Int, contentType: String, body: Data, headers: [String: String] = [:]) {
        let reason = [
            200: "OK", 302: "Found", 400: "Bad Request", 401: "Unauthorized",
            404: "Not Found", 413: "Payload Too Large", 422: "Unprocessable Content",
            500: "Internal Server Error", 502: "Bad Gateway"
        ][status] ?? "Error"
        var headerText = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (name, value) in headers { headerText += "\(name): \(value)\r\n" }
        headerText += "\r\n"
        var data = Data(headerText.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { [connection] _ in connection.cancel() })
    }
}

@main
private struct BookFetcherServer {
    static func main() throws {
        let tokenURL = AppConfiguration.intakeToken
        guard let token = try? String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              token.count >= 24 else {
            fputs("Missing or invalid pairing token at \(tokenURL.path)\n", stderr)
            exit(78)
        }
        guard let address = NetworkAddressResolver.privateWiFiIPv4(),
              let port = NWEndpoint.Port(rawValue: AppConfiguration.intakePort) else {
            fputs("No private Wi-Fi IPv4 address is available.\n", stderr)
            exit(69)
        }
        do {
            try LANWebsiteService().ensureCalibreLibraryRunning()
        } catch {
            fputs("Could not prepare the Calibre LAN library: \(error.localizedDescription)\n", stderr)
            exit(69)
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: port)
        let listener = try NWListener(using: parameters)
        let coordinator = ImportCoordinator()
        let catalog = LibraryCatalog(address: address)
        listener.newConnectionHandler = { connection in
            HTTPConnection(connection: connection, token: token, coordinator: coordinator, catalog: catalog).start()
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("Book Fetcher intake listening on \(address):\(AppConfiguration.intakePort)")
            case .failed(let error):
                fputs("Listener failed: \(error)\n", stderr)
                exit(70)
            default:
                break
            }
        }
        listener.start(queue: .main)

        let networkMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
        let monitorQueue = DispatchQueue(label: "com.prakrinkumar.book-fetcher.network-monitor")
        networkMonitor.pathUpdateHandler = { _ in
            monitorQueue.asyncAfter(deadline: .now() + 1) {
                guard NetworkAddressResolver.privateWiFiIPv4() != address else { return }
                fputs("Wi-Fi address changed; restarting the e-reader LAN services.\n", stderr)
                exit(0)
            }
        }
        networkMonitor.start(queue: monitorQueue)
        dispatchMain()
    }
}

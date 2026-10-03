import Foundation
import Network

enum EReaderWebServerState: Sendable {
    case stopped
    case starting
    case ready(String)
    case failed(String)
}

/// A real HTTP request the e-reader's browser made against us — the only reliable
/// signal that the e-reader actually reached the iPhone (iOS gives apps no way to
/// list hotspot clients, so we detect the e-reader at the HTTP layer instead).
enum EReaderWebEvent: Sendable {
    case opened                 // loaded the library page
    case downloaded(String)     // tapped Download for a book title
}

final class EReaderWebServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.prakrinkumar.book-fetcher-ios.web-server")
    private var listener: NWListener?
    private var library = CachedLibrary.empty
    // Port 80 so the e-reader types just http://172.20.10.1 (no :port to key in).
    // iOS lets sandboxed apps bind privileged ports — the restriction was lifted
    // before the first iOS SDK. The Simulator is the exception (it runs on macOS,
    // which enforces the privileged-port rule), so fall back to 8090 if 80 is
    // refused. That also covers any device that unexpectedly blocks 80.
    private let primaryPort: UInt16 = 80
    private let fallbackPort: UInt16 = 8090
    private var triedFallback = false

    var onStateChange: (@Sendable (EReaderWebServerState) -> Void)?
    var onRequest: (@Sendable (EReaderWebEvent) -> Void)?

    func start(library: CachedLibrary, address: String) throws {
        stop()
        self.library = library
        triedFallback = false
        onStateChange?(.starting)
        try startListener(address: address, port: primaryPort)
    }

    private func startListener(address: String, port: UInt16) throws {
        let parameters = NWParameters.tcp
        // Pin to the resolved local IP. On the hotspot path that address lives on
        // a bridge interface, not the Wi-Fi station interface — so we must NOT
        // force requiredInterfaceType = .wifi here or the bind fails.
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(address),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            EReaderWebConnection(connection: connection, library: self.library, onRequest: self.onRequest).start()
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let url = port == 80 ? "http://\(address)" : "http://\(address):\(port)"
                self.onStateChange?(.ready(url))
            case .failed(let error):
                if !self.triedFallback {
                    self.triedFallback = true          // port 80 refused → retry on 8090
                    try? self.startListener(address: address, port: self.fallbackPort)
                } else {
                    self.onStateChange?(.failed(error.localizedDescription))
                    self.stop()
                }
            case .cancelled:
                self.onStateChange?(.stopped)
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    func updateLibrary(_ library: CachedLibrary) {
        queue.async { [weak self] in self?.library = library }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

private final class EReaderWebConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let library: CachedLibrary
    private let onRequest: (@Sendable (EReaderWebEvent) -> Void)?
    private var request = Data()

    init(connection: NWConnection, library: CachedLibrary, onRequest: (@Sendable (EReaderWebEvent) -> Void)?) {
        self.connection = connection
        self.library = library
        self.onRequest = onRequest
    }

    func start() {
        connection.start(queue: .global(qos: .userInitiated))
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [self] data, _, complete, error in
            if let data { request.append(data) }
            if request.count > 16_384 {
                respond(status: 413, contentType: "text/plain; charset=utf-8", body: Data("Request too large".utf8))
                return
            }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                route()
            } else if complete || error != nil {
                respond(status: 400, contentType: "text/plain; charset=utf-8", body: Data("Invalid request".utf8))
            } else {
                receive()
            }
        }
    }

    private func route() {
        guard let text = String(data: request, encoding: .utf8),
              let first = text.components(separatedBy: "\r\n").first else {
            respond(status: 400, contentType: "text/plain; charset=utf-8", body: Data("Invalid request".utf8))
            return
        }
        let parts = first.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            respond(status: 405, contentType: "text/plain; charset=utf-8", body: Data("Method not allowed".utf8))
            return
        }
        let path = String(parts[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"

        if path == "/" || path == "/library" {
            onRequest?(.opened)
            respond(
                status: 200,
                contentType: "text/html; charset=utf-8",
                body: Data(Self.libraryHTML(library.books).utf8),
                extraHeaders: ["Cache-Control": "no-store"]
            )
            return
        }
        if let id = routeID(path, prefix: "/cover/"),
           let book = library.books.first(where: { $0.id == id }),
           let filename = book.coverFilename {
            serveFile(CachedLibraryPaths.cover(filename), contentType: "image/jpeg", downloadName: nil)
            return
        }
        if let id = routeID(path, prefix: "/download/"),
           let book = library.books.first(where: { $0.id == id }) {
            onRequest?(.downloaded(book.title))
            serveFile(
                CachedLibraryPaths.book(book.bookFilename),
                contentType: Self.contentType(book.downloadExtension),
                downloadName: Self.safeDownloadName(book.title, extension: book.downloadExtension)
            )
            return
        }
        respond(status: 404, contentType: "text/plain; charset=utf-8", body: Data("Not found".utf8))
    }

    private func routeID(_ path: String, prefix: String) -> Int? {
        guard path.hasPrefix(prefix) else { return nil }
        return Int(path.dropFirst(prefix.count))
    }

    private func serveFile(_ url: URL, contentType: String, downloadName: String?) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let handle = try? FileHandle(forReadingFrom: url) else {
            respond(status: 404, contentType: "text/plain; charset=utf-8", body: Data("File unavailable".utf8))
            return
        }

        var headers = Self.responseHeader(status: 200, contentType: contentType, length: size.intValue)
        if let downloadName {
            headers += "Content-Disposition: attachment; filename=\"\(downloadName)\"\r\n"
        }
        headers += "Connection: close\r\n\r\n"
        connection.send(content: Data(headers.utf8), isComplete: false, completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else {
                try? handle.close()
                self?.connection.cancel()
                return
            }
            self.sendNextChunk(from: handle)
        })
    }

    private func sendNextChunk(from handle: FileHandle) {
        let chunk = (try? handle.read(upToCount: 64 * 1_024)) ?? nil
        guard let chunk, !chunk.isEmpty else {
            try? handle.close()
            connection.send(content: nil, isComplete: true, completion: .contentProcessed { [connection] _ in
                connection.cancel()
            })
            return
        }
        connection.send(content: chunk, isComplete: false, completion: .contentProcessed { [weak self] error in
            guard error == nil else {
                try? handle.close()
                self?.connection.cancel()
                return
            }
            self?.sendNextChunk(from: handle)
        })
    }

    private func respond(
        status: Int,
        contentType: String,
        body: Data,
        extraHeaders: [String: String] = [:]
    ) {
        var header = Self.responseHeader(status: status, contentType: contentType, length: body.count)
        for (name, value) in extraHeaders { header += "\(name): \(value)\r\n" }
        header += "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, isComplete: true, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }

    private static func responseHeader(status: Int, contentType: String, length: Int) -> String {
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large"][status] ?? "Error"
        return "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(length)\r\n"
    }

    private static func libraryHTML(_ books: [CachedBook]) -> String {
        let cards = books.map { book in
            let cover = book.coverFilename == nil
                ? "<div class=placeholder>BOOK</div>"
                : "<img src=\"/cover/\(book.id)\" alt=\"Cover\">"
            return """
            <article>
              \(cover)
              <div class=details>
                <h2>\(escape(book.title))</h2>
                <p>\(escape(book.author))</p>
                <a class=download href=\"/download/\(book.id)\">Download \(escape(book.downloadExtension.uppercased()))</a>
              </div>
            </article>
            """
        }.joined(separator: "\n")

        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Book Fetcher</title><style>
        body{font-family:Arial,sans-serif;margin:0;background:#f4f0e6;color:#251f19}header{padding:20px;background:#17345f;color:white}header h1{margin:0;font-size:26px}header p{margin:6px 0 0}.library{padding:12px}article{display:flex;gap:14px;background:white;border:2px solid #c9bda7;border-radius:10px;padding:12px;margin-bottom:12px}img,.placeholder{width:84px;height:118px;object-fit:cover;background:#dbe3ef;border-radius:5px;flex:none}.placeholder{display:flex;align-items:center;justify-content:center;font-weight:bold;color:#40516d}.details{min-width:0}h2{font-size:20px;margin:2px 0 7px;overflow-wrap:anywhere}p{margin:0 0 14px;color:#5a5149}.download{display:inline-block;padding:11px 14px;background:#17345f;color:white;text-decoration:none;border-radius:7px;font-weight:bold}
        </style></head><body><header><h1>Book Fetcher</h1><p>\(books.count) cached books on this iPhone</p></header><main class=library>\(cards)</main></body></html>
        """
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func safeDownloadName(_ title: String, extension ext: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(title.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(cleaned.isEmpty ? "Book" : cleaned).\(ext)"
    }

    private static func contentType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": return "application/pdf"
        case "txt": return "text/plain; charset=utf-8"
        case "azw3": return "application/vnd.amazon.mobi8-ebook"
        default: return "application/x-mobipocket-ebook"
        }
    }
}

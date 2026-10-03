import Foundation

struct IntakeResponse: Decodable, Sendable {
    let ok: Bool
    let message: String
    let title: String?
    let format: String?
}

enum IntakeError: LocalizedError {
    case invalidServer
    case publicServer
    case invalidBookURL
    case invalidStoredFile
    case missingToken
    case badResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidServer: return "Enter the Mac address shown in the Mac app."
        case .publicServer: return "For safety, the Mac address must be a private local IPv4 address."
        case .invalidBookURL: return "Paste a complete HTTP or HTTPS book download link."
        case .invalidStoredFile: return "Choose a regular book file or ZIP archive."
        case .missingToken: return "Paste the pairing token shown in the Mac app."
        case .badResponse: return "The Mac returned an unreadable response."
        case .server(let message): return message
        }
    }
}

struct IntakeClient: Sendable {
    func send(bookURLText: String, serverText: String, token: String) async throws -> IntakeResponse {
        let server = try validatedServer(serverText)
        guard let bookURL = URL(string: bookURLText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = bookURL.scheme?.lowercased(), ["http", "https"].contains(scheme),
              bookURL.host != nil else { throw IntakeError.invalidBookURL }
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanToken.count >= 24 else { throw IntakeError.missingToken }

        var endpoint = server
        endpoint.append(path: "import")
        return try await request(endpoint: endpoint, token: cleanToken, body: ["url": bookURL.absoluteString])
    }

    func repairCovers(serverText: String, token: String) async throws -> IntakeResponse {
        let server = try validatedServer(serverText)
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanToken.count >= 24 else { throw IntakeError.missingToken }

        var endpoint = server
        endpoint.append(path: "repair-covers")
        return try await request(endpoint: endpoint, token: cleanToken, body: [:])
    }

    func upload(fileURL: URL, serverText: String, token: String) async throws -> IntakeResponse {
        let server = try validatedServer(serverText)
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanToken.count >= 24 else { throw IntakeError.missingToken }

        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw IntakeError.invalidStoredFile }
        if (values.fileSize ?? 0) > 500 * 1_024 * 1_024 {
            throw IntakeError.server("\(fileURL.lastPathComponent) exceeds the 500 MB safety limit.")
        }

        var endpoint = server
        endpoint.append(path: "upload")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 620
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(cleanToken, forHTTPHeaderField: "X-Book-Fetcher-Token")
        request.setValue(
            Data(fileURL.lastPathComponent.utf8).base64EncodedString(),
            forHTTPHeaderField: "X-Book-Fetcher-Filename"
        )

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        return try decodedResponse(data: data, response: response)
    }

    private func request(endpoint: URL, token: String, body: [String: String]) async throws -> IntakeResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 620
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-Book-Fetcher-Token")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        return try decodedResponse(data: data, response: response)
    }

    private func decodedResponse(data: Data, response: URLResponse) throws -> IntakeResponse {
        guard let http = response as? HTTPURLResponse,
              let result = try? JSONDecoder().decode(IntakeResponse.self, from: data) else {
            throw IntakeError.badResponse
        }
        guard (200..<300).contains(http.statusCode), result.ok else {
            throw IntakeError.server(result.message)
        }
        return result
    }

    private func validatedServer(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "http",
              let host = url.host, url.port != nil else { throw IntakeError.invalidServer }
        guard isPrivateIPv4(host) else { throw IntakeError.publicServer }
        return url
    }

    private func isPrivateIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10 || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 172 && (16...31).contains(parts[1]))
    }
}

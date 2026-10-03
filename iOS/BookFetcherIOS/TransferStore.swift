import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class TransferStore {
    enum State: Equatable {
        case idle
        case sending
        case success(String)
        case failure(String)
    }

    var bookURL = ""
    var serverAddress: String {
        didSet { UserDefaults.standard.set(serverAddress, forKey: "serverAddress") }
    }
    var pairingToken: String {
        didSet { KeychainStore.save(pairingToken, account: "pairingToken") }
    }
    private(set) var state: State = .idle
    private(set) var isRepairingCovers = false
    private(set) var isUploadingFiles = false
    private(set) var isConvertingOnDevice = false
    private(set) var uploadProgress = ""
    private(set) var isSyncingLibrary = false
    private(set) var cachedBookCount = 0
    private(set) var lastLibrarySync: Date?
    private(set) var isServingWebsite = false
    private(set) var isStartingWebsite = false
    private(set) var websiteAddress = ""
    private(set) var websiteMessage = "Starting the e-reader website when this app becomes active…"
    private(set) var networkMode: WiFiAddressResolver.Mode?
    private(set) var eReaderStatus = ""
    private let client = IntakeClient()
    private let mirror = LibraryMirrorService()
    private let converter = OnDeviceBookConverter()
    private let localLibrary = LocalLibraryService()
    private let webServer = EReaderWebServer()
    private var cachedLibrary = CachedLibrary.empty

    init() {
        serverAddress = UserDefaults.standard.string(forKey: "serverAddress") ?? "http://192.168.1.10:8090"
        pairingToken = KeychainStore.load(account: "pairingToken")
        cachedLibrary = mirror.loadCachedLibrary()
        cachedBookCount = cachedLibrary.books.count
        lastLibrarySync = cachedLibrary.syncedAt
        webServer.onStateChange = { [weak self] serverState in
            Task { @MainActor in self?.handleWebServerState(serverState) }
        }
        webServer.onRequest = { [weak self] event in
            Task { @MainActor in self?.handleEReaderEvent(event) }
        }
    }

    /// Live network read for the setup guide (cheap getifaddrs each call).
    var detectedNetwork: WiFiAddressResolver.Resolved? { WiFiAddressResolver.resolve() }
    var isHotspotServing: Bool { isServingWebsite && networkMode == .hotspot }

    var canSend: Bool {
        !bookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !pairingToken.isEmpty && state != .sending && !isRepairingCovers && !isUploadingFiles
    }

    var canProcessOnIPhone: Bool {
        !bookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && state != .sending && !isRepairingCovers && !isUploadingFiles && !isConvertingOnDevice
    }

    var canRepairCovers: Bool {
        !pairingToken.isEmpty && state != .sending && !isRepairingCovers && !isUploadingFiles
    }

    var canBrowseStoredBooks: Bool {
        state != .sending && !isRepairingCovers && !isUploadingFiles && !isSyncingLibrary && !isConvertingOnDevice
    }

    var canSyncLibrary: Bool {
        state != .sending && !isRepairingCovers && !isUploadingFiles && !isSyncingLibrary && !isServingWebsite
    }

    var canStartWebsite: Bool {
        !isSyncingLibrary && !isServingWebsite && !isStartingWebsite
    }

    func usePastedStrings(_ values: [String]) {
        if let value = values.first { bookURL = value.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func send() async {
        guard canSend else { return }
        state = .sending
        do {
            let result = try await client.send(bookURLText: bookURL, serverText: serverAddress, token: pairingToken)
            let name = result.title ?? "Book"
            let format = result.format.map { " (\($0))" } ?? ""
            state = .success("\(name)\(format) was added to your Mac library.")
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failure(error.localizedDescription)
        }
    }

    func processLinkOnIPhone() async {
        guard canProcessOnIPhone else { return }
        isConvertingOnDevice = true
        state = .idle
        defer { isConvertingOnDevice = false }
        do {
            let link = bookURL
            let engine = converter
            let payloads = try await Task.detached(priority: .userInitiated) {
                try await engine.downloadAndConvert(link)
            }.value
            try addToIPhoneLibrary(payloads)
            state = .success(Self.addedMessage(payloads))
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failure(error.localizedDescription)
        }
    }

    func repairCovers() async {
        guard canRepairCovers else { return }
        isRepairingCovers = true
        state = .idle
        defer { isRepairingCovers = false }

        do {
            let result = try await client.repairCovers(serverText: serverAddress, token: pairingToken)
            state = .success(result.message)
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failure(error.localizedDescription)
        }
    }

    func uploadStoredBooks(_ urls: [URL]) async {
        guard !urls.isEmpty, canBrowseStoredBooks else { return }
        isUploadingFiles = true
        state = .idle
        defer {
            isUploadingFiles = false
            uploadProgress = ""
        }

        do {
            var responses: [IntakeResponse] = []
            for (index, url) in urls.enumerated() {
                uploadProgress = "Uploading \(index + 1) of \(urls.count): \(url.lastPathComponent)"
                responses.append(try await uploadStoredBook(url))
            }
            if responses.count == 1, let response = responses.first {
                state = .success(response.message)
            } else {
                state = .success("Processed \(responses.count) stored files on your Mac library.")
            }
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failure(error.localizedDescription)
        }
    }

    func processStoredBooksOnIPhone(_ urls: [URL]) async {
        guard !urls.isEmpty, canBrowseStoredBooks else { return }
        isConvertingOnDevice = true
        state = .idle
        uploadProgress = "Preparing on-device conversion…"
        defer {
            isConvertingOnDevice = false
            uploadProgress = ""
        }
        do {
            var all: [ConvertedBookPayload] = []
            for (index, url) in urls.enumerated() {
                uploadProgress = "Converting \(index + 1) of \(urls.count): \(url.lastPathComponent)"
                let granted = url.startAccessingSecurityScopedResource()
                let engine = converter
                do {
                    let converted = try await Task.detached(priority: .userInitiated) {
                        try engine.convert(url)
                    }.value
                    all.append(contentsOf: converted)
                } catch {
                    if granted { url.stopAccessingSecurityScopedResource() }
                    throw error
                }
                if granted { url.stopAccessingSecurityScopedResource() }
            }
            try addToIPhoneLibrary(all)
            state = .success(Self.addedMessage(all))
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failure(error.localizedDescription)
        }
    }

    func showFileSelectionError(_ error: Error) {
        guard !isUploadingFiles else { return }
        state = .failure(error.localizedDescription)
    }

    func syncLibraryToIPhone() async {
        guard canSyncLibrary else { return }
        isSyncingLibrary = true
        state = .idle
        websiteMessage = "Copying converted books and covers from the Mac…"
        defer { isSyncingLibrary = false }

        do {
            let library = try await mirror.sync(from: serverAddress, preserving: cachedLibrary)
            cachedLibrary = library
            cachedBookCount = library.books.count
            lastLibrarySync = library.syncedAt
            webServer.updateLibrary(library)
            websiteMessage = "Cached \(library.books.count) books on this iPhone."
        } catch is CancellationError {
            websiteMessage = "Library sync cancelled."
        } catch {
            websiteMessage = error.localizedDescription
        }
    }

    func startWebsite() {
        guard canStartWebsite else { return }
        guard let resolved = WiFiAddressResolver.resolve() else {
            networkMode = nil
            websiteMessage = "Turn on Personal Hotspot (Settings ▸ Personal Hotspot) so your e-reader can connect."
            return
        }
        networkMode = resolved.mode
        do {
            try webServer.start(library: cachedLibrary, address: resolved.ip)
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            websiteMessage = error.localizedDescription
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    /// Called on a timer by the setup guide so serving auto-starts the moment the
    /// hotspot (or Wi-Fi) comes up, without the user having to leave the app.
    func refreshServing() {
        if !isServingWebsite && !isStartingWebsite { startWebsite() }
    }

    func stopWebsite() {
        webServer.stop()
        isServingWebsite = false
        isStartingWebsite = false
        websiteAddress = ""
        networkMode = nil
        eReaderStatus = ""
        websiteMessage = cachedBookCount == 0
            ? "Website stopped. Add books whenever you are ready."
            : "Website stopped. Cached books remain on this iPhone."
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func handleEReaderEvent(_ event: EReaderWebEvent) {
        switch event {
        case .opened:
            eReaderStatus = "✅ Your e-reader opened the library."
        case .downloaded(let title):
            eReaderStatus = "📥 Sending “\(title)” to your e-reader…"
        }
    }

    private func handleWebServerState(_ serverState: EReaderWebServerState) {
        switch serverState {
        case .stopped:
            isServingWebsite = false
            isStartingWebsite = false
            websiteAddress = ""
            UIApplication.shared.isIdleTimerDisabled = false
        case .starting:
            isStartingWebsite = true
            websiteMessage = "Starting the iPhone website…"
        case .ready(let address):
            isServingWebsite = true
            isStartingWebsite = false
            websiteAddress = address
            websiteMessage = "Keep this app open while the e-reader downloads books."
        case .failed(let message):
            isServingWebsite = false
            isStartingWebsite = false
            websiteAddress = ""
            websiteMessage = message
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func uploadStoredBook(_ url: URL) async throws -> IntakeResponse {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        return try await client.upload(fileURL: url, serverText: serverAddress, token: pairingToken)
    }

    private func addToIPhoneLibrary(_ payloads: [ConvertedBookPayload]) throws {
        cachedLibrary = try localLibrary.add(payloads, to: cachedLibrary)
        cachedBookCount = cachedLibrary.books.count
        webServer.updateLibrary(cachedLibrary)
        websiteMessage = "Ready: \(cachedBookCount) books stored on this iPhone."
    }

    private static func addedMessage(_ payloads: [ConvertedBookPayload]) -> String {
        if let only = payloads.first, payloads.count == 1 {
            return "\(only.title) was converted on this iPhone and added to its e-reader website."
        }
        return "\(payloads.count) books were processed on this iPhone and added to its e-reader website."
    }
}

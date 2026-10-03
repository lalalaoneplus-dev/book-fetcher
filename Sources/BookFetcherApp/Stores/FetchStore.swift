import AppKit
import Foundation
import BookFetcherCore
import Network

private enum PDFPivotSummaryLaunchError: LocalizedError {
    case appMissing

    var errorDescription: String? {
        "Install PDFPivot in /Applications before starting a book summary."
    }
}

@MainActor
final class FetchStore: ObservableObject {
    @Published var urlText = ""
    @Published private(set) var state: TransferState = .idle
    @Published private(set) var history: [ImportRecord] = []
    @Published private(set) var isRepairingCovers = false
    @Published private(set) var coverRepairMessage = "Checks for missing thumbnails without replacing valid covers."
    @Published private(set) var lanWebsiteMessage = "Starting the e-reader LAN website…"
    @Published private(set) var isLANWebsiteRunning = false
    @Published private(set) var calibreMissing = !FileManager.default.fileExists(atPath: "/Applications/calibre.app")
    @Published private(set) var summaryBooks: [URL] = []
    @Published var selectedSummaryBookPath = ""

    private let downloadService = DownloadService()
    private let libraryService = LibraryService()
    private let networkMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let networkMonitorQueue = DispatchQueue(
        label: "com.prakrinkumar.book-fetcher.app-network-monitor"
    )
    private var currentTask: Task<Void, Never>?
    private var websiteTask: Task<Void, Never>?
    private var networkRefreshTask: Task<Void, Never>?
    private var websiteRecheckRequested = false

    init() {
        networkMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleLANWebsiteRefresh()
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
        refreshSummaryBooks()
    }

    func refreshSummaryBooks() {
        summaryBooks = BookSummaryService().availableLibraryBooks()
        if !summaryBooks.contains(where: { $0.path == selectedSummaryBookPath }) {
            selectedSummaryBookPath = summaryBooks.first?.path ?? ""
        }
    }

    func summarizeSelectedLibraryBook() {
        guard let url = summaryBooks.first(where: { $0.path == selectedSummaryBookPath }) else {
            state = .failure("No EPUB or PDF is available in the Book LAN Library.")
            return
        }
        summarizeStoredBook(url)
    }

    var isWorking: Bool { state == .downloading || state == .processing || isRepairingCovers }
    var canStart: Bool { !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isWorking }
    var usesInsecureHTTP: Bool {
        urlText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http://")
    }
    var intakeAddress: String {
        guard let address = NetworkAddressResolver.privateWiFiIPv4() else { return "Wi-Fi unavailable" }
        return "http://\(address):\(AppConfiguration.intakePort)"
    }
    var pairingToken: String {
        (try? String(contentsOf: AppConfiguration.intakeToken, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Install the LAN helper first"
    }

    func pasteURL() {
        if let value = NSPasteboard.general.string(forType: .string) {
            urlText = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func copyIntakeAddress() { copy(intakeAddress) }
    func copyPairingToken() { copy(pairingToken) }

    func ensureLANWebsiteRunning() {
        guard websiteTask == nil else {
            websiteRecheckRequested = true
            return
        }
        isLANWebsiteRunning = false
        lanWebsiteMessage = "Starting the e-reader LAN website…"

        websiteTask = Task { [weak self] in
            do {
                let address = try await Task.detached(priority: .userInitiated) {
                    guard let resources = Bundle.main.resourceURL else {
                        throw AppSetupError.missingResource("Resources")
                    }
                    try AppSetupService(paths: AppSetupPaths(
                        resources: resources,
                        home: FileManager.default.homeDirectoryForCurrentUser
                    )).install()
                    guard FileManager.default.fileExists(atPath: "/Applications/calibre.app") else {
                        return "Install Calibre from https://calibre-ebook.com/download_osx to use the library."
                    }
                    return try LANWebsiteService().startIfNeeded()
                }.value
                let calibreMissing = !FileManager.default.fileExists(atPath: "/Applications/calibre.app")
                self?.calibreMissing = calibreMissing
                self?.isLANWebsiteRunning = !calibreMissing
                self?.lanWebsiteMessage = address
            } catch is CancellationError {
                self?.lanWebsiteMessage = "e-reader LAN website start cancelled."
            } catch {
                self?.isLANWebsiteRunning = false
                self?.lanWebsiteMessage = error.localizedDescription
            }
            let shouldRecheck = self?.websiteRecheckRequested ?? false
            self?.websiteRecheckRequested = false
            self?.websiteTask = nil
            if shouldRecheck {
                self?.scheduleLANWebsiteRefresh()
            }
        }
    }

    private func scheduleLANWebsiteRefresh() {
        networkRefreshTask?.cancel()
        networkRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.networkRefreshTask = nil
            self?.ensureLANWebsiteRunning()
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func clear() {
        guard !isWorking else { return }
        urlText = ""
        state = .idle
    }

    func start() {
        guard canStart else { return }
        let input = urlText
        let downloader = downloadService
        let importer = libraryService
        state = .downloading

        currentTask = Task { [weak self] in
            do {
                let sourceURL = try DownloadService.validatedURL(from: input)
                let downloaded = try await downloader.download(from: sourceURL)
                try Task.checkCancellation()
                self?.state = .processing
                let report = try await Task.detached(priority: .userInitiated) {
                    try importer.importBooks(downloaded)
                }.value
                try Task.checkCancellation()
                self?.history.insert(contentsOf: report.records, at: 0)
                self?.state = .success(report.message)
            } catch is CancellationError {
                self?.state = .idle
            } catch {
                self?.state = .failure(error.localizedDescription)
            }
            self?.currentTask = nil
        }
    }

    func importStoredFiles(_ urls: [URL]) {
        guard !urls.isEmpty, !isWorking else { return }
        state = .processing
        let grantedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }

        currentTask = Task { [weak self] in
            defer { grantedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    let stager = StoredBookService()
                    let importer = LibraryService()
                    var records: [ImportRecord] = []
                    var skipped: [String] = []
                    var failed: [String] = []

                    for url in urls {
                        do {
                            let staged = try stager.stage(url)
                            let result = try importer.importBooks(staged)
                            records.append(contentsOf: result.records)
                            skipped.append(contentsOf: result.skippedFiles)
                            failed.append(contentsOf: result.failedFiles)
                        } catch {
                            failed.append("\(url.lastPathComponent): \(error.localizedDescription)")
                        }
                    }

                    guard !records.isEmpty else {
                        throw LibraryServiceError.batchImportFailed(
                            failed.first ?? "No selected books could be imported."
                        )
                    }
                    return BookImportReport(records: records, skippedFiles: skipped, failedFiles: failed)
                }.value
                try Task.checkCancellation()
                self?.history.insert(contentsOf: report.records, at: 0)
                self?.state = .success(report.message)
            } catch is CancellationError {
                self?.state = .idle
            } catch {
                self?.state = .failure(error.localizedDescription)
            }
            self?.currentTask = nil
        }
    }

    func summarizeStoredBook(_ url: URL) {
        guard !isWorking else { return }
        state = .processing
        let granted = url.startAccessingSecurityScopedResource()

        currentTask = Task { [weak self] in
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            do {
                let pdfURL = try await Task.detached(priority: .userInitiated) {
                    try BookSummaryService().preparePDF(from: url)
                }.value
                try Task.checkCancellation()
                try await self?.openSummaryInPDFPivot(pdfURL)
                self?.state = .success("Opened \(pdfURL.lastPathComponent) in PDFPivot and started its AI Summary.")
            } catch is CancellationError {
                self?.state = .idle
            } catch {
                self?.state = .failure(error.localizedDescription)
            }
            self?.currentTask = nil
        }
    }

    private func openSummaryInPDFPivot(_ pdfURL: URL) async throws {
        let appURL = URL(fileURLWithPath: "/Applications/PDFPivot.app")
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw PDFPivotSummaryLaunchError.appMissing
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--run-ai-summary"]

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open(
                [pdfURL],
                withApplicationAt: appURL,
                configuration: configuration
            ) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func reportFileSelectionError(_ error: Error) {
        guard !isWorking else { return }
        state = .failure(error.localizedDescription)
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        state = .idle
    }

    func repairCovers() {
        guard !isWorking else { return }
        isRepairingCovers = true
        coverRepairMessage = "Checking Calibre and matching missing covers…"
        let importer = libraryService

        currentTask = Task { [weak self] in
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try importer.repairMissingCovers()
                }.value
                self?.coverRepairMessage = report.message
            } catch is CancellationError {
                self?.coverRepairMessage = "Cover repair cancelled."
            } catch {
                self?.coverRepairMessage = error.localizedDescription
            }
            self?.isRepairingCovers = false
            self?.currentTask = nil
        }
    }

    func openDownloadsFolder() {
        try? FileManager.default.createDirectory(at: AppConfiguration.downloadsRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(AppConfiguration.downloadsRoot)
    }

    func openLANLibrary() {
        guard let address = NetworkAddressResolver.privateWiFiIPv4(),
              let url = URL(string: "http://\(address):\(AppConfiguration.intakePort)/") else {
            state = .failure("The Mac does not currently have a private Wi-Fi address.")
            return
        }
        NSWorkspace.shared.open(url)
    }
}

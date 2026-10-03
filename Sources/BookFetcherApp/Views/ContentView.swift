import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var store: FetchStore
    @FocusState private var urlFieldFocused: Bool
    @State private var isChoosingStoredBooks = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            urlComposer
            storedBooksCard
            summaryCard
            StatusView(state: store.state)
            coverRepairCard
            pairingCard
            if !store.history.isEmpty { ImportHistoryView(records: store.history) }
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 610)
        .onAppear {
            urlFieldFocused = true
            store.ensureLANWebsiteRunning()
        }
        .fileImporter(
            isPresented: $isChoosingStoredBooks,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): store.importStoredFiles(urls)
            case .failure(let error): store.reportFileSelectionError(error)
            }
        }
    }

    private var storedBooksCard: some View {
        GroupBox("Books already on this Mac") {
            HStack(spacing: 12) {
                Image(systemName: "folder.badge.plus")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Browse stored books").font(.headline)
                    Text("Choose individual books or ZIP bundles and add them to the local e-reader website.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose Books…", systemImage: "folder") {
                    isChoosingStoredBooks = true
                }
                .disabled(store.isWorking)
            }
            .padding(6)
        }
    }

    private var summaryCard: some View {
        GroupBox("Summarize a book in PDFPivot") {
            HStack(spacing: 12) {
                Image(systemName: "text.book.closed")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Library book → PDF → AI Summary").font(.headline)
                    Text("Uses a DRM-free EPUB or PDF already in this library, then opens PDFPivot and starts Summary automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Book", selection: $store.selectedSummaryBookPath) {
                    if store.summaryBooks.isEmpty {
                        Text("No EPUB or PDF books").tag("")
                    } else {
                        ForEach(store.summaryBooks, id: \.path) { url in
                            Text(url.deletingPathExtension().lastPathComponent).tag(url.path)
                        }
                    }
                }
                .labelsHidden()
                .frame(width: 220)
                Button("Convert & Summarize", systemImage: "sparkles") {
                    store.summarizeSelectedLibraryBook()
                }
                .disabled(store.summaryBooks.isEmpty || store.isWorking)
            }
            .padding(6)
        }
    }

    private var coverRepairCard: some View {
        GroupBox("Cover thumbnails") {
            HStack(spacing: 12) {
                Image(systemName: "photo.badge.arrow.down")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Repair missing covers").font(.headline)
                    Text(store.coverRepairMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if store.isRepairingCovers {
                    ProgressView().controlSize(.small)
                }
                Button("Repair Covers", systemImage: "wand.and.stars") {
                    store.repairCovers()
                }
                .disabled(store.isWorking)
            }
            .padding(6)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 32)).foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text("Book Fetcher").font(.title2.weight(.semibold))
                Text("Paste a direct book link and add it to your private LAN library.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var urlComposer: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    TextField("https://website.example/book.epub", text: $store.urlText)
                        .textFieldStyle(.roundedBorder).focused($urlFieldFocused)
                        .disabled(store.isWorking).onSubmit { store.start() }
                    Button("Paste", systemImage: "doc.on.clipboard") { store.pasteURL() }
                        .disabled(store.isWorking)
                    Button("Clear") { store.clear() }
                        .disabled(store.isWorking || store.urlText.isEmpty)
                }
                if store.usesInsecureHTTP {
                    Label("This link is not encrypted. Use HTTPS when available.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Text("Calibre formats supported — TXT, EPUB, PDF, DOCX, RTF, HTML, comics and more")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if store.isWorking { Button("Cancel", role: .cancel) { store.cancel() } }
                    Button("Download & Add", systemImage: "arrow.down.doc.fill") { store.start() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!store.canStart)
                }
            }.padding(6)
        }
    }

    private var pairingCard: some View {
        GroupBox("iPhone pairing") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Mac address").foregroundStyle(.secondary)
                    Text(store.intakeAddress).textSelection(.enabled)
                    Button("Copy") { store.copyIntakeAddress() }
                }
                GridRow {
                    Text("LAN website").foregroundStyle(.secondary)
                    Label(
                        store.lanWebsiteMessage,
                        systemImage: store.isLANWebsiteRunning
                            ? "checkmark.circle.fill"
                            : "network"
                    )
                    .foregroundStyle(store.isLANWebsiteRunning ? .green : .secondary)
                    .textSelection(.enabled)
                    .gridCellColumns(2)
                }
                GridRow {
                    Text("Pairing token").foregroundStyle(.secondary)
                    Text(store.pairingToken).fontDesign(.monospaced).textSelection(.enabled)
                    Button("Copy") { store.copyPairingToken() }
                }
            }.padding(6)
        }
    }

    private var footer: some View {
        HStack {
            Button("Open Downloads", systemImage: "folder") { store.openDownloadsFolder() }
            Spacer()
            Button("Open LAN Library", systemImage: "network") { store.openLANLibrary() }
        }.buttonStyle(.link)
    }
}

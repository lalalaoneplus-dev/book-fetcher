import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var store: TransferStore
    @State private var isChoosingStoredBooks = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    EReaderSetupGuideView(store: store)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Send a Book to Your E-Reader").font(.body.bold())
                            Text("Step-by-step setup — open this each time").font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "books.vertical.fill")
                    }
                }
                if !store.eReaderStatus.isEmpty {
                    Label(store.eReaderStatus, systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
            }

            Section {
                TextField("https://website.example/book.txt", text: $store.bookURL, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .lineLimit(2...4)
                PasteButton(payloadType: String.self) { store.usePastedStrings($0) }
            } header: {
                Text("Book download link")
            } footer: {
                Text("Use a direct, DRM-free link. EPUB, HTML, TXT, Markdown and RTF convert to reflowable MOBI for an e-reader directly on this iPhone; MOBI, AZW3 and PDF are stored as-is.")
            }

            Section {
                Button {
                    Task { await store.processLinkOnIPhone() }
                } label: {
                    HStack {
                        Spacer()
                        if store.isConvertingOnDevice {
                            ProgressView().padding(.trailing, 6)
                            Text("Converting on iPhone…")
                        } else {
                            Label("Download & Convert on iPhone", systemImage: "iphone.and.arrow.forward.inward")
                        }
                        Spacer()
                    }
                }
                .disabled(!store.canProcessOnIPhone)
            }

            Section {
                Button {
                    isChoosingStoredBooks = true
                } label: {
                    HStack {
                        Spacer()
                        if store.isConvertingOnDevice || store.isUploadingFiles {
                            ProgressView().padding(.trailing, 6)
                            Text(store.uploadProgress)
                                .lineLimit(1)
                        } else {
                            Label("Browse Stored Books", systemImage: "folder.badge.plus")
                        }
                        Spacer()
                    }
                }
                .disabled(!store.canBrowseStoredBooks)
            } header: {
                Text("Books on this iPhone")
            } footer: {
                Text("Choose one or more book files or ZIP bundles. Supported books are unpacked, converted, and stored entirely on this iPhone.")
            }

            Section("Optional Mac fallback") {
                TextField("http://192.168.1.10:8090", text: $store.serverAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("Pairing token", text: $store.pairingToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await store.send() }
                } label: {
                    if store.state == .sending {
                        Label("Sending to Mac…", systemImage: "desktopcomputer")
                    } else {
                        Label("Use Mac Converter for This Link", systemImage: "desktopcomputer")
                    }
                }
                .disabled(!store.canSend)
            }

            Section {
                Button {
                    Task { await store.repairCovers() }
                } label: {
                    HStack {
                        Spacer()
                        if store.isRepairingCovers {
                            ProgressView().padding(.trailing, 6)
                            Text("Repairing thumbnails…")
                        } else {
                            Label("Repair Missing Thumbnails", systemImage: "photo.badge.checkmark")
                        }
                        Spacer()
                    }
                }
                .disabled(!store.canRepairCovers)
            } header: {
                Text("Cover thumbnails")
            } footer: {
                Text("Checks the Mac library, preserves valid covers, and repairs only missing artwork.")
            }

            Section {
                LabeledContent("Cached books", value: String(store.cachedBookCount))
                if let synced = store.lastLibrarySync {
                    LabeledContent("Last sync", value: synced.formatted(date: .abbreviated, time: .shortened))
                }
                if !store.websiteAddress.isEmpty {
                    LabeledContent("E-Reader Address") {
                        Text(store.websiteAddress)
                            .fontDesign(.monospaced)
                            .textSelection(.enabled)
                    }
                }
                Text(store.websiteMessage)
                    .font(.footnote)
                    .foregroundStyle(store.isServingWebsite ? .green : .secondary)

                Button {
                    Task { await store.syncLibraryToIPhone() }
                } label: {
                    if store.isSyncingLibrary {
                        Label("Syncing Mac Library…", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("Sync Converted Books from Mac", systemImage: "arrow.down.circle")
                    }
                }
                .disabled(!store.canSyncLibrary)

                Button {
                    store.isServingWebsite ? store.stopWebsite() : store.startWebsite()
                } label: {
                    if store.isStartingWebsite {
                        Label("Starting E-Reader Website…", systemImage: "network")
                    } else {
                        Label(
                            store.isServingWebsite ? "Stop E-Reader Website" : "Start E-Reader Website",
                            systemImage: store.isServingWebsite ? "stop.circle.fill" : "network"
                        )
                    }
                }
                .disabled(store.isStartingWebsite || (!store.isServingWebsite && !store.canStartWebsite))
            } header: {
                Text("E-Reader Website on This iPhone")
            } footer: {
                Text("Easiest setup: turn on Personal Hotspot, then open “Send a Book to Your E-Reader” above for step-by-step help. Keep Book Fetcher visible; iOS stops the website when the app is in the background.")
            }

            statusSection
        }
        .navigationTitle("Book Fetcher")
        .onAppear {
            if scenePhase == .active {
                store.startWebsite()
            }
        }
        .fileImporter(
            isPresented: $isChoosingStoredBooks,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await store.processStoredBooksOnIPhone(urls) }
            case .failure(let error):
                store.showFileSelectionError(error)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.startWebsite()
            } else if store.isServingWebsite || store.isStartingWebsite {
                store.stopWebsite()
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch store.state {
        case .idle, .sending:
            EmptyView()
        case .success(let message):
            Section { Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
        case .failure(let message):
            Section { Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
        }
    }
}

#Preview {
    NavigationStack { ContentView(store: TransferStore()) }
}

import BookFetcherCore
import SwiftUI

struct StatusView: View {
    let state: TransferState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .downloading:
            Label("Downloading and validating the book…", systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
        case .processing:
            Label("Converting and adding it to Calibre…", systemImage: "books.vertical")
                .foregroundStyle(.secondary)
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }
}

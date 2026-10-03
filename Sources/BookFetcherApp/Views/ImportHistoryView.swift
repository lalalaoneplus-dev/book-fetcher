import BookFetcherCore
import SwiftUI

struct ImportHistoryView: View {
    let records: [ImportRecord]

    var body: some View {
        GroupBox("This session") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(records.prefix(5)) { record in
                    HStack {
                        Image(systemName: "book.closed.fill")
                        Text(record.title).lineLimit(1)
                        Spacer()
                        Text(record.format.displayName).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(4)
        }
    }
}

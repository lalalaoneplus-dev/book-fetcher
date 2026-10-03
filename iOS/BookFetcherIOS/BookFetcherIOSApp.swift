import SwiftUI

@main
struct BookFetcherIOSApp: App {
    @State private var store = TransferStore()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ContentView(store: store)
            }
        }
    }
}

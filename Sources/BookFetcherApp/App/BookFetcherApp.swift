import AppKit
import SwiftUI

@main
struct BookFetcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = FetchStore()

    var body: some Scene {
        WindowGroup("Book Fetcher", id: "main") {
            ContentView(store: store)
        }
        .defaultSize(width: 680, height: 580)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

import SwiftUI

/// Step-by-step "get a book onto your e-reader" walkthrough with a live status card.
/// Assume a total beginner is following it on both devices, every time.
struct EReaderSetupGuideView: View {
    @Bindable var store: TransferStore
    /// Re-reads the (non-observable) network state on a timer and auto-starts serving.
    @State private var tick = 0
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var network: WiFiAddressResolver.Resolved? { _ = tick; return store.detectedNetwork }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                statusCard
                stepGroup(
                    title: "On your iPhone",
                    systemImage: "iphone",
                    steps: iPhoneSteps
                )
                stepGroup(
                    title: "On Your E-Reader",
                    systemImage: "book.closed",
                    steps: eReaderSteps
                )
                tips
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Send to an E-Reader")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(timer) { _ in
            tick &+= 1
            store.refreshServing()
        }
    }

    // MARK: - Live status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusRow(
                ok: store.cachedBookCount > 0,
                okText: "\(store.cachedBookCount) book\(store.cachedBookCount == 1 ? "" : "s") ready to send",
                badText: "No books yet — add one on the main screen first"
            )
            statusRow(
                ok: network?.mode == .hotspot,
                okText: network?.mode == .hotspot ? "Personal Hotspot is ON" : "On Wi-Fi — Personal Hotspot works best",
                badText: "Personal Hotspot is OFF — turn it on in Settings",
                warn: network?.mode == .wifi
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("Type this on your e-reader")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(store.isServingWebsite ? store.websiteAddress : "http://\(WiFiAddressResolver.hotspotIP)")
                    .font(.system(.title2, design: .monospaced).bold())
                    .foregroundStyle(store.isHotspotServing ? Color.green : Color.primary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }

            Divider()

            Label(
                store.eReaderStatus.isEmpty
                    ? (store.isServingWebsite ? "Waiting for your e-reader…" : "Start Personal Hotspot to begin")
                    : store.eReaderStatus,
                systemImage: store.eReaderStatus.isEmpty ? "dot.radiowaves.left.and.right" : "checkmark.seal.fill"
            )
            .font(.callout.bold())
            .foregroundStyle(store.eReaderStatus.isEmpty ? Color.secondary : Color.green)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func statusRow(ok: Bool, okText: String, badText: String, warn: Bool = false) -> some View {
        let color: Color = ok ? .green : (warn ? .orange : .red)
        let symbol = ok ? "checkmark.circle.fill" : (warn ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
        return Label(ok ? okText : badText, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(color)
    }

    // MARK: - Steps

    private func stepGroup(title: String, systemImage: String, steps: [Step]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.title3.bold())
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                StepRow(number: index + 1, step: step)
            }
        }
    }

    private var iPhoneSteps: [Step] {
        [
            Step("Add a book", "On the main screen, paste a link and tap Download & Convert, or tap Browse Stored Books."),
            Step("Turn on Personal Hotspot", "Settings ▸ Personal Hotspot ▸ Allow Others to Join. Turn ON Maximize Compatibility so an older e-reader can see it. Note the Wi-Fi password shown there."),
            Step("Keep cellular data on", "The e-reader browser refuses a network with no internet, so leave mobile data on. Your book still transfers locally — it doesn’t use up data."),
            Step("Come back here and wait", "Keep Book Fetcher open on this screen. The address above turns green and says “Waiting for your e-reader…”."),
        ]
    }

    private var eReaderSteps: [Step] {
        [
            Step("Join the hotspot", "On the e-reader: Settings ▸ Wi-Fi ▸ pick your iPhone’s hotspot ▸ type the password once. The e-reader remembers it next time."),
            Step("Open the Web Browser", "From the e-reader menu (⋮) choose Web Browser (also called the Experimental Browser)."),
            Step("Go to the address", "Type the address shown at the top of this screen (usually \(WiFiAddressResolver.hotspotIP)) into the e-reader’s address bar — no “https”. Only the first time."),
            Step("Bookmark the page", "When your library appears, use the menu ▸ Bookmark this page. Next time it’s one tap — no typing."),
            Step("Tap Download", "Tap Download under the book you want. It saves to the e-reader and shows up in your Library."),
        ]
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("If it doesn’t connect", systemImage: "lightbulb")
                .font(.headline)
            tip("Keep this app open and the screen on — iPhone stops the website when the app is in the background.")
            tip("On the iPhone, open Settings ▸ Personal Hotspot and leave that screen up for a moment so the hotspot starts broadcasting.")
            tip("Turn on Maximize Compatibility in Personal Hotspot for older e-readers.")
            tip("Make sure you typed http://\(WiFiAddressResolver.hotspotIP) — not https, and no extra numbers.")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func tip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").bold()
            Text(text)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

private struct Step {
    let title: String
    let detail: String
    init(_ title: String, _ detail: String) {
        self.title = title
        self.detail = detail
    }
}

private struct StepRow: View {
    let number: Int
    let step: Step

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title).font(.body.bold())
                Text(step.detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

#Preview {
    NavigationStack { EReaderSetupGuideView(store: TransferStore()) }
}

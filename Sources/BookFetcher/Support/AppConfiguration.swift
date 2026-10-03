import Foundation

public enum AppConfiguration {
    public static let home = FileManager.default.homeDirectoryForCurrentUser

    static let calibreApp = URL(fileURLWithPath: "/Applications/calibre.app")
    static let ebookConvert = calibreApp.appendingPathComponent("Contents/MacOS/ebook-convert")
    static let ebookMetadata = calibreApp.appendingPathComponent("Contents/MacOS/ebook-meta")
    static let calibreDatabase = calibreApp.appendingPathComponent("Contents/MacOS/calibredb")
    static let calibreDebug = calibreApp.appendingPathComponent("Contents/MacOS/calibre-debug")

    static let legacyLibrary = home.appendingPathComponent(
        "Documents/Book LAN Library",
        isDirectory: true
    )
    static let library = intakeSupport.appendingPathComponent("Calibre Library", isDirectory: true)
    static let launchAgent = home.appendingPathComponent(
        "Library/LaunchAgents/com.prakrinkumar.book-lan-server.plist"
    )
    static let launchLabel = "com.prakrinkumar.book-lan-server"

    public static let downloadsRoot = home.appendingPathComponent("Downloads/Book Fetcher", isDirectory: true)
    public static let originals = downloadsRoot.appendingPathComponent("Originals", isDirectory: true)
    public static let ready = downloadsRoot.appendingPathComponent("Ready", isDirectory: true)
    public static let summaries = downloadsRoot.appendingPathComponent("Summaries", isDirectory: true)
    public static let intakeSupport = home.appendingPathComponent(
        "Library/Application Support/Book Fetcher",
        isDirectory: true
    )
    public static let intakeToken = intakeSupport.appendingPathComponent("intake-token")
    public static let intakeLaunchAgent = home.appendingPathComponent(
        "Library/LaunchAgents/com.prakrinkumar.book-fetcher-intake.plist"
    )
    public static let intakeLaunchLabel = "com.prakrinkumar.book-fetcher-intake"
    public static let intakePort: UInt16 = 8090
    public static let calibreLibraryID = "Calibre_Library"
}

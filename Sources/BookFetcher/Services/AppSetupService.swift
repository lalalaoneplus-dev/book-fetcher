import Darwin
import Foundation
import Security

public struct AppSetupPaths: Sendable {
    public let resources: URL
    public let home: URL
    let calibreDatabase: URL

    public init(resources: URL, home: URL) {
        self.init(resources: resources, home: home, calibreDatabase: AppConfiguration.calibreDatabase)
    }

    init(resources: URL, home: URL, calibreDatabase: URL) {
        self.resources = resources
        self.home = home
        self.calibreDatabase = calibreDatabase
    }

    var support: URL { home.appendingPathComponent("Library/Application Support/Book Fetcher") }
    var logs: URL { home.appendingPathComponent("Library/Logs/Book Fetcher") }
    var calibreLogs: URL { home.appendingPathComponent("Library/Logs/Book LAN Server") }
    var calibreSupport: URL { support.appendingPathComponent("Calibre Server") }
    var agents: URL { home.appendingPathComponent("Library/LaunchAgents") }
    var token: URL { support.appendingPathComponent("intake-token") }
    var server: URL { support.appendingPathComponent("BookFetcherServer") }
    var html: URL { support.appendingPathComponent("book-library.html") }
    var intakeWrapper: URL { support.appendingPathComponent("start-intake.sh") }
    var calibreWrapper: URL { calibreSupport.appendingPathComponent("start-calibre-lan.sh") }
    var library: URL { support.appendingPathComponent("Calibre Library") }
    var legacyLibrary: URL { home.appendingPathComponent("Documents/Book LAN Library") }
    var intakePlist: URL { agents.appendingPathComponent("\(AppConfiguration.intakeLaunchLabel).plist") }
    var calibrePlist: URL { agents.appendingPathComponent("\(AppConfiguration.launchLabel).plist") }
}

public enum AppSetupError: LocalizedError {
    case missingResource(String)
    case randomFailure
    case launchFailure(String)
    case libraryInitializationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingResource(let name): return "The app bundle is missing \(name). Reinstall Book Fetcher."
        case .randomFailure: return "Could not create the LAN pairing token."
        case .launchFailure(let detail): return "Could not start a LAN helper: \(detail)"
        case .libraryInitializationFailed(let detail): return "Could not create the Calibre library: \(detail)"
        }
    }
}

public struct AppSetupService: Sendable {
    private let paths: AppSetupPaths
    private let runner: any SetupProcessRunning
    private var fileManager: FileManager { .default }

    public init(paths: AppSetupPaths) {
        self.paths = paths
        self.runner = ProcessRunner()
    }

    init(paths: AppSetupPaths, runner: any SetupProcessRunning) {
        self.paths = paths
        self.runner = runner
    }

    public func install() throws {
        for directory in [paths.support, paths.logs, paths.calibreLogs, paths.calibreSupport, paths.agents] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let tokenChanged = try ensureToken()
        try migrateLibraryIfAvailable()
        let calibreAvailable = fileManager.isExecutableFile(atPath: paths.calibreDatabase.path)
        if calibreAvailable {
            try ensureLibrary()
        }
        let serverChanged = try copyResource("BookFetcherServer", to: paths.server, permissions: 0o700)
        let htmlChanged = try copyResource("book-library.html", to: paths.html, permissions: 0o600)
        let intakeWrapperChanged = try copyResource("start-intake.sh", to: paths.intakeWrapper, permissions: 0o700)

        let calibreTemplate = try resourceString("start-calibre-lan.sh")
        let calibreWrapper = substitute(calibreTemplate, [
            "__LIBRARY_PATH__": shellQuotedContent(paths.library.path),
            "__SERVER_LOG__": shellQuotedContent(paths.calibreLogs.appendingPathComponent("server.log").path),
            "__ACCESS_LOG__": shellQuotedContent(paths.calibreLogs.appendingPathComponent("access.log").path)
        ])
        let calibreWrapperChanged = try writeIfDifferent(Data(calibreWrapper.utf8), to: paths.calibreWrapper, permissions: 0o700)

        let intakePlistChanged = try writePlist(
            "intake-launch-agent.plist", to: paths.intakePlist,
            wrapper: paths.intakeWrapper, logs: paths.logs
        )
        let calibrePlistChanged = try writePlist(
            "calibre-launch-agent.plist", to: paths.calibrePlist,
            wrapper: paths.calibreWrapper, logs: paths.calibreLogs
        )

        if calibreAvailable {
            try ensureAgent(
                label: AppConfiguration.launchLabel, plist: paths.calibrePlist,
                changed: calibreWrapperChanged || calibrePlistChanged
            )
        }
        try ensureAgent(
            label: AppConfiguration.intakeLaunchLabel, plist: paths.intakePlist,
            changed: tokenChanged || serverChanged || htmlChanged || intakeWrapperChanged || intakePlistChanged
        )
    }

    private func resourceData(_ name: String) throws -> Data {
        let url = paths.resources.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: url.path) else { throw AppSetupError.missingResource(name) }
        return try Data(contentsOf: url)
    }

    private func resourceString(_ name: String) throws -> String {
        let data = try resourceData(name)
        guard let string = String(data: data, encoding: .utf8) else { throw AppSetupError.missingResource(name) }
        return string
    }

    private func copyResource(_ name: String, to destination: URL, permissions: Int) throws -> Bool {
        try writeIfDifferent(resourceData(name), to: destination, permissions: permissions)
    }

    private func writeIfDifferent(_ data: Data, to destination: URL, permissions: Int) throws -> Bool {
        let changed = (try? Data(contentsOf: destination)) != data
        if changed { try data.write(to: destination, options: .atomic) }
        let currentMode = (try? fileManager.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)?.intValue
        if currentMode != permissions {
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path)
        }
        return changed || currentMode != permissions
    }

    private func ensureToken() throws -> Bool {
        guard !fileManager.fileExists(atPath: paths.token.path) else { return false }
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AppSetupError.randomFailure
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined() + "\n"
        try Data(token.utf8).write(to: paths.token, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.token.path)
        return true
    }

    private func migrateLibraryIfAvailable() throws {
        guard !fileManager.fileExists(atPath: paths.library.path) else { return }
        guard fileManager.fileExists(atPath: paths.legacyLibrary.appendingPathComponent("metadata.db").path) else { return }
        try fileManager.copyItem(at: paths.legacyLibrary, to: paths.library)
    }

    private func ensureLibrary() throws {
        let metadata = paths.library.appendingPathComponent("metadata.db")
        guard !fileManager.fileExists(atPath: metadata.path) else { return }
        let result = try runner.run(
            executable: paths.calibreDatabase.path,
            arguments: ["list", "--with-library", paths.library.path],
            allowFailure: true
        )
        guard result.terminationStatus == 0, fileManager.fileExists(atPath: metadata.path) else {
            throw AppSetupError.libraryInitializationFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func writePlist(_ name: String, to destination: URL, wrapper: URL, logs: URL) throws -> Bool {
        let template = try resourceString(name)
        let contents = substitute(template, [
            "__WRAPPER_PATH__": xmlEscaped(wrapper.path),
            "__STDOUT_PATH__": xmlEscaped(logs.appendingPathComponent(name.hasPrefix("intake") ? "intake-stdout.log" : "stdout.log").path),
            "__STDERR_PATH__": xmlEscaped(logs.appendingPathComponent(name.hasPrefix("intake") ? "intake-stderr.log" : "stderr.log").path)
        ])
        return try writeIfDifferent(Data(contents.utf8), to: destination, permissions: 0o600)
    }

    private func substitute(_ template: String, _ values: [String: String]) -> String {
        values.reduce(template) { result, pair in result.replacingOccurrences(of: pair.key, with: pair.value) }
    }

    private func xmlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func shellQuotedContent(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    private func ensureAgent(label: String, plist: URL, changed: Bool) throws {
        let userDomain = "gui/\(getuid())"
        let serviceDomain = "\(userDomain)/\(label)"
        let status = try runner.run(executable: "/bin/launchctl", arguments: ["print", serviceDomain], allowFailure: true)
        guard changed || status.terminationStatus != 0 else { return }
        if status.terminationStatus == 0 {
            _ = try runner.run(executable: "/bin/launchctl", arguments: ["bootout", serviceDomain], allowFailure: true)
        }
        let result = try runner.run(executable: "/bin/launchctl", arguments: ["bootstrap", userDomain, plist.path], allowFailure: true)
        guard result.terminationStatus == 0 else { throw AppSetupError.launchFailure(result.output) }
        _ = try runner.run(executable: "/bin/launchctl", arguments: ["enable", serviceDomain], allowFailure: true)
    }
}

import Darwin
import Foundation

public enum LANWebsiteServiceError: LocalizedError {
    case helperMissing
    case startFailed(String)

    public var errorDescription: String? {
        switch self {
        case .helperMissing:
            return "Install the LAN helper once to enable the e-reader website."
        case .startFailed(let detail):
            return detail.isEmpty
                ? "The e-reader LAN website could not be started."
                : "The e-reader LAN website could not be started: \(detail)"
        }
    }
}

public struct LANWebsiteService: Sendable {
    private let runner = ProcessRunner()

    public init() {}

    @discardableResult
    public func startIfNeeded() throws -> String {
        let userDomain = "gui/\(getuid())"
        let address = try ensureCalibreLibraryRunning()

        guard FileManager.default.fileExists(atPath: AppConfiguration.intakeLaunchAgent.path) else {
            throw LANWebsiteServiceError.helperMissing
        }
        try ensureService(
            label: AppConfiguration.intakeLaunchLabel,
            launchAgent: AppConfiguration.intakeLaunchAgent,
            userDomain: userDomain,
            address: address,
            port: AppConfiguration.intakePort,
            name: "e-reader LAN website"
        )

        if let address {
            return "http://\(address):\(AppConfiguration.intakePort)"
        }
        return "Running; connect this Mac to private Wi-Fi to get its address."
    }

    @discardableResult
    public func ensureCalibreLibraryRunning() throws -> String? {
        try ensureLocalLibrary()
        guard let address = NetworkAddressResolver.privateWiFiIPv4() else {
            return nil
        }
        try ensureService(
            label: AppConfiguration.launchLabel,
            launchAgent: AppConfiguration.launchAgent,
            userDomain: "gui/\(getuid())",
            address: address,
            port: 8080,
            name: "Calibre LAN library"
        )
        return address
    }

    private func ensureLocalLibrary() throws {
        let metadata = AppConfiguration.library.appendingPathComponent("metadata.db")
        guard FileManager.default.fileExists(atPath: metadata.path) else {
            throw LANWebsiteServiceError.startFailed("The Calibre library could not be found.")
        }
    }

    private func ensureService(
        label: String,
        launchAgent: URL,
        userDomain: String,
        address: String?,
        port: UInt16,
        name: String
    ) throws {
        guard FileManager.default.fileExists(atPath: launchAgent.path) else {
            throw LANWebsiteServiceError.startFailed("\(name) configuration is missing.")
        }

        let serviceDomain = "\(userDomain)/\(label)"
        var status = try serviceStatus(serviceDomain)
        if status.terminationStatus == 0,
           Self.isRunning(status.output),
           address.map({ portAcceptsConnections(address: $0, port: port) }) ?? true {
            return
        }

        if status.terminationStatus == 0 {
            let restart = try runner.run(
                executable: "/bin/launchctl",
                arguments: ["kickstart", "-k", serviceDomain],
                allowFailure: true
            )
            guard restart.terminationStatus == 0 else {
                throw LANWebsiteServiceError.startFailed(
                    "\(name): \(restart.output.trimmingCharacters(in: .whitespacesAndNewlines))"
                )
            }
        } else {
            let bootstrap = try runner.run(
                executable: "/bin/launchctl",
                arguments: ["bootstrap", userDomain, launchAgent.path],
                allowFailure: true
            )
            guard bootstrap.terminationStatus == 0 else {
                throw LANWebsiteServiceError.startFailed(
                    "\(name): \(bootstrap.output.trimmingCharacters(in: .whitespacesAndNewlines))"
                )
            }
            _ = try runner.run(
                executable: "/bin/launchctl",
                arguments: ["enable", serviceDomain],
                allowFailure: true
            )
        }

        for _ in 0..<60 {
            status = try serviceStatus(serviceDomain)
            let portIsReady = address.map {
                portAcceptsConnections(address: $0, port: port)
            } ?? true
            if status.terminationStatus == 0, Self.isRunning(status.output), portIsReady {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw LANWebsiteServiceError.startFailed(
            "\(name) did not become reachable on port \(port)."
        )
    }

    private func portAcceptsConnections(address: String, port: UInt16) -> Bool {
        let result = try? runner.run(
            executable: "/usr/bin/nc",
            arguments: ["-z", "-w", "1", address, String(port)],
            allowFailure: true
        )
        return result?.terminationStatus == 0
    }

    private func serviceStatus(_ serviceDomain: String) throws -> ProcessResult {
        try runner.run(
            executable: "/bin/launchctl",
            arguments: ["print", serviceDomain],
            allowFailure: true
        )
    }

    private static func isRunning(_ output: String) -> Bool {
        output.range(
            of: #"(?m)^\s*state = running\s*$"#,
            options: .regularExpression
        ) != nil
    }
}

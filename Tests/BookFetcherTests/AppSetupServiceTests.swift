import Foundation
import XCTest
@testable import BookFetcherCore

private final class FakeSetupRunner: SetupProcessRunning, @unchecked Sendable {
    struct Command {
        let executable: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private var loaded = Set<String>()
    private(set) var commands: [Command] = []
    var createMetadata = true

    func run(executable: String, arguments: [String], allowFailure: Bool) throws -> ProcessResult {
        lock.lock()
        defer { lock.unlock() }
        commands.append(Command(executable: executable, arguments: arguments))
        if arguments.first == "list" {
            XCTAssertEqual(arguments.count, 3)
            XCTAssertEqual(arguments[1], "--with-library")
            if createMetadata {
                let library = URL(fileURLWithPath: arguments[2])
                try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
                try Data("empty-library".utf8).write(to: library.appendingPathComponent("metadata.db"))
            }
            return ProcessResult(terminationStatus: 0, output: "")
        }
        XCTAssertEqual(executable, "/bin/launchctl")
        switch arguments[0] {
        case "print": return ProcessResult(terminationStatus: loaded.contains(arguments[1]) ? 0 : 113, output: "")
        case "bootout": loaded.remove(arguments[1])
        case "bootstrap":
            let label = URL(fileURLWithPath: arguments[2]).deletingPathExtension().lastPathComponent
            loaded.insert("\(arguments[1])/\(label)")
        default: break
        }
        return ProcessResult(terminationStatus: 0, output: "")
    }

    func clearCommands() {
        lock.lock()
        commands.removeAll()
        lock.unlock()
    }
}

final class AppSetupServiceTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let paths: AppSetupPaths
        let runner = FakeSetupRunner()

        init() throws {
            let manager = FileManager.default
            root = manager.temporaryDirectory.appendingPathComponent("setup-\(UUID().uuidString)")
            let resources = root.appendingPathComponent("bundle")
            paths = AppSetupPaths(
                resources: resources,
                home: root.appendingPathComponent("home"),
                calibreDatabase: root.appendingPathComponent("tools/calibredb")
            )
            try manager.createDirectory(at: resources, withIntermediateDirectories: true)
            let sourceResources = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources")
            for name in ["book-library.html", "start-intake.sh", "start-calibre-lan.sh", "intake-launch-agent.plist", "calibre-launch-agent.plist"] {
                try manager.copyItem(at: sourceResources.appendingPathComponent(name), to: resources.appendingPathComponent(name))
            }
            try Data("helper".utf8).write(to: resources.appendingPathComponent("BookFetcherServer"))
        }

        func installCalibre() throws {
            let manager = FileManager.default
            try manager.createDirectory(at: paths.calibreDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: paths.calibreDatabase)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.calibreDatabase.path)
        }

        func library(at url: URL, contents: String) throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url.appendingPathComponent("metadata.db"))
        }

        func install() throws {
            try AppSetupService(paths: paths, runner: runner).install()
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    func testMigrationIgnoresOtherLibraries() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let paths = fixture.paths
        try fixture.installCalibre()
        try fixture.library(at: paths.home.appendingPathComponent("Documents/Other Library"), contents: "documents")
        try fixture.library(at: paths.home.appendingPathComponent("Library/Application Support/Other App/Calibre Library"), contents: "support")

        try fixture.install()

        XCTAssertEqual(try String(contentsOf: paths.library.appendingPathComponent("metadata.db"), encoding: .utf8), "empty-library")
        XCTAssertEqual(fixture.runner.commands.filter { $0.arguments.first == "list" }.count, 1)
    }

    func testMigrationCopiesOnlyDocumentedLegacyLibrary() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.installCalibre()
        try fixture.library(at: fixture.paths.legacyLibrary, contents: "legacy")
        try fixture.library(at: fixture.paths.home.appendingPathComponent("Library/Application Support/Other App/Calibre Library"), contents: "unrelated")

        try fixture.install()

        let metadata = fixture.paths.library.appendingPathComponent("metadata.db")
        XCTAssertEqual(try String(contentsOf: metadata, encoding: .utf8), "legacy")
        XCTAssertEqual(try String(contentsOf: fixture.paths.legacyLibrary.appendingPathComponent("metadata.db"), encoding: .utf8), "legacy")
        XCTAssertFalse(fixture.runner.commands.contains { $0.arguments.first == "list" })
    }

    func testFreshUserCreatesLibraryBeforeBootstrap() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.installCalibre()

        try fixture.install()

        let commands = fixture.runner.commands
        let createIndex = try XCTUnwrap(commands.firstIndex { $0.arguments.first == "list" })
        let bootstrapIndex = try XCTUnwrap(commands.firstIndex { $0.arguments.first == "bootstrap" })
        XCTAssertLessThan(createIndex, bootstrapIndex)
        XCTAssertEqual(commands[createIndex].executable, fixture.paths.calibreDatabase.path)
        XCTAssertEqual(commands[createIndex].arguments, ["list", "--with-library", fixture.paths.library.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.library.appendingPathComponent("metadata.db").path))
        XCTAssertEqual(commands.filter { $0.arguments.first == "bootstrap" }.count, 2)
    }

    func testMissingCalibreDefersOnlyItsAgentAndNextRunCompletesSetup() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.install()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.library.path))
        XCTAssertFalse(fixture.runner.commands.contains { $0.arguments.first == "list" })
        XCTAssertEqual(fixture.runner.commands.filter { $0.arguments.first == "bootstrap" }.map(\.arguments[2]), [fixture.paths.intakePlist.path])

        try fixture.installCalibre()
        fixture.runner.clearCommands()
        try fixture.install()
        XCTAssertEqual(fixture.runner.commands.filter { $0.arguments.first == "bootstrap" }.map(\.arguments[2]), [fixture.paths.calibrePlist.path])
        XCTAssertEqual(fixture.runner.commands.filter { $0.arguments.first == "list" }.count, 1)

        fixture.runner.clearCommands()
        try fixture.install()
        XCTAssertFalse(fixture.runner.commands.contains { $0.arguments.first == "list" || $0.arguments.first == "bootstrap" || $0.arguments.first == "bootout" })
        XCTAssertEqual(try String(contentsOf: fixture.paths.library.appendingPathComponent("metadata.db"), encoding: .utf8), "empty-library")
    }

    func testExistingLibraryAndTokenRemainUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.installCalibre()
        try fixture.library(at: fixture.paths.library, contents: "existing")
        try fixture.library(at: fixture.paths.legacyLibrary, contents: "legacy")
        try FileManager.default.createDirectory(at: fixture.paths.support, withIntermediateDirectories: true)
        try Data("existing-token".utf8).write(to: fixture.paths.token)

        try fixture.install()

        XCTAssertEqual(try String(contentsOf: fixture.paths.library.appendingPathComponent("metadata.db"), encoding: .utf8), "existing")
        XCTAssertEqual(try String(contentsOf: fixture.paths.token, encoding: .utf8), "existing-token")
        XCTAssertFalse(fixture.runner.commands.contains { $0.arguments.first == "list" })
    }

    func testInitializationRequiresMetadataBeforeBootstrap() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.installCalibre()
        fixture.runner.createMetadata = false

        XCTAssertThrowsError(try fixture.install())
        XCTAssertFalse(fixture.runner.commands.contains { $0.arguments.first == "bootstrap" })
    }
}

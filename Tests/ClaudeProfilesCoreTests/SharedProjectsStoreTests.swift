import Foundation
import XCTest
@testable import ClaudeProfilesCore

final class SharedProjectsStoreTests: XCTestCase {
    private let fileManager = FileManager.default

    func testLinksEmptyProjectsDirectoryToSharedStore() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let sharedConfig = root.appendingPathComponent("shared", isDirectory: true)
        let profileConfig = root.appendingPathComponent("profile", isDirectory: true)
        let profileProjects = profileConfig.appendingPathComponent("projects", isDirectory: true)
        try fileManager.createDirectory(at: profileProjects, withIntermediateDirectories: true)

        let result = try SharedProjectsStore().prepare(
            profileConfigPath: profileConfig.path,
            sharedConfigPath: sharedConfig.path,
            backupRootPath: root.appendingPathComponent("backups").path
        )

        XCTAssertEqual(result.importedFileCount, 0)
        XCTAssertNil(result.backupPath)
        XCTAssertFalse(result.wasAlreadyShared)
        XCTAssertEqual(
            try resolvedLink(at: profileProjects),
            sharedConfig.appendingPathComponent("projects").standardizedFileURL.path
        )
    }

    func testMigratesExistingHistoryAndRetainsBackup() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let sharedConfig = root.appendingPathComponent("shared", isDirectory: true)
        let sharedProjects = sharedConfig.appendingPathComponent("projects", isDirectory: true)
        let profileConfig = root.appendingPathComponent("profile", isDirectory: true)
        let profileProjects = profileConfig.appendingPathComponent("projects", isDirectory: true)
        let sharedSession = sharedProjects.appendingPathComponent("project/shared.jsonl")
        let profileSession = profileProjects.appendingPathComponent("project/profile.jsonl")
        try write("shared", to: sharedSession)
        try write("profile", to: profileSession)

        let result = try SharedProjectsStore().prepare(
            profileConfigPath: profileConfig.path,
            sharedConfigPath: sharedConfig.path,
            backupRootPath: root.appendingPathComponent("backups").path
        )

        XCTAssertEqual(result.importedFileCount, 1)
        XCTAssertNotNil(result.backupPath)
        XCTAssertEqual(try String(contentsOf: sharedSession), "shared")
        XCTAssertEqual(
            try String(contentsOf: sharedProjects.appendingPathComponent("project/profile.jsonl")),
            "profile"
        )
        XCTAssertEqual(
            try String(contentsOf: URL(fileURLWithPath: result.backupPath!)
                .appendingPathComponent("project/profile.jsonl")),
            "profile"
        )
        XCTAssertEqual(try resolvedLink(at: profileProjects), sharedProjects.path)
    }

    func testRejectsConflictWithoutMovingProfileHistory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let sharedConfig = root.appendingPathComponent("shared", isDirectory: true)
        let profileConfig = root.appendingPathComponent("profile", isDirectory: true)
        let sharedSession = sharedConfig.appendingPathComponent("projects/project/session.jsonl")
        let profileSession = profileConfig.appendingPathComponent("projects/project/session.jsonl")
        try write("shared version", to: sharedSession)
        try write("profile version", to: profileSession)

        XCTAssertThrowsError(
            try SharedProjectsStore().prepare(
                profileConfigPath: profileConfig.path,
                sharedConfigPath: sharedConfig.path,
                backupRootPath: root.appendingPathComponent("backups").path
            )
        ) { error in
            XCTAssertEqual(
                error as? SharedProjectsStoreError,
                .conflictingItem("project/session.jsonl")
            )
        }

        XCTAssertEqual(try String(contentsOf: sharedSession), "shared version")
        XCTAssertEqual(try String(contentsOf: profileSession), "profile version")
        XCTAssertEqual(
            try fileManager.attributesOfItem(atPath: profileConfig
                .appendingPathComponent("projects").path)[.type] as? FileAttributeType,
            .typeDirectory
        )
    }

    func testRecognizesExistingSharedLink() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let sharedConfig = root.appendingPathComponent("shared", isDirectory: true)
        let sharedProjects = sharedConfig.appendingPathComponent("projects", isDirectory: true)
        let profileConfig = root.appendingPathComponent("profile", isDirectory: true)
        let profileProjects = profileConfig.appendingPathComponent("projects", isDirectory: true)
        try fileManager.createDirectory(at: sharedProjects, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: profileConfig, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            atPath: profileProjects.path,
            withDestinationPath: sharedProjects.path
        )

        let result = try SharedProjectsStore().prepare(
            profileConfigPath: profileConfig.path,
            sharedConfigPath: sharedConfig.path,
            backupRootPath: root.appendingPathComponent("backups").path
        )

        XCTAssertTrue(result.wasAlreadyShared)
        XCTAssertNil(result.backupPath)
    }

    func testEmptyProfileMemoryDoesNotConflictWithSharedMemoryLink() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let sharedConfig = root.appendingPathComponent("shared", isDirectory: true)
        let sharedMemoryTarget = root.appendingPathComponent("shared-memory", isDirectory: true)
        let sharedMemory = sharedConfig.appendingPathComponent("projects/project/memory")
        let profileConfig = root.appendingPathComponent("profile", isDirectory: true)
        let profileMemory = profileConfig.appendingPathComponent("projects/project/memory")
        try fileManager.createDirectory(at: sharedMemoryTarget, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: sharedMemory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createSymbolicLink(
            atPath: sharedMemory.path,
            withDestinationPath: sharedMemoryTarget.path
        )
        try fileManager.createDirectory(at: profileMemory, withIntermediateDirectories: true)
        try write(
            "profile session",
            to: profileConfig.appendingPathComponent("projects/project/session.jsonl")
        )

        let result = try SharedProjectsStore().prepare(
            profileConfigPath: profileConfig.path,
            sharedConfigPath: sharedConfig.path,
            backupRootPath: root.appendingPathComponent("backups").path
        )

        XCTAssertEqual(result.importedFileCount, 1)
        XCTAssertEqual(
            try String(contentsOf: sharedConfig
                .appendingPathComponent("projects/project/session.jsonl")),
            "profile session"
        )
        XCTAssertEqual(
            try resolvedLink(at: profileConfig.appendingPathComponent("projects")),
            sharedConfig.appendingPathComponent("projects").path
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("SharedProjectsStoreTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ content: String, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(content.utf8).write(to: url)
    }

    private func resolvedLink(at url: URL) throws -> String {
        let destination = try fileManager.destinationOfSymbolicLink(atPath: url.path)
        return URL(fileURLWithPath: destination, isDirectory: true).standardizedFileURL.path
    }
}

// Tests for SharedHistoryStore: merging and linking `file-history/` and `history.jsonl`
// from an additional profile into the default profile's configuration directory.

import Foundation
import XCTest

@testable import ClaudeProfilesCore

internal final class SharedHistoryStoreTests: XCTestCase {
    /// Temporary profile / shared / backup layout for one test.
    private struct TestEnvironment {
        let root: URL
        let profile: URL
        let shared: URL
        let backupRoot: URL

        func prepare() throws -> SharedHistoryPreparation {
            try SharedHistoryStore().prepare(
                profileConfigPath: profile.path,
                sharedConfigPath: shared.path,
                backupRootPath: backupRoot.path
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Result of a run that had nothing to merge or back up.
    private static let unchanged: SharedHistoryPreparation = .init(
        movedSessionCount: 0,
        mergedHistoryLineCount: nil,
        backupPath: nil
    )

    private let fileManager: FileManager = .default

    /// Session folders are moved into the shared file-history and the profile gets a link.
    internal func testMovesSessionFoldersIntoSharedFileHistory() throws {
        let env: TestEnvironment = try makeEnvironment()
        defer { env.cleanUp() }
        try write("snapshot a", to: env.profile.appendingPathComponent("file-history/session-a/1@v1"))
        try write("snapshot s", to: env.shared.appendingPathComponent("file-history/session-s/1@v1"))

        let result: SharedHistoryPreparation = try env.prepare()

        XCTAssertEqual(result.movedSessionCount, 1)
        XCTAssertEqual(
            try String(contentsOf: env.shared.appendingPathComponent("file-history/session-a/1@v1")),
            "snapshot a"
        )
        let sharedSession: URL = env.shared.appendingPathComponent("file-history/session-s")
        XCTAssertTrue(fileManager.fileExists(atPath: sharedSession.path))
        try assertLinked("file-history", in: env)
        // Read through the link: the profile now sees both sessions.
        let throughLink: URL = env.profile.appendingPathComponent("file-history")
        let linkedSessions: [String] = try fileManager.contentsOfDirectory(atPath: throughLink.path).sorted()
        XCTAssertEqual(linkedSessions, ["session-a", "session-s"])
    }

    /// A session ID present on both sides keeps the shared copy; the profile's goes to backup.
    internal func testKeepsSharedSessionAndBacksUpConflictingProfileSession() throws {
        let env: TestEnvironment = try makeEnvironment()
        defer { env.cleanUp() }
        try write("profile", to: env.profile.appendingPathComponent("file-history/same/1@v1"))
        try write("shared", to: env.shared.appendingPathComponent("file-history/same/1@v1"))

        let result: SharedHistoryPreparation = try env.prepare()

        XCTAssertEqual(result.movedSessionCount, 0)
        XCTAssertEqual(try String(contentsOf: env.shared.appendingPathComponent("file-history/same/1@v1")), "shared")
        let backup: URL = try XCTUnwrap(result.backupPath.map { URL(fileURLWithPath: $0) })
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("file-history/same/1@v1")), "profile")
        XCTAssertTrue(backup.path.hasPrefix(env.backupRoot.path))
        try assertLinked("file-history", in: env)
    }

    /// history.jsonl: duplicates removed, sorted by timestamp, both originals backed up,
    /// permissions 0600, and the profile file replaced by a link.
    internal func testMergesHistoryWithoutDuplicatesInTimestampOrder() throws {
        let env: TestEnvironment = try makeEnvironment()
        defer { env.cleanUp() }
        let shared: String = """
        {"display":"s1","timestamp":100}
        {"display":"both","timestamp":300}

        """
        let profile: String = """
        {"display":"p1","timestamp":200}
        {"display":"both","timestamp":300}
        {"display":"p0","timestamp":50}

        """
        try write(shared, to: env.shared.appendingPathComponent("history.jsonl"))
        try write(profile, to: env.profile.appendingPathComponent("history.jsonl"))

        let result: SharedHistoryPreparation = try env.prepare()

        let merged: String = try String(contentsOf: env.shared.appendingPathComponent("history.jsonl"))
        XCTAssertEqual(merged, """
        {"display":"p0","timestamp":50}
        {"display":"s1","timestamp":100}
        {"display":"p1","timestamp":200}
        {"display":"both","timestamp":300}

        """)
        XCTAssertEqual(result.mergedHistoryLineCount, 4)
        let attributes: [FileAttributeKey: Any] = try fileManager.attributesOfItem(
            atPath: env.shared.appendingPathComponent("history.jsonl").path
        )
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        let backup: URL = try XCTUnwrap(result.backupPath.map { URL(fileURLWithPath: $0) })
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("history.jsonl.shared")), shared)
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("history.jsonl.profile")), profile)
        try assertLinked("history.jsonl", in: env)
    }

    /// Lines that are not JSON (or have no timestamp) are kept verbatim after sorted lines.
    internal func testKeepsBrokenAndUnstampedLinesInOriginalOrder() {
        // 0xFF is not valid UTF-8; such a line must survive byte for byte.
        var invalidUTF8: Data = .init("bad ".utf8)
        invalidUTF8.append(0xFF)
        let merged: [Data] = SharedHistoryStore.mergedHistory(
            shared: Data("not json {\n{\"timestamp\":20}\n".utf8) + invalidUTF8,
            profile: Data("{\"display\":\"no stamp\"}\n{\"timestamp\":10}\nnot json {\n".utf8)
        )

        XCTAssertEqual(merged, [
            Data("{\"timestamp\":10}".utf8),
            Data("{\"timestamp\":20}".utf8),
            Data("not json {".utf8),
            invalidUTF8,
            Data("{\"display\":\"no stamp\"}".utf8)
        ])
    }

    /// A second run changes nothing and creates no new backup.
    internal func testIsIdempotent() throws {
        let env: TestEnvironment = try makeEnvironment()
        defer { env.cleanUp() }
        try write("a", to: env.profile.appendingPathComponent("file-history/session-a/1@v1"))
        try write("{\"timestamp\":1}\n", to: env.profile.appendingPathComponent("history.jsonl"))
        _ = try env.prepare()
        let historyBefore: Data = try Data(contentsOf: env.shared.appendingPathComponent("history.jsonl"))
        let backupsBefore: [String] = try fileManager.contentsOfDirectory(atPath: env.backupRoot.path)

        let second: SharedHistoryPreparation = try env.prepare()

        XCTAssertEqual(second, Self.unchanged)
        XCTAssertEqual(try Data(contentsOf: env.shared.appendingPathComponent("history.jsonl")), historyBefore)
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: env.backupRoot.path), backupsBefore)
    }

    /// Items already linked to the shared copy are left alone; links elsewhere are refused.
    internal func testExistingLinksAreNoOpsAndForeignLinksAreRejected() throws {
        let env: TestEnvironment = try makeEnvironment()
        defer { env.cleanUp() }
        let sharedFileHistory: URL = env.shared.appendingPathComponent("file-history")
        try fileManager.createDirectory(at: sharedFileHistory, withIntermediateDirectories: true)
        try write("{\"timestamp\":1}\n", to: env.shared.appendingPathComponent("history.jsonl"))
        try fileManager.createSymbolicLink(
            at: env.profile.appendingPathComponent("file-history"),
            withDestinationURL: env.shared.appendingPathComponent("file-history")
        )
        try fileManager.createSymbolicLink(
            at: env.profile.appendingPathComponent("history.jsonl"),
            withDestinationURL: env.shared.appendingPathComponent("history.jsonl")
        )

        XCTAssertEqual(try env.prepare(), Self.unchanged)

        let elsewhere: URL = env.root.appendingPathComponent("elsewhere.jsonl")
        try write("", to: elsewhere)
        try fileManager.removeItem(at: env.profile.appendingPathComponent("history.jsonl"))
        let profileHistory: URL = env.profile.appendingPathComponent("history.jsonl")
        try fileManager.createSymbolicLink(at: profileHistory, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try env.prepare()) { error in
            XCTAssertEqual(
                error as? SharedHistoryStoreError,
                .linkPointsElsewhere(env.profile.appendingPathComponent("history.jsonl").path)
            )
        }
    }

    /// Missing or empty profile items are simply linked; the shared side is created if absent.
    internal func testEmptyOrMissingProfileItemsAreJustLinked() throws {
        let env: TestEnvironment = try makeEnvironment()
        defer { env.cleanUp() }
        let emptyFileHistory: URL = env.profile.appendingPathComponent("file-history")
        try fileManager.createDirectory(at: emptyFileHistory, withIntermediateDirectories: true)
        try write("", to: env.profile.appendingPathComponent("history.jsonl"))

        let result: SharedHistoryPreparation = try env.prepare()

        XCTAssertEqual(result, Self.unchanged)
        try assertLinked("file-history", in: env)
        try assertLinked("history.jsonl", in: env)
        XCTAssertEqual(try Data(contentsOf: env.shared.appendingPathComponent("history.jsonl")), Data())
        XCTAssertFalse(fileManager.fileExists(atPath: env.backupRoot.path))
    }

    // MARK: - Helpers

    private func makeEnvironment() throws -> TestEnvironment {
        let root: URL = fileManager.temporaryDirectory
            .appendingPathComponent("SharedHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        let env: TestEnvironment = .init(
            root: root,
            profile: root.appendingPathComponent("profile", isDirectory: true),
            shared: root.appendingPathComponent("shared", isDirectory: true),
            backupRoot: root.appendingPathComponent("backups/Shared History", isDirectory: true)
        )
        try fileManager.createDirectory(at: env.profile, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: env.shared, withIntermediateDirectories: true)
        return env
    }

    private func write(_ content: String, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    /// Asserts that `<profile>/<name>` is a symbolic link to `<shared>/<name>`.
    private func assertLinked(_ name: String, in env: TestEnvironment) throws {
        let link: String = try fileManager.destinationOfSymbolicLink(
            atPath: env.profile.appendingPathComponent(name).path
        )
        XCTAssertEqual(
            URL(fileURLWithPath: link).standardizedFileURL.path,
            env.shared.appendingPathComponent(name).standardizedFileURL.path
        )
    }
}

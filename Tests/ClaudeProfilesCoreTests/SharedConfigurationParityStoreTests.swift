import Foundation
import XCTest
@testable import ClaudeProfilesCore

final class SharedConfigurationParityStoreTests: XCTestCase {
    private let fileManager = FileManager.default

    func testLinksOnlyAllowlistedOperationalConfiguration() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared")
        let profile = root.appendingPathComponent("profile")

        for (index, name) in SharedConfigurationParityStore.sharedItemNames.enumerated() {
            if name.hasSuffix(".json") || name.hasSuffix(".md") {
                try write("shared-\(index)", to: shared.appendingPathComponent(name))
            } else {
                try write("shared-\(index)", to: shared.appendingPathComponent("\(name)/item"))
            }
        }

        let excluded = [
            ".claude.json",
            "remote-settings.json",
            "session-env",
            "sessions",
            "shell-snapshots",
            "telemetry"
        ]
        for name in excluded {
            try write("profile-only", to: profile.appendingPathComponent(name))
        }

        let result = try SharedConfigurationParityStore().prepare(
            profileConfigPath: profile.path,
            sharedConfigPath: shared.path,
            backupRootPath: root.appendingPathComponent("backups").path
        )

        XCTAssertEqual(result.linkedItems, SharedConfigurationParityStore.sharedItemNames)
        XCTAssertTrue(result.missingSharedItems.isEmpty)
        XCTAssertNil(result.backupPath)
        XCTAssertFalse(result.wasAlreadyConfigured)
        for name in SharedConfigurationParityStore.sharedItemNames {
            XCTAssertEqual(
                try resolvedLink(at: profile.appendingPathComponent(name)),
                shared.appendingPathComponent(name).standardizedFileURL.path
            )
        }
        for name in excluded {
            let item = profile.appendingPathComponent(name)
            XCTAssertEqual(try String(contentsOf: item), "profile-only")
            XCTAssertNotEqual(try itemType(at: item), .typeSymbolicLink)
        }
    }

    func testBacksUpExistingAllowlistedItemsBeforeReplacingThem() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared")
        let profile = root.appendingPathComponent("profile")
        try write("shared instructions", to: shared.appendingPathComponent("CLAUDE.md"))
        try write("profile instructions", to: profile.appendingPathComponent("CLAUDE.md"))
        try write("shared agent", to: shared.appendingPathComponent("agents/opus-xhigh.md"))
        try write("profile agent", to: profile.appendingPathComponent("agents/custom.md"))

        let result = try SharedConfigurationParityStore().prepare(
            profileConfigPath: profile.path,
            sharedConfigPath: shared.path,
            backupRootPath: root.appendingPathComponent("backups").path
        )

        let backup = try XCTUnwrap(result.backupPath).asURL
        XCTAssertEqual(
            try String(contentsOf: backup.appendingPathComponent("CLAUDE.md")),
            "profile instructions"
        )
        XCTAssertEqual(
            try String(contentsOf: backup.appendingPathComponent("agents/custom.md")),
            "profile agent"
        )
        XCTAssertEqual(
            try resolvedLink(at: profile.appendingPathComponent("CLAUDE.md")),
            shared.appendingPathComponent("CLAUDE.md").path
        )
        XCTAssertEqual(
            try resolvedLink(at: profile.appendingPathComponent("agents")),
            shared.appendingPathComponent("agents").path
        )
    }

    func testIsIdempotentAndDoesNotCreateAnotherBackup() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared")
        let profile = root.appendingPathComponent("profile")
        try write("shared", to: shared.appendingPathComponent("settings.json"))

        _ = try SharedConfigurationParityStore().prepare(
            profileConfigPath: profile.path,
            sharedConfigPath: shared.path,
            backupRootPath: root.appendingPathComponent("backups").path
        )
        let result = try SharedConfigurationParityStore().prepare(
            profileConfigPath: profile.path,
            sharedConfigPath: shared.path,
            backupRootPath: root.appendingPathComponent("backups").path
        )

        XCTAssertTrue(result.wasAlreadyConfigured)
        XCTAssertTrue(result.linkedItems.isEmpty)
        XCTAssertNil(result.backupPath)
    }

    func testRollsBackAllExistingItemsWhenLinkCreationFails() throws {
        struct ExpectedFailure: Error {}

        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared")
        let profile = root.appendingPathComponent("profile")
        try write("shared instructions", to: shared.appendingPathComponent("CLAUDE.md"))
        try write("shared agent", to: shared.appendingPathComponent("agents/opus-xhigh.md"))
        try write("profile instructions", to: profile.appendingPathComponent("CLAUDE.md"))
        try write("profile agent", to: profile.appendingPathComponent("agents/custom.md"))

        var invocationCount = 0
        let store = SharedConfigurationParityStore(
            fileManager: fileManager,
            createLink: { [fileManager] linkPath, destinationPath in
                invocationCount += 1
                if invocationCount == 2 { throw ExpectedFailure() }
                try fileManager.createSymbolicLink(
                    atPath: linkPath,
                    withDestinationPath: destinationPath
                )
            }
        )

        XCTAssertThrowsError(
            try store.prepare(
                profileConfigPath: profile.path,
                sharedConfigPath: shared.path,
                backupRootPath: root.appendingPathComponent("backups").path
            )
        ) { error in
            XCTAssertTrue(error is ExpectedFailure)
        }

        XCTAssertEqual(
            try String(contentsOf: profile.appendingPathComponent("CLAUDE.md")),
            "profile instructions"
        )
        XCTAssertEqual(
            try String(contentsOf: profile.appendingPathComponent("agents/custom.md")),
            "profile agent"
        )
        XCTAssertNotEqual(try itemType(at: profile.appendingPathComponent("CLAUDE.md")), .typeSymbolicLink)
        XCTAssertNotEqual(try itemType(at: profile.appendingPathComponent("agents")), .typeSymbolicLink)
    }

    func testRejectsDanglingSharedLinkBeforeChangingProfile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared")
        let profile = root.appendingPathComponent("profile")
        try fileManager.createDirectory(at: shared, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            atPath: shared.appendingPathComponent("agents").path,
            withDestinationPath: root.appendingPathComponent("missing-agents").path
        )
        try write("profile", to: profile.appendingPathComponent("CLAUDE.md"))
        try write("shared", to: shared.appendingPathComponent("CLAUDE.md"))

        XCTAssertThrowsError(
            try SharedConfigurationParityStore().prepare(
                profileConfigPath: profile.path,
                sharedConfigPath: shared.path,
                backupRootPath: root.appendingPathComponent("backups").path
            )
        ) { error in
            XCTAssertEqual(
                error as? SharedConfigurationParityError,
                .danglingSharedItem(shared.appendingPathComponent("agents").path)
            )
        }
        XCTAssertEqual(try String(contentsOf: profile.appendingPathComponent("CLAUDE.md")), "profile")
    }

    func testMissingOptionalSharedItemPreservesProfileItem() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared")
        let profile = root.appendingPathComponent("profile")
        try write("shared settings", to: shared.appendingPathComponent("settings.json"))
        try write("profile local settings", to: profile.appendingPathComponent("settings.local.json"))

        let result = try SharedConfigurationParityStore().prepare(
            profileConfigPath: profile.path,
            sharedConfigPath: shared.path,
            backupRootPath: root.appendingPathComponent("backups").path
        )

        XCTAssertTrue(result.missingSharedItems.contains("settings.local.json"))
        XCTAssertEqual(
            try String(contentsOf: profile.appendingPathComponent("settings.local.json")),
            "profile local settings"
        )
        XCTAssertNotEqual(
            try itemType(at: profile.appendingPathComponent("settings.local.json")),
            .typeSymbolicLink
        )
    }

    /// Names listed in the extra shared items file are linked exactly like built-in items.
    func testLinksItemsListedInExtraSharedItemsFile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared")
        let profile = root.appendingPathComponent("profile")
        try write("shared tool", to: shared.appendingPathComponent("my-tools/run.sh"))
        try write("shared notes", to: shared.appendingPathComponent("notes.md"))
        try write("profile-only", to: profile.appendingPathComponent("not-listed.md"))
        try write("shared but not listed", to: shared.appendingPathComponent("not-listed.md"))
        let extraFile = root.appendingPathComponent("extra-shared-items.txt")
        try write("# personal additions\n\nmy-tools\n  notes.md  \nmy-tools\n", to: extraFile)

        let result = try SharedConfigurationParityStore(extraItemsFilePath: extraFile.path).prepare(
            profileConfigPath: profile.path,
            sharedConfigPath: shared.path,
            backupRootPath: root.appendingPathComponent("backups").path
        )

        XCTAssertEqual(result.linkedItems, ["my-tools", "notes.md"])
        for name in ["my-tools", "notes.md"] {
            XCTAssertEqual(
                try resolvedLink(at: profile.appendingPathComponent(name)),
                shared.appendingPathComponent(name).standardizedFileURL.path
            )
        }
        // Items that are not listed stay profile-local.
        XCTAssertEqual(
            try String(contentsOf: profile.appendingPathComponent("not-listed.md")),
            "profile-only"
        )
    }

    /// Unsafe names are dropped instead of being linked, and valid neighbours still apply.
    func testIgnoresInvalidExtraSharedItemNames() throws {
        let parsed = SharedConfigurationParityStore.parseExtraItemNames(
            "../escape\nnested/item\n.\n..\n# comment\n\nvalid-item\n"
        )
        XCTAssertEqual(parsed.accepted, ["valid-item"])
        XCTAssertEqual(parsed.rejected, ["../escape", "nested/item", ".", ".."])

        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared")
        let profile = root.appendingPathComponent("profile")
        try write("outside", to: root.appendingPathComponent("escape"))
        try write("valid", to: shared.appendingPathComponent("valid-item"))
        let extraFile = root.appendingPathComponent("extra-shared-items.txt")
        try write("../escape\nvalid-item\n", to: extraFile)

        let result = try SharedConfigurationParityStore(extraItemsFilePath: extraFile.path).prepare(
            profileConfigPath: profile.path,
            sharedConfigPath: shared.path,
            backupRootPath: root.appendingPathComponent("backups").path
        )

        XCTAssertEqual(result.linkedItems, ["valid-item"])
        // "../escape" resolves outside the profile; it must not have been replaced by a link.
        XCTAssertNotEqual(try itemType(at: root.appendingPathComponent("escape")), .typeSymbolicLink)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("escape")), "outside")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("SharedConfigurationParityStoreTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ content: String, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    private func resolvedLink(at url: URL) throws -> String {
        let destination = try fileManager.destinationOfSymbolicLink(atPath: url.path)
        return URL(fileURLWithPath: destination).standardizedFileURL.path
    }

    private func itemType(at url: URL) throws -> FileAttributeType? {
        try fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
    }
}

private extension String {
    var asURL: URL { URL(fileURLWithPath: self, isDirectory: true) }
}

import Foundation
import XCTest
@testable import ClaudeProfilesCore

/// Account data must survive operational parity and its repeated application.
final class SharedMCPConfigurationStoreTests: XCTestCase {
    func testMergesMCPWithoutCopyingIdentityTrustOrUsage() throws {
        let source: [String: Any] = [
            "oauthAccount": ["id": "main"], "userID": "main", "machineID": "main",
            "mcpServers": ["memory": ["command": "memory-server"]],
            "projects": ["/repo": ["mcpServers": ["index": ["command": "index-server"]],
                                     "hasTrustDialogAccepted": true, "allowedTools": ["Bash"],
                                     "lastSessionId": "main-session"]]
        ]
        let target: [String: Any] = [
            "oauthAccount": ["id": "sub"], "userID": "sub", "machineID": "sub",
            "disabledMcpServers": ["memory"], "unknown": "preserved",
            "projects": ["/repo": ["hasTrustDialogAccepted": false, "allowedTools": [],
                                     "lastSessionId": "sub-session"],
                         "/only-sub": ["mcpServers": ["custom": ["command": "custom"]]]]
        ]
        let store = SharedMCPConfigurationStore()
        let result = try store.merging(source: source, destination: target)
        for key in ["oauthAccount", "userID", "machineID", "unknown"] {
            XCTAssertEqual(NSDictionary(dictionary: [key: result[key]!]), NSDictionary(dictionary: [key: target[key]!]))
        }
        XCTAssertNil(result["disabledMcpServers"])
        XCTAssertNotNil((result["mcpServers"] as? [String: Any])?["memory"])
        let projects = try XCTUnwrap(result["projects"] as? [String: [String: Any]])
        XCTAssertEqual(projects["/repo"]?["hasTrustDialogAccepted"] as? Bool, false)
        XCTAssertEqual(projects["/repo"]?["lastSessionId"] as? String, "sub-session")
        XCTAssertEqual(projects["/repo"]?["allowedTools"] as? [String], [])
        XCTAssertNotNil(projects["/only-sub"])
        XCTAssertEqual(NSDictionary(dictionary: result), NSDictionary(dictionary: try store.merging(source: source, destination: result)))
    }

    func testBackupPermissionsAndIdempotency() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("main.json")
        let target = root.appendingPathComponent("sub.json")
        let original = Data(#"{"oauthAccount":{"id":"sub"},"userID":"sub"}"#.utf8)
        try Data(#"{"mcpServers":{"memory":{"command":"memory-server"}},"oauthAccount":{"id":"main"}}"#.utf8).write(to: source)
        try original.write(to: target)
        let store = SharedMCPConfigurationStore()
        let backup = try XCTUnwrap(store.prepare(sharedFile: source, profileFile: target, backupRoot: root.appendingPathComponent("backups")))
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("profile-config.json")), original)
        for file in [target, backup.appendingPathComponent("profile-config.json")] {
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        }
        XCTAssertNil(try store.prepare(sharedFile: source, profileFile: target, backupRoot: root.appendingPathComponent("backups")))
    }

    func testRejectsMalformedSourceAndLinkedDestinationWithoutWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("main.json")
        let target = root.appendingPathComponent("sub.json")
        let original = Data(#"{"userID":"sub"}"#.utf8)
        try Data(#"{"mcpServers":"invalid"}"#.utf8).write(to: source)
        try original.write(to: target)
        let store = SharedMCPConfigurationStore()
        XCTAssertThrowsError(try store.prepare(sharedFile: source, profileFile: target, backupRoot: root.appendingPathComponent("backups")))
        XCTAssertEqual(try Data(contentsOf: target), original)
        let link = root.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try store.prepare(sharedFile: source, profileFile: link, backupRoot: root.appendingPathComponent("backups")))
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testMissingSourceIsNoOpAndMissingTargetCanBeCreated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("main.json")
        let target = root.appendingPathComponent("sub.json")
        let store = SharedMCPConfigurationStore()
        XCTAssertNil(try store.prepare(sharedFile: source, profileFile: target, backupRoot: root.appendingPathComponent("backups")))
        try Data(#"{"mcpServers":{"memory":{"command":"memory-server"}}}"#.utf8).write(to: source)
        XCTAssertNotNil(try store.prepare(sharedFile: source, profileFile: target, backupRoot: root.appendingPathComponent("backups")))
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any]
        XCTAssertNotNil(result?["mcpServers"])
        XCTAssertNil(result?["oauthAccount"])
    }
}

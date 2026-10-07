import Foundation
import Darwin

/// Copies operational MCP fields out of Claude's mixed account/configuration file.
/// The file itself must never be linked: OAuth identity and runtime state stay local.
public struct SharedMCPConfigurationStore {
    public static let sharedKeys = [
        "mcpServers", "enabledMcpServers", "disabledMcpServers",
        "enabledMcpjsonServers", "disabledMcpjsonServers", "mcpContextUris"
    ]

    public init() {}

    /// Refreshes known MCP fields, retaining all other profile fields, including trust
    /// decisions. Returns the retained backup URL, or nil when no change is needed.
    /// Call before starting a profile; the snapshot check detects concurrent writes
    /// during preparation but is not a lock shared with Claude's own writer.
    public func prepare(sharedFile: URL, profileFile: URL, backupRoot: URL) throws -> URL? {
        guard sharedFile.resolvingSymlinksInPath() != profileFile.resolvingSymlinksInPath(),
              (try? profileFile.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        else { throw SharedMCPConfigurationError.unsafeDestination }
        // A missing source is not an instruction to erase destination settings.
        guard FileManager.default.fileExists(atPath: sharedFile.path) else { return nil }
        let sourceData = try Data(contentsOf: sharedFile)
        let source = try dictionary(sourceData)
        let original = try readIfPresent(profileFile)
        let destination = try original.map(dictionary) ?? [:]
        let merged = try merging(source: source, destination: destination)
        guard !NSDictionary(dictionary: destination).isEqual(to: merged) else { return nil }

        let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
        let manager = FileManager.default
        let backup = backupRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: backup, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        if let original {
            // Backups contain account state too: create them owner-only from the outset.
            let saved = backup.appendingPathComponent("profile-config.json")
            guard manager.createFile(atPath: saved.path, contents: original,
                                     attributes: [.posixPermissions: 0o600]) else {
                throw SharedMCPConfigurationError.backupFailed
            }
        } else {
            try Data().write(to: backup.appendingPathComponent("profile-config-was-absent"))
        }

        try manager.createDirectory(at: profileFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = profileFile.deletingLastPathComponent().appendingPathComponent(".mcp-sync-\(UUID().uuidString)")
        guard manager.createFile(atPath: staged.path, contents: data,
                                 attributes: [.posixPermissions: 0o600]) else {
            throw SharedMCPConfigurationError.writeFailed
        }
        defer { try? manager.removeItem(at: staged) }
        guard try readIfPresent(profileFile) == original,
              try Data(contentsOf: sharedFile) == sourceData else {
            throw SharedMCPConfigurationError.changedDuringPreparation
        }
        // Same-directory rename publishes the complete owner-only file atomically.
        guard rename(staged.path, profileFile.path) == 0 else {
            throw SharedMCPConfigurationError.writeFailed
        }
        return backup
    }

    /// Main settings win for known fields in matching projects. Profile-only projects
    /// and unknown fields are retained; onboarding/trust/permissions are not cloned.
    func merging(source: [String: Any], destination: [String: Any]) throws -> [String: Any] {
        var result = destination
        try copyFields(source: source, into: &result)
        if let rawProjects = source["projects"] {
            guard let projects = rawProjects as? [String: Any],
                  destination["projects"] == nil || destination["projects"] is [String: Any]
            else { throw SharedMCPConfigurationError.invalidJSON }
            var targets = destination["projects"] as? [String: Any] ?? [:]
            for (path, rawProject) in projects {
                guard let project = rawProject as? [String: Any],
                      targets[path] == nil || targets[path] is [String: Any]
                else { throw SharedMCPConfigurationError.invalidJSON }
                var target = targets[path] as? [String: Any] ?? [:]
                try copyFields(source: project, into: &target)
                if !target.isEmpty { targets[path] = target }
            }
            if !targets.isEmpty { result["projects"] = targets }
        }
        return result
    }

    private func copyFields(source: [String: Any], into target: inout [String: Any]) throws {
        for key in Self.sharedKeys {
            if let value = source[key] {
                let valid = key == "mcpServers" ? value is [String: Any] : value is [String]
                guard valid else { throw SharedMCPConfigurationError.invalidJSON }
                target[key] = value
            } else {
                target.removeValue(forKey: key)
            }
        }
    }

    private func dictionary(_ data: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SharedMCPConfigurationError.invalidJSON
        }
        return result
    }

    private func readIfPresent(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }
}

public enum SharedMCPConfigurationError: SharedPreparationError {
    case unsafeDestination, invalidJSON, backupFailed, writeFailed, changedDuringPreparation

    public var errorDescription: String? {
        switch self {
        case .unsafeDestination: return "MCP設定の保存先が共有元と同じか、リンクになっています。"
        case .invalidJSON: return "MCP設定の形式を確認できませんでした。設定は変更していません。"
        case .backupFailed: return "MCP設定のバックアップを作成できませんでした。"
        case .writeFailed: return "MCP設定を書き込めませんでした。元の設定は保持しています。"
        case .changedDuringPreparation: return "準備中に設定が更新されました。Claudeの作業が落ち着いてから再試行してください。"
        }
    }
}

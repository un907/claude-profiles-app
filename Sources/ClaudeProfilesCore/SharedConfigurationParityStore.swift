// Shares the default profile's user-authored Claude Code configuration with an
// additional profile by replacing allowlisted items in the profile's CLAUDE_CONFIG_DIR
// with symbolic links. The allowlist is a fixed built-in set plus optional,
// user-supplied names read from an "extra shared items" text file.

import Foundation
import os

public struct SharedConfigurationParityPreparation: Equatable, Sendable {
    public let linkedItems: [String]
    public let missingSharedItems: [String]
    public let backupPath: String?
    public let wasAlreadyConfigured: Bool

    public init(
        linkedItems: [String],
        missingSharedItems: [String],
        backupPath: String?,
        wasAlreadyConfigured: Bool
    ) {
        self.linkedItems = linkedItems
        self.missingSharedItems = missingSharedItems
        self.backupPath = backupPath
        self.wasAlreadyConfigured = wasAlreadyConfigured
    }
}

public enum SharedConfigurationParityError: SharedPreparationError, Equatable, Sendable {
    case sameConfigurationDirectory
    case danglingSharedItem(String)
    case unsupportedSharedItem(String)
    case unsupportedProfileItem(String)
    case rollbackFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sameConfigurationDirectory:
            return "標準プロフィールと追加プロフィールの設定保存先が同一です。"
        case .danglingSharedItem(let path):
            return "標準プロフィールの設定リンクが壊れています（\(path)）。設定は変更していません。"
        case .unsupportedSharedItem(let path):
            return "標準プロフィールの設定形式を共有できません（\(path)）。設定は変更していません。"
        case .unsupportedProfileItem(let path):
            return "追加プロフィールの既存設定形式を退避できません（\(path)）。設定は変更していません。"
        case .rollbackFailed(let path):
            return "設定共有に失敗し、元の設定を完全に復元できませんでした（\(path)）。バックアップを確認してください。"
        }
    }
}

/// Shares only user-authored operational Claude configuration. Authentication,
/// account state, remote policy/cache, Desktop data, and transient session state
/// remain in the isolated profile configuration directory.
public struct SharedConfigurationParityStore {
    public static let sharedItemNames = [
        "CLAUDE.md",
        "agents",
        "rules",
        "hooks",
        "commands",
        "skills",
        "output-styles",
        "settings.json",
        "settings.local.json",
        "plugins",
        // Referenced support files must resolve under an isolated config root too.
        "scripts", "docs", "templates",
        "AGENTS.md", "launch.json",
        "browser-tooling.md", "statusline-command.sh"
    ]

    /// Result of parsing an extra shared items file.
    public struct ExtraItemNames: Equatable, Sendable {
        /// Names that will be appended to the built-in allowlist, in file order, deduplicated.
        public let accepted: [String]
        /// Non-comment lines that were rejected because they are not a single safe name.
        public let rejected: [String]

        public init(accepted: [String], rejected: [String]) {
            self.accepted = accepted
            self.rejected = rejected
        }
    }

    private static let logger = Logger(
        subsystem: "io.github.un907.claudeprofiles",
        category: "SharedConfiguration"
    )

    private let fileManager: FileManager
    private let createLink: (String, String) throws -> Void
    /// Optional path of a text file listing additional item names to share
    /// (one per line). Read on every `prepare` call so edits apply without a restart.
    private let extraItemsFilePath: String?

    public init(fileManager: FileManager = .default, extraItemsFilePath: String? = nil) {
        self.fileManager = fileManager
        self.extraItemsFilePath = extraItemsFilePath
        self.createLink = { linkPath, destinationPath in
            try fileManager.createSymbolicLink(
                atPath: linkPath,
                withDestinationPath: destinationPath
            )
        }
    }

    init(
        fileManager: FileManager,
        extraItemsFilePath: String? = nil,
        createLink: @escaping (String, String) throws -> Void
    ) {
        self.fileManager = fileManager
        self.extraItemsFilePath = extraItemsFilePath
        self.createLink = createLink
    }

    /// Parses the contents of an extra shared items file.
    ///
    /// Format: one item name per line; surrounding whitespace is trimmed; empty lines and
    /// lines starting with `#` are ignored. A name is rejected when it contains `/` or `..`
    /// (it could escape the configuration directory) or is exactly `.` (it would resolve to
    /// the profile configuration directory itself, which `prepare` would then move into the
    /// backup folder wholesale).
    ///
    /// Names in `reservedExtraItemNames` are rejected too: these are built-in items that are
    /// shared with a merge step (SharedProjectsStore / SharedHistoryStore), and sending them
    /// through this store's back-up-then-link path would link them before the merge runs.
    public static func parseExtraItemNames(_ text: String) -> ExtraItemNames {
        var accepted: [String] = []
        var rejected: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            if line.contains("/") || line.contains("..") || line == "."
                || reservedExtraItemNames.contains(line) {
                rejected.append(line)
                continue
            }
            if !accepted.contains(line) {
                accepted.append(line)
            }
        }
        return ExtraItemNames(accepted: accepted, rejected: rejected)
    }

    /// Items shared by merging rather than by this store; never accepted as extras.
    public static let reservedExtraItemNames: Set<String> = [
        "projects",
        SharedHistoryStore.fileHistoryName,
        SharedHistoryStore.historyFileName
    ]

    /// Built-in allowlist followed by any valid names from the extra items file.
    ///
    /// A missing or unreadable file simply means "no extras": sharing the built-in set must
    /// keep working even if the optional file is absent. Rejected names are logged (not
    /// thrown) so one bad line does not block launching the profile.
    func effectiveItemNames() -> [String] {
        guard let extraItemsFilePath,
              let text = try? String(contentsOfFile: extraItemsFilePath, encoding: .utf8) else {
            return Self.sharedItemNames
        }
        let parsed = Self.parseExtraItemNames(text)
        for name in parsed.rejected {
            Self.logger.warning(
                "Ignoring extra shared item \(name, privacy: .public): unsafe or reserved name"
            )
        }
        return Self.sharedItemNames + parsed.accepted.filter { !Self.sharedItemNames.contains($0) }
    }

    /// Replaces allowlisted profile items with links to the default profile.
    /// Every existing item is moved to a retained backup before any link is
    /// created. If any step fails, all items changed by this call are restored.
    public func prepare(
        profileConfigPath: String,
        sharedConfigPath: String,
        backupRootPath: String
    ) throws -> SharedConfigurationParityPreparation {
        let profileConfig = URL(fileURLWithPath: profileConfigPath, isDirectory: true)
        let sharedConfig = URL(fileURLWithPath: sharedConfigPath, isDirectory: true)

        guard normalized(profileConfig) != normalized(sharedConfig) else {
            throw SharedConfigurationParityError.sameConfigurationDirectory
        }

        var missingSharedItems: [String] = []
        var plans: [LinkPlan] = []

        // Preflight the complete allowlist before touching the profile. Only names on the
        // allowlist are ever visited, so items that were shared by an older allowlist and
        // are no longer on it are left untouched.
        for name in effectiveItemNames() {
            let source = sharedConfig.appendingPathComponent(name)
            let destination = profileConfig.appendingPathComponent(name)

            guard let sourceType = try itemType(at: source) else {
                missingSharedItems.append(name)
                continue
            }
            try validateSharedItem(source, type: sourceType)

            let destinationType = try itemType(at: destination)
            if destinationType == .typeSymbolicLink,
               try resolvedLink(at: destination) == normalized(source) {
                continue
            }
            if let destinationType {
                try validateProfileItem(destination, type: destinationType)
            }
            plans.append(LinkPlan(
                name: name,
                source: source,
                destination: destination,
                hadExistingItem: destinationType != nil
            ))
        }

        guard !plans.isEmpty else {
            return SharedConfigurationParityPreparation(
                linkedItems: [],
                missingSharedItems: missingSharedItems,
                backupPath: nil,
                wasAlreadyConfigured: true
            )
        }

        try fileManager.createDirectory(at: profileConfig, withIntermediateDirectories: true)

        let plansWithExistingItems = plans.filter(\.hadExistingItem)
        let backupRoot: URL? = plansWithExistingItems.isEmpty ? nil : URL(
            fileURLWithPath: backupRootPath,
            isDirectory: true
        ).appendingPathComponent(UUID().uuidString, isDirectory: true)

        if let backupRoot {
            try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        }

        var movedPlans: [LinkPlan] = []
        var createdPlans: [LinkPlan] = []

        do {
            if let backupRoot {
                for plan in plansWithExistingItems {
                    try fileManager.moveItem(
                        at: plan.destination,
                        to: backupRoot.appendingPathComponent(plan.name)
                    )
                    movedPlans.append(plan)
                }
            }

            for plan in plans {
                try createLink(plan.destination.path, plan.source.path)
                createdPlans.append(plan)
            }
        } catch {
            for plan in createdPlans.reversed() {
                try? fileManager.removeItem(at: plan.destination)
            }

            var failedRestorePath: String?
            if let backupRoot {
                for plan in movedPlans.reversed() {
                    let backupItem = backupRoot.appendingPathComponent(plan.name)
                    do {
                        if try itemType(at: plan.destination) != nil {
                            try fileManager.removeItem(at: plan.destination)
                        }
                        try fileManager.moveItem(at: backupItem, to: plan.destination)
                    } catch {
                        failedRestorePath = plan.destination.path
                    }
                }
            }

            if let failedRestorePath {
                throw SharedConfigurationParityError.rollbackFailed(failedRestorePath)
            }
            throw error
        }

        return SharedConfigurationParityPreparation(
            linkedItems: plans.map(\.name),
            missingSharedItems: missingSharedItems,
            backupPath: backupRoot?.path,
            wasAlreadyConfigured: false
        )
    }

    private func validateSharedItem(_ url: URL, type: FileAttributeType) throws {
        if type == .typeSymbolicLink {
            guard fileManager.fileExists(atPath: url.path) else {
                throw SharedConfigurationParityError.danglingSharedItem(url.path)
            }
            return
        }
        guard type == .typeDirectory || type == .typeRegular else {
            throw SharedConfigurationParityError.unsupportedSharedItem(url.path)
        }
    }

    private func validateProfileItem(_ url: URL, type: FileAttributeType) throws {
        guard type == .typeDirectory || type == .typeRegular || type == .typeSymbolicLink else {
            throw SharedConfigurationParityError.unsupportedProfileItem(url.path)
        }
    }

    private func itemType(at url: URL) throws -> FileAttributeType? {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            return attributes[.type] as? FileAttributeType
        } catch let error as CocoaError {
            if error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                return nil
            }
            throw error
        }
    }

    private func resolvedLink(at url: URL) throws -> String {
        let destination = try fileManager.destinationOfSymbolicLink(atPath: url.path)
        let destinationURL: URL
        if destination.hasPrefix("/") {
            destinationURL = URL(fileURLWithPath: destination)
        } else {
            destinationURL = url.deletingLastPathComponent().appendingPathComponent(destination)
        }
        return normalized(destinationURL)
    }

    private func normalized(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private struct LinkPlan {
        let name: String
        let source: URL
        let destination: URL
        let hadExistingItem: Bool
    }
}

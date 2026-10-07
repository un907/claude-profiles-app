// Shares Claude Code's rewind snapshots (`file-history/`) and prompt history
// (`history.jsonl`) between an additional profile and the default profile.
//
// Unlike SharedConfigurationParityStore (which backs the profile's item up and replaces
// it with a link), these two items hold data the user wants to keep from every profile,
// so the profile's copy is first merged into the default profile's copy and only then
// replaced by a symbolic link — the same "merge, then link" approach SharedProjectsStore
// uses for `projects/`. Result and error types live in SharedHistoryPreparation.swift and
// SharedHistoryStoreError.swift.
//
// Safety rules:
// - The default profile's data is only ever added to (file-history) or replaced in one
//   atomic rename (history.jsonl); a failure never leaves it half-written.
// - Anything that cannot be merged without overwriting is moved to
//   "<backup root>/<run UUID>/…" instead of being deleted.
// - history.jsonl is merged as raw bytes per line, so lines that are not valid JSON or
//   not valid UTF-8 are carried over verbatim.

import Foundation

/// Merges and links `file-history/` and `history.jsonl` (see the file header).
public struct SharedHistoryStore {
    /// Directory with one sub-directory of rewind snapshots per session ID.
    public static let fileHistoryName: String = "file-history"
    /// Prompt history: one JSON object per line.
    public static let historyFileName: String = "history.jsonl"

    /// Owner read/write only: the history contains everything the user typed.
    private static let historyPermissions: Int = 0o600
    /// Line separator of history.jsonl.
    private static let newline: UInt8 = .init(ascii: "\n")

    private let fileManager: FileManager

    /// - Parameter fileManager: injected for tests; defaults to `.default`.
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - Merge rule

    /// Merge rule for two `history.jsonl` contents:
    /// 1. all non-empty lines, shared first, then the profile's;
    /// 2. exact duplicate lines removed (first occurrence kept);
    /// 3. lines with a numeric `timestamp` sorted ascending (stable), followed by every
    ///    other line — including lines that are not valid JSON, which are kept verbatim —
    ///    in their original order.
    /// Lines are returned without their trailing newline.
    public static func mergedHistory(shared: Data, profile: Data) -> [Data] {
        var seen: Set<Data> = []
        var stamped: [(timestamp: Double, line: Data)] = []
        var unstamped: [Data] = []
        let lines: [Data] = (shared.split(separator: newline) + profile.split(separator: newline)).map { Data($0) }
        for line in lines where !line.isEmpty && seen.insert(line).inserted {
            if let timestamp = timestamp(of: line) {
                stamped.append((timestamp, line))
            } else {
                unstamped.append(line)
            }
        }
        // Array.sort is not guaranteed to be stable, so ties keep their insertion order.
        let ordered: [Data] = stamped.enumerated()
            .sorted { lhs, rhs in
                lhs.element.timestamp == rhs.element.timestamp
                    ? lhs.offset < rhs.offset
                    : lhs.element.timestamp < rhs.element.timestamp
            }
            .map(\.element.line)
        return ordered + unstamped
    }

    /// The `timestamp` of a history line (milliseconds since 1970), or nil when the line
    /// is not a JSON object or has no numeric timestamp.
    private static func timestamp(of line: Data) -> Double? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return nil
        }
        return object["timestamp"] as? Double
    }

    /// True when both URLs name the same file after resolving links.
    private static func isSameLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path
            == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: - Entry point

    /// Merges the profile's `file-history/` and `history.jsonl` into the shared
    /// configuration directory and replaces them with links. Idempotent: items that are
    /// already linked to the shared copy are left alone.
    ///
    /// - Parameters:
    ///   - profileConfigPath: the additional profile's CLAUDE_CONFIG_DIR.
    ///   - sharedConfigPath: the default profile's configuration directory.
    ///   - backupRootPath: "Migration Backups/<profile UUID>/Shared History"; a run UUID
    ///     folder is created below it only when something has to be kept aside.
    public func prepare(
        profileConfigPath: String,
        sharedConfigPath: String,
        backupRootPath: String
    ) throws -> SharedHistoryPreparation {
        let profileConfig: URL = .init(fileURLWithPath: profileConfigPath, isDirectory: true)
        let sharedConfig: URL = .init(fileURLWithPath: sharedConfigPath, isDirectory: true)
        // Created lazily so an idempotent run leaves no empty backup folders behind.
        let backupRoot: URL = .init(fileURLWithPath: backupRootPath, isDirectory: true)
        let runBackup: URL = backupRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)

        let movedSessionCount: Int = try shareFileHistory(
            profile: profileConfig.appendingPathComponent(Self.fileHistoryName, isDirectory: true),
            shared: sharedConfig.appendingPathComponent(Self.fileHistoryName, isDirectory: true),
            runBackup: runBackup
        )
        let mergedLineCount: Int? = try shareHistoryFile(
            profile: profileConfig.appendingPathComponent(Self.historyFileName),
            shared: sharedConfig.appendingPathComponent(Self.historyFileName),
            runBackup: runBackup
        )
        return SharedHistoryPreparation(
            movedSessionCount: movedSessionCount,
            mergedHistoryLineCount: mergedLineCount,
            backupPath: fileManager.fileExists(atPath: runBackup.path) ? runBackup.path : nil
        )
    }

    // MARK: - file-history

    /// Moves each session folder of the profile into the shared `file-history`. A session
    /// ID that already exists in the shared folder keeps the shared copy; the profile's
    /// copy goes to "<run>/file-history/<name>". Returns the number of folders moved.
    private func shareFileHistory(profile: URL, shared: URL, runBackup: URL) throws -> Int {
        guard try isNotLinkedYet(profile, to: shared) else {
            return 0
        }
        try fileManager.createDirectory(at: shared, withIntermediateDirectories: true)

        var movedCount: Int = 0
        if try kind(of: profile) == .typeDirectory {
            let backupFolder: URL = runBackup.appendingPathComponent(Self.fileHistoryName, isDirectory: true)
            for entry in try fileManager.contentsOfDirectory(atPath: profile.path).sorted() {
                let source: URL = profile.appendingPathComponent(entry)
                let target: URL = shared.appendingPathComponent(entry)
                if try kind(of: target) == nil {
                    try fileManager.moveItem(at: source, to: target)
                    movedCount += 1
                } else {
                    // Never overwrite the shared snapshot; keep the profile's copy aside.
                    try fileManager.createDirectory(at: backupFolder, withIntermediateDirectories: true)
                    try fileManager.moveItem(at: source, to: backupFolder.appendingPathComponent(entry))
                }
            }
            // Every entry has been moved out, so only an empty folder is removed here.
            try fileManager.removeItem(at: profile)
        }
        try fileManager.createSymbolicLink(at: profile, withDestinationURL: shared)
        return movedCount
    }

    // MARK: - history.jsonl

    /// Merges the profile's `history.jsonl` into the shared one (see `mergedHistory`) and
    /// links it. Both originals are copied to "<run>/history.jsonl.shared" and
    /// "<run>/history.jsonl.profile" first. Returns the merged line count, or nil when the
    /// shared file did not need rewriting (no profile file, or an empty one).
    private func shareHistoryFile(profile: URL, shared: URL, runBackup: URL) throws -> Int? {
        guard try isNotLinkedYet(profile, to: shared) else {
            return nil
        }
        try fileManager.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
        // If the default profile's history.jsonl is itself a link (a user's own setup),
        // read and rewrite the file it points to instead of replacing that link.
        let sharedFile: URL = shared.resolvingSymlinksInPath()

        var mergedLineCount: Int?
        if try kind(of: profile) == .typeRegular {
            let profileData: Data = try Data(contentsOf: profile)
            if !profileData.isEmpty {
                let sharedData: Data = try kind(of: sharedFile) == nil ? Data() : Data(contentsOf: sharedFile)
                try backUp(sharedData: sharedData, profile: profile, shared: sharedFile, runBackup: runBackup)
                let merged: [Data] = Self.mergedHistory(shared: sharedData, profile: profileData)
                try writeAtomically(merged, to: sharedFile)
                mergedLineCount = merged.count
            }
            // The profile's original is in the backup (or was empty), so it can go.
            try fileManager.removeItem(at: profile)
        }
        if try kind(of: sharedFile) == nil {
            // Claude Code appends through the link; give it a real, private file to append to.
            try writeAtomically([], to: sharedFile)
        }
        try fileManager.createSymbolicLink(at: profile, withDestinationURL: shared)
        return mergedLineCount
    }

    /// Copies both originals into the run's backup folder before the shared file changes.
    private func backUp(sharedData: Data, profile: URL, shared: URL, runBackup: URL) throws {
        try fileManager.createDirectory(at: runBackup, withIntermediateDirectories: true)
        if try kind(of: shared) != nil {
            try sharedData.write(to: runBackup.appendingPathComponent(Self.historyFileName + ".shared"))
        }
        try fileManager.copyItem(at: profile, to: runBackup.appendingPathComponent(Self.historyFileName + ".profile"))
    }

    /// Writes `lines` (each newline-terminated) through a temporary file in the same
    /// folder and one rename, so readers see either the old or the new file, never a
    /// partial one.
    private func writeAtomically(_ lines: [Data], to url: URL) throws {
        let temporary: URL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let contents: Data = lines.reduce(into: Data()) { result, line in
            result.append(line)
            result.append(Self.newline)
        }
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: contents,
            attributes: [.posixPermissions: Self.historyPermissions]
        ) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        // rename(2) replaces the destination atomically and keeps the temporary file's 0600
        // mode. FileManager.replaceItemAt would copy the old file's metadata instead.
        guard rename(temporary.path, url.path) == 0 else {
            let code: Int32 = errno
            try? fileManager.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    // MARK: - Helpers

    /// False when `item` is already a link to `shared`, or is the shared item itself
    /// (nothing to do). Throws when it is a link to anywhere else, or when its type is not
    /// what Claude Code creates, so a profile is never silently re-pointed.
    private func isNotLinkedYet(_ item: URL, to shared: URL) throws -> Bool {
        let itemKind: FileAttributeType? = try kind(of: item)
        if itemKind != .typeSymbolicLink, Self.isSameLocation(item, shared) {
            // The profile's config directory is the shared one: nothing to share.
            return false
        }
        switch itemKind {
        case .typeSymbolicLink:
            let target: String = try fileManager.destinationOfSymbolicLink(atPath: item.path)
            let absolute: URL = target.hasPrefix("/")
                ? URL(fileURLWithPath: target)
                : item.deletingLastPathComponent().appendingPathComponent(target)
            guard Self.isSameLocation(absolute, shared) else {
                throw SharedHistoryStoreError.linkPointsElsewhere(item.path)
            }
            return false

        case nil:
            return true

        case .typeDirectory where item.lastPathComponent == Self.fileHistoryName:
            return true

        case .typeRegular where item.lastPathComponent == Self.historyFileName:
            return true

        default:
            throw SharedHistoryStoreError.unsupportedItem(item.path)
        }
    }

    /// File type of `url` without following a final symbolic link; nil when absent.
    private func kind(of url: URL) throws -> FileAttributeType? {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil else {
            return .typeSymbolicLink
        }
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
    }
}

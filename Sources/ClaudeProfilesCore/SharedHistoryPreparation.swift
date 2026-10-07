// Result value of SharedHistoryStore.prepare (see SharedHistoryStore.swift).

import Foundation

/// What one `SharedHistoryStore.prepare` call changed.
public struct SharedHistoryPreparation: Equatable, Sendable {
    /// Session directories moved from the profile into the shared `file-history`.
    public let movedSessionCount: Int
    /// Lines in the shared `history.jsonl` after merging, or nil when it was not rewritten.
    public let mergedHistoryLineCount: Int?
    /// Backup folder of this run, or nil when nothing needed to be kept aside.
    public let backupPath: String?

    /// Creates a summary value.
    public init(movedSessionCount: Int, mergedHistoryLineCount: Int?, backupPath: String?) {
        self.movedSessionCount = movedSessionCount
        self.mergedHistoryLineCount = mergedHistoryLineCount
        self.backupPath = backupPath
    }
}

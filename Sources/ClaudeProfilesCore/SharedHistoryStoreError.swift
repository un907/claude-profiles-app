// Errors of SharedHistoryStore (see SharedHistoryStore.swift).

import Foundation

/// Reasons the history items of a profile cannot be shared.
public enum SharedHistoryStoreError: SharedPreparationError, Equatable, Sendable {
    /// The profile's item is already a link, but to somewhere other than the shared item.
    case linkPointsElsewhere(String)
    /// The profile's item has an unexpected type (e.g. `history.jsonl` is a directory).
    case unsupportedItem(String)

    /// Japanese message shown in the launcher, matching the other stores.
    public var errorDescription: String? {
        switch self {
        case .linkPointsElsewhere(let path):
            return "既存の入力履歴リンクが別の保存先を指しています（\(path)）。"

        case .unsupportedItem(let path):
            return "入力履歴の保存形式を確認できません（\(path)）。"
        }
    }
}

// CLI command ("claude-<suffix>") support for LauncherModel.
//
// Kept in an extension so the model's main body stays focused on launching and profile
// management. The heavy lifting (shim contents, ownership marker, full sync, PATH check)
// lives in ClaudeProfilesCore.CLIShimStore, which is unit tested.

import ClaudeProfilesCore
import Foundation

extension LauncherModel {
    /// Brings ~/.local/bin in line with the current profiles (CLIShimStore.synchronize).
    /// Called after every profile change and at launch. Conflicts with the user's own files
    /// and write failures are shown in the profile list; they never undo the saved profile.
    func syncCLIShims() {
        do {
            let result = try cliShimStore.synchronize(profiles: profiles, executable: cliClaudeExecutable)
            if let command = result.conflicts.first {
                errorMessage = "\(command)は既存のファイルと同じ名前のため作成できませんでした。別の名前にしてください。"
            } else if let command = result.duplicates.first {
                errorMessage = "\(command)は複数のプロフィールで指定されています。どちらかを変更してください。"
            }
        } catch {
            errorMessage = "ターミナル用コマンドを更新できませんでした。"
        }
    }

    /// Checks once, in the background, whether ~/.local/bin is on the login shell's PATH.
    /// Starting a login shell can take a moment, so it must not block app launch. A failed
    /// check leaves the value nil, which shows no warning.
    func checkCLIDirectoryOnLoginPath() {
        let directory = Self.cliShimDirectory
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let isOnPath = CLIShimStore.isDirectoryOnLoginShellPath(directory)
            DispatchQueue.main.async {
                self?.isCLIDirectoryOnLoginPath = isOnPath
            }
        }
    }
}

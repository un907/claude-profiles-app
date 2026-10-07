import AppKit
import ClaudeProfilesCore
import Foundation

final class LauncherModel: ObservableObject {
    static let shared = LauncherModel()

    @Published private(set) var profiles: [ClaudeProfile] = []
    @Published private(set) var runningPIDs: [UUID: Int32] = [:]
    @Published private(set) var launchingProfileIDs: Set<UUID> = []
    @Published private(set) var stoppingProfileIDs: Set<UUID> = []
    @Published var errorMessage: String?
    @Published var closeAfterOpening: Bool {
        didSet {
            UserDefaults.standard.set(closeAfterOpening, forKey: Self.closeAfterOpeningKey)
        }
    }
    /// The `claude` that generated CLI shims execute. Empty means plain `claude`, resolved
    /// through the terminal's PATH. Changing it rewrites every shim.
    @Published var cliClaudeExecutable: String {
        didSet {
            guard cliClaudeExecutable != oldValue else { return }
            UserDefaults.standard.set(cliClaudeExecutable, forKey: Self.cliClaudeExecutableKey)
            syncCLIShims()
        }
    }
    /// Whether the CLI shim directory is on the login shell's PATH. nil while unknown or
    /// when the check failed; the UI only warns on an explicit `false`.
    /// Written only by `checkCLIDirectoryOnLoginPath()` (LauncherModel+CLI.swift).
    @Published var isCLIDirectoryOnLoginPath: Bool?

    private let repository = ProfileRepository()
    private let scanner = ClaudeProcessScanner()
    private let controller = ClaudeController()
    private let sharedProjectsStore = SharedProjectsStore()
    /// Shares the default profile's configuration; users can extend the built-in allowlist
    /// with item names listed in "extra-shared-items.txt" next to profiles.json.
    private let sharedConfigurationParityStore = SharedConfigurationParityStore(
        extraItemsFilePath: ProfileRepository().supportRoot
            .appendingPathComponent("extra-shared-items.txt").path
    )
    private let sharedMCPConfigurationStore = SharedMCPConfigurationStore()
    /// Writes `claude-<suffix>` terminal commands into ~/.local/bin.
    let cliShimStore = CLIShimStore(directory: LauncherModel.cliShimDirectory)
    private var timer: Timer?
    private static let closeAfterOpeningKey = "closeAfterOpening"
    private static let cliClaudeExecutableKey = "cliClaudeExecutable"

    /// Directory for generated CLI commands. ~/.local/bin is the common per-user bin
    /// directory (XDG convention) and is already on PATH for many setups.
    static let cliShimDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin", isDirectory: true)

    var runningCount: Int {
        runningPIDs.count
    }

    var activeProfiles: [ClaudeProfile] {
        profiles.filter { !$0.isArchived }
    }

    var archivedProfiles: [ClaudeProfile] {
        profiles.filter(\.isArchived)
    }

    var isClaudeInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Claude.app")
    }

    init() {
        closeAfterOpening = UserDefaults.standard.bool(forKey: Self.closeAfterOpeningKey)
        cliClaudeExecutable = UserDefaults.standard.string(forKey: Self.cliClaudeExecutableKey) ?? ""
        do {
            profiles = try repository.loadProfiles()
        } catch {
            errorMessage = "プロファイルを読み込めませんでした。"
        }
        refresh()
        prepareStoppedProfilesForSharedConfiguration()
        // Launch-time reconciliation: recreate missing or stale shims and remove generated
        // ones that no profile wants (e.g. after an interrupted rename).
        syncCLIShims()
        checkCLIDirectoryOnLoginPath()
    }

    deinit {
        timer?.invalidate()
    }

    func startMonitoring() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func isRunning(_ profile: ClaudeProfile) -> Bool {
        runningPIDs[profile.id] != nil
    }

    func isLaunching(_ profile: ClaudeProfile) -> Bool {
        launchingProfileIDs.contains(profile.id)
    }

    func isStopping(_ profile: ClaudeProfile) -> Bool {
        stoppingProfileIDs.contains(profile.id)
    }

    func open(_ profile: ClaudeProfile) {
        refresh()

        if let pid = runningPIDs[profile.id] {
            if !controller.focus(pid: pid) {
                errorMessage = "\(profile.name)を前面に表示できませんでした。"
            } else {
                recordUse(of: profile)
                hideLauncherIfNeeded()
            }
            return
        }

        guard !launchingProfileIDs.contains(profile.id) else { return }
        launchingProfileIDs.insert(profile.id)

        do {
            try prepareSharedConfiguration(for: profile)
            try controller.launch(profile)
            recordUse(of: profile)
            errorMessage = nil
            hideLauncherIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.refresh()
                self?.launchingProfileIDs.remove(profile.id)
            }
        } catch {
            launchingProfileIDs.remove(profile.id)
            errorMessage = sharedConfigurationErrorMessage(
                for: error,
                fallback: "\(profile.name)を起動できませんでした。"
            )
        }
    }

    func startAll() {
        let profilesToLaunch = activeProfiles.filter { !isRunning($0) && !isLaunching($0) }
        launchingProfileIDs.formUnion(profilesToLaunch.map(\.id))

        do {
            for profile in profilesToLaunch {
                try prepareSharedConfiguration(for: profile)
            }
        } catch {
            launchingProfileIDs.subtract(profilesToLaunch.map(\.id))
            errorMessage = configurationPreparationErrorMessage(for: error)
            return
        }

        for profile in profilesToLaunch {
            do {
                try controller.launch(profile)
            } catch {
                launchingProfileIDs.remove(profile.id)
                errorMessage = "一部のClaudeを起動できませんでした。"
                break
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refresh()
            self?.launchingProfileIDs.subtract(profilesToLaunch.map(\.id))
        }
    }

    func addProfile(name: String, purpose: String, colorHex: String, cliCommandSuffix: String?) {
        do {
            var profile = try repository.makeProfile(
                name: name,
                purpose: purpose,
                colorHex: colorHex
            )
            profile.cliCommandSuffix = cliCommandSuffix
            profiles.append(profile)
            try repository.saveProfiles(profiles)
            try prepareSharedConfiguration(for: profile)
            errorMessage = nil
            syncCLIShims()
        } catch {
            errorMessage = sharedConfigurationErrorMessage(
                for: error,
                fallback: "新しいプロファイルを作成できませんでした。"
            )
        }
    }

    func updateProfile(
        _ profile: ClaudeProfile,
        name: String,
        purpose: String,
        colorHex: String,
        cliCommandSuffix: String?
    ) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].name = name
        profiles[index].purpose = purpose
        profiles[index].colorHex = colorHex
        profiles[index].cliCommandSuffix = cliCommandSuffix
        saveProfiles(errorMessage: "変更を保存できませんでした。")
        // The shim embeds the profile name and suffix, so a rename or suffix change rewrites
        // (or removes) it.
        syncCLIShims()
    }

    func stop(_ profile: ClaudeProfile) {
        guard let pid = runningPIDs[profile.id] else { return }
        stoppingProfileIDs.insert(profile.id)
        guard controller.terminate(pid: pid) else {
            stoppingProfileIDs.remove(profile.id)
            errorMessage = "\(profile.name)を終了できませんでした。"
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refresh()
            self?.stoppingProfileIDs.remove(profile.id)
        }
    }

    func restart(_ profile: ClaudeProfile) {
        guard let pid = runningPIDs[profile.id] else {
            open(profile)
            return
        }

        stoppingProfileIDs.insert(profile.id)
        launchingProfileIDs.insert(profile.id)
        guard controller.terminate(pid: pid) else {
            stoppingProfileIDs.remove(profile.id)
            launchingProfileIDs.remove(profile.id)
            errorMessage = "\(profile.name)を再起動できませんでした。"
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.refresh()
            guard !self.isRunning(profile) else {
                self.stoppingProfileIDs.remove(profile.id)
                self.launchingProfileIDs.remove(profile.id)
                self.errorMessage = "終了処理を待っています。少し後でもう一度お試しください。"
                return
            }

            do {
                try self.prepareSharedConfiguration(for: profile)
                try self.controller.launch(profile)
                self.recordUse(of: profile)
                self.errorMessage = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.refresh()
                    self?.stoppingProfileIDs.remove(profile.id)
                    self?.launchingProfileIDs.remove(profile.id)
                }
            } catch {
                self.stoppingProfileIDs.remove(profile.id)
                self.launchingProfileIDs.remove(profile.id)
                self.errorMessage = self.sharedConfigurationErrorMessage(
                    for: error,
                    fallback: "\(profile.name)を再起動できませんでした。"
                )
            }
        }
    }

    func archive(_ profile: ClaudeProfile) {
        guard !profile.isDefault else { return }
        guard !isRunning(profile), !isLaunching(profile), !isStopping(profile) else {
            errorMessage = "終了してからアーカイブしてください。"
            return
        }
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].isArchived = true
        saveProfiles(errorMessage: "アーカイブできませんでした。")
        syncCLIShims()
    }

    func restore(_ profile: ClaudeProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].isArchived = false
        saveProfiles(errorMessage: "復元できませんでした。")
        syncCLIShims()
    }

    func showStorage(for profile: ClaudeProfile) {
        do {
            try FileManager.default.createDirectory(
                atPath: profile.userDataPath,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.activateFileViewerSelecting([
                URL(fileURLWithPath: profile.userDataPath)
            ])
        } catch {
            errorMessage = "保存場所を開けませんでした。"
        }
    }

    func showLauncherStorage() {
        NSWorkspace.shared.open(repository.supportRoot)
    }

    func refresh() {
        do {
            let snapshots = try scanner.currentSnapshot()
            runningPIDs = Dictionary(uniqueKeysWithValues: profiles.compactMap { profile in
                let pid = profile.isDefault
                    ? ClaudeProcessParser.defaultProfilePID(in: snapshots)
                    : ClaudeProcessParser.pid(forUserDataPath: profile.userDataPath, in: snapshots)
                guard let pid else {
                    return nil
                }
                return (profile.id, pid)
            })
        } catch {
            runningPIDs = [:]
            errorMessage = "Claudeの起動状態を確認できませんでした。"
        }
    }

    private func recordUse(of profile: ClaudeProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].lastOpenedAt = Date()
        saveProfiles(errorMessage: nil)
    }

    private func saveProfiles(errorMessage message: String?) {
        do {
            try repository.saveProfiles(profiles)
            errorMessage = nil
        } catch {
            if let message { errorMessage = message }
        }
    }

    private func hideLauncherIfNeeded() {
        guard closeAfterOpening else { return }
        NotificationCenter.default.post(name: .hideLauncherWindow, object: nil)
    }

    private func prepareSharedConfiguration(for profile: ClaudeProfile) throws {
        guard !profile.isDefault else { return }
        guard let defaultProfile = profiles.first(where: \.isDefault) else { return }

        // Default Claude stores this mixed file beside ~/.claude, while an isolated
        // CLAUDE_CONFIG_DIR stores it inside that directory. Copy only MCP fields.
        _ = try sharedMCPConfigurationStore.prepare(
            sharedFile: URL(fileURLWithPath: defaultProfile.claudeConfigPath + ".json"),
            profileFile: URL(fileURLWithPath: profile.claudeConfigPath).appendingPathComponent(".claude.json"),
            backupRoot: repository.migrationBackupsRoot
                .appendingPathComponent(profile.id.uuidString)
                .appendingPathComponent("MCP Configuration")
        )

        _ = try sharedConfigurationParityStore.prepare(
            profileConfigPath: profile.claudeConfigPath,
            sharedConfigPath: defaultProfile.claudeConfigPath,
            backupRootPath: repository.migrationBackupsRoot
                .appendingPathComponent(profile.id.uuidString, isDirectory: true)
                .appendingPathComponent("Shared Configuration", isDirectory: true)
                .path
        )
        _ = try sharedProjectsStore.prepare(
            profileConfigPath: profile.claudeConfigPath,
            sharedConfigPath: defaultProfile.claudeConfigPath,
            backupRootPath: repository.migrationBackupsRoot
                .appendingPathComponent(profile.id.uuidString, isDirectory: true)
                .path
        )
    }

    private func prepareStoppedProfilesForSharedConfiguration() {
        var firstError: Error?
        for profile in profiles where !profile.isDefault && !profile.isArchived && !isRunning(profile) {
            do {
                try prepareSharedConfiguration(for: profile)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError {
            errorMessage = configurationPreparationErrorMessage(for: firstError)
        }
    }

    private func configurationPreparationErrorMessage(for error: Error) -> String {
        if let error = error as? SharedProjectsStoreError {
            return error.localizedDescription
        }
        if let error = error as? SharedConfigurationParityError {
            return error.localizedDescription
        }
        if let error = error as? SharedMCPConfigurationError {
            return error.localizedDescription
        }
        return "共有設定の準備に失敗しました。元の設定は保持しています。"
    }

    private func sharedConfigurationErrorMessage(for error: Error, fallback: String) -> String {
        if error is SharedProjectsStoreError || error is SharedConfigurationParityError || error is SharedMCPConfigurationError {
            return configurationPreparationErrorMessage(for: error)
        }
        return fallback
    }
}

extension Notification.Name {
    static let hideLauncherWindow = Notification.Name("hideLauncherWindow")
}

private struct ProfileRepository {
    private let fileManager = FileManager.default

    var supportRoot: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude Profiles Launcher", isDirectory: true)
    }

    private var profilesFile: URL {
        supportRoot.appendingPathComponent("profiles.json")
    }

    var migrationBackupsRoot: URL {
        supportRoot.appendingPathComponent("Migration Backups", isDirectory: true)
    }

    func loadProfiles() throws -> [ClaudeProfile] {
        try fileManager.createDirectory(at: supportRoot, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: profilesFile.path) {
            let profiles = try addingDefaultProfileIfNeeded(to: decodeProfiles(from: profilesFile))
            try saveProfiles(profiles)
            return profiles
        }

        let profiles = try makeDefaultProfiles()

        let migratedProfiles = try addingDefaultProfileIfNeeded(to: profiles)
        try saveProfiles(migratedProfiles)
        return migratedProfiles
    }

    func saveProfiles(_ profiles: [ClaudeProfile]) throws {
        try fileManager.createDirectory(at: supportRoot, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: profilesFile, options: .atomic)
    }

    func makeProfile(name: String, purpose: String, colorHex: String) throws -> ClaudeProfile {
        let id = UUID()
        let profileRoot = supportRoot
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        let userData = profileRoot.appendingPathComponent("user-data", isDirectory: true)
        let config = profileRoot.appendingPathComponent("claude-config", isDirectory: true)

        try fileManager.createDirectory(at: userData, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: config, withIntermediateDirectories: true)

        return ClaudeProfile(
            id: id,
            name: name,
            purpose: purpose,
            colorHex: colorHex,
            userDataPath: userData.path,
            claudeConfigPath: config.path
        )
    }

    private func makeDefaultProfiles() throws -> [ClaudeProfile] {
        [
            try makeProfile(name: "Claude 1", purpose: "実装", colorHex: "5968E8"),
            try makeProfile(name: "Claude 2", purpose: "調査", colorHex: "2F7D62")
        ]
    }

    private func addingDefaultProfileIfNeeded(to profiles: [ClaudeProfile]) throws -> [ClaudeProfile] {
        guard !profiles.contains(where: \.isDefault) else { return profiles }

        let defaultUserData = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Claude", isDirectory: true)
        let defaultConfig = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
        let defaultProfile = ClaudeProfile(
            id: UUID(uuidString: "CD000000-0000-4000-8000-000000000001")!,
            name: "いつものClaude",
            purpose: "通常プロファイル",
            colorHex: "D08954",
            userDataPath: defaultUserData.path,
            claudeConfigPath: defaultConfig.path,
            isDefault: true
        )
        return [defaultProfile] + profiles
    }

    private func decodeProfiles(from url: URL) throws -> [ClaudeProfile] {
        try JSONDecoder().decode([ClaudeProfile].self, from: Data(contentsOf: url))
    }
}

private struct ClaudeProcessScanner {
    func currentSnapshot() throws -> [ClaudeProcessSnapshot] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ScannerError.processListUnavailable
        }

        let text = String(decoding: data, as: UTF8.self)
        return ClaudeProcessParser.parse(text)
    }

    private enum ScannerError: Error {
        case processListUnavailable
    }
}

private struct ClaudeController {
    func launch(_ profile: ClaudeProfile) throws {
        if profile.isDefault {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", "-a", "Claude"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return
        }

        try FileManager.default.createDirectory(
            atPath: profile.userDataPath,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: profile.claudeConfigPath,
            withIntermediateDirectories: true
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-n",
            "-a", "Claude",
            "--env", "CLAUDE_CONFIG_DIR=\(profile.claudeConfigPath)",
            "--args", "--user-data-dir=\(profile.userDataPath)"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    @discardableResult
    func focus(pid: Int32) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: pid) else {
            return false
        }
        return application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    @discardableResult
    func terminate(pid: Int32) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: pid) else {
            return false
        }
        return application.terminate()
    }
}

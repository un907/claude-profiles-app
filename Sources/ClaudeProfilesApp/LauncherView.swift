import AppKit
import ClaudeProfilesCore
import SwiftUI

private enum LauncherSection: String, CaseIterable, Identifiable {
    case profiles
    case archive
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profiles: return "プロフィール"
        case .archive: return "アーカイブ"
        case .settings: return "設定"
        }
    }

    var icon: String {
        switch self {
        case .profiles: return "rectangle.stack"
        case .archive: return "archivebox"
        case .settings: return "gearshape"
        }
    }
}

private struct PendingProfileAction: Identifiable {
    enum Kind: String {
        case stop
        case restart
        case archive
    }

    let kind: Kind
    let profile: ClaudeProfile
    var id: String { "\(kind.rawValue)-\(profile.id.uuidString)" }
}

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @State private var selection: LauncherSection? = .profiles
    @State private var isAddingProfile = false
    @State private var editingProfile: ClaudeProfile?
    @State private var pendingAction: PendingProfileAction?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 178, ideal: 196, max: 220)
        } detail: {
            sectionContent
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 680, minHeight: 460)
        .onAppear { model.startMonitoring() }
        .onReceive(NotificationCenter.default.publisher(for: .hideLauncherWindow)) { _ in
            NSApp.keyWindow?.orderOut(nil)
        }
        .sheet(isPresented: $isAddingProfile) {
            ProfileEditorSheet(
                profile: nil,
                allProfiles: model.profiles,
                isCLIDirectoryOnLoginPath: model.isCLIDirectoryOnLoginPath
            ) { name, purpose, color, suffix in
                model.addProfile(name: name, purpose: purpose, colorHex: color, cliCommandSuffix: suffix)
            }
        }
        .sheet(item: $editingProfile) { profile in
            ProfileEditorSheet(
                profile: profile,
                allProfiles: model.profiles,
                isCLIDirectoryOnLoginPath: model.isCLIDirectoryOnLoginPath
            ) { name, purpose, color, suffix in
                model.updateProfile(
                    profile,
                    name: name,
                    purpose: purpose,
                    colorHex: color,
                    cliCommandSuffix: suffix
                )
            }
        }
        .alert(item: $pendingAction, content: confirmationAlert)
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                ForEach(LauncherSection.allCases) { section in
                    HStack {
                        Label(section.title, systemImage: section.icon)
                        Spacer()
                        if let badge = badge(for: section) {
                            Text("\(badge)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .tag(section)
                }
            }

            Section("状態") {
                LabeledContent {
                    Text(model.isClaudeInstalled ? "検出済み" : "未検出")
                        .foregroundStyle(.secondary)
                } label: {
                    Label("Claude", systemImage: "app.dashed")
                }

                LabeledContent {
                    Text("\(model.runningCount)件")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } label: {
                    Label("起動中", systemImage: "circle.fill")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Claude Profiles")
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selection ?? .profiles {
        case .profiles:
            ProfilesScreen(
                model: model,
                addProfile: { isAddingProfile = true },
                editProfile: { editingProfile = $0 },
                requestAction: { kind, profile in
                    pendingAction = PendingProfileAction(kind: kind, profile: profile)
                }
            )
        case .archive:
            ArchiveScreen(model: model)
        case .settings:
            SettingsScreen(model: model)
        }
    }

    private func badge(for section: LauncherSection) -> Int? {
        switch section {
        case .profiles:
            return model.activeProfiles.count
        case .archive:
            return model.archivedProfiles.isEmpty ? nil : model.archivedProfiles.count
        case .settings:
            return nil
        }
    }

    private func confirmationAlert(_ action: PendingProfileAction) -> Alert {
        switch action.kind {
        case .stop:
            return Alert(
                title: Text("\(action.profile.name)を終了しますか？"),
                message: Text("開いているClaudeウィンドウを通常終了します。"),
                primaryButton: .destructive(Text("終了")) { model.stop(action.profile) },
                secondaryButton: .cancel()
            )
        case .restart:
            return Alert(
                title: Text("\(action.profile.name)を再起動しますか？"),
                message: Text("いったん終了し、同じログイン環境でもう一度開きます。"),
                primaryButton: .default(Text("再起動")) { model.restart(action.profile) },
                secondaryButton: .cancel()
            )
        case .archive:
            return Alert(
                title: Text("\(action.profile.name)をアーカイブしますか？"),
                message: Text("一覧から隠すだけで、ログイン情報や保存データは削除しません。"),
                primaryButton: .default(Text("アーカイブ")) { model.archive(action.profile) },
                secondaryButton: .cancel()
            )
        }
    }
}

private struct ProfilesScreen: View {
    @ObservedObject var model: LauncherModel
    let addProfile: () -> Void
    let editProfile: (ClaudeProfile) -> Void
    let requestAction: (PendingProfileAction.Kind, ClaudeProfile) -> Void

    @State private var selectedProfileID: UUID?

    private var allRequested: Bool {
        model.activeProfiles.allSatisfy {
            model.isRunning($0) || model.isLaunching($0)
        }
    }

    var body: some View {
        Group {
            if model.activeProfiles.isEmpty {
                NativeEmptyState(
                    icon: "rectangle.stack.badge.plus",
                    title: "プロフィールがありません",
                    message: "ツールバーの追加ボタンからClaudeを登録できます。"
                )
            } else {
                List(selection: $selectedProfileID) {
                    if let error = model.errorMessage {
                        Section {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                    }

                    Section {
                        ForEach(model.activeProfiles) { profile in
                            NativeProfileRow(
                                profile: profile,
                                isRunning: model.isRunning(profile),
                                isLaunching: model.isLaunching(profile),
                                isStopping: model.isStopping(profile),
                                open: { model.open(profile) },
                                edit: { editProfile(profile) },
                                showStorage: { model.showStorage(for: profile) },
                                stop: { requestAction(.stop, profile) },
                                restart: { requestAction(.restart, profile) },
                                archive: { requestAction(.archive, profile) }
                            )
                            .tag(profile.id)
                        }
                    } header: {
                        Text("\(model.runningCount)／\(model.activeProfiles.count)件が起動中")
                            .monospacedDigit()
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("プロフィール")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.startAll()
                } label: {
                    Label(startAllTitle, systemImage: allRequested ? "checkmark" : "play.fill")
                }
                .disabled(model.activeProfiles.isEmpty || allRequested)

                Button(action: addProfile) {
                    Label("プロフィールを追加", systemImage: "plus")
                }
                .help("新しいClaudeを追加")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }

    private var startAllTitle: String {
        if !model.launchingProfileIDs.isEmpty { return "起動中" }
        if model.runningCount == model.activeProfiles.count { return "すべて起動済み" }
        if model.runningCount == 0 { return "すべて起動" }
        return "残り\(model.activeProfiles.count - model.runningCount)件を起動"
    }
}

private struct NativeProfileRow: View {
    let profile: ClaudeProfile
    let isRunning: Bool
    let isLaunching: Bool
    let isStopping: Bool
    let open: () -> Void
    let edit: () -> Void
    let showStorage: () -> Void
    let stop: () -> Void
    let restart: () -> Void
    let archive: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color(hex: profile.colorHex))
                .frame(width: 4, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    if profile.isDefault {
                        Text("標準")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("\(profile.purpose) ・ \(lastUsedText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // Terminal command, only when one is configured (never for the default
                // profile, which plain `claude` already serves).
                if !profile.isDefault, let suffix = profile.cliCommandSuffix {
                    Text(CLIShimStore.commandPrefix + suffix)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 12)

            StatusLabel(
                isRunning: isRunning,
                isLaunching: isLaunching,
                isStopping: isStopping
            )

            Button(action: open) {
                Label(
                    isLaunching ? "起動中" : (isRunning ? "表示" : "起動"),
                    systemImage: isRunning ? "arrow.up.forward.app" : "play.fill"
                )
            }
            .nativeProfileAction()
            .disabled(isLaunching || isStopping)

            Menu {
                Button("名前・用途・色を編集", systemImage: "pencil", action: edit)
                Button("保存場所をFinderで表示", systemImage: "folder", action: showStorage)

                if isRunning {
                    Divider()
                    Button("再起動…", systemImage: "arrow.clockwise", action: restart)
                    Button("終了…", systemImage: "power", role: .destructive, action: stop)
                }

                if !profile.isDefault {
                    Divider()
                    Button("アーカイブ…", systemImage: "archivebox", action: archive)
                        .disabled(isRunning || isLaunching || isStopping)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("プロフィールを管理")
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: open)
        .contextMenu {
            Button(isRunning ? "表示" : "起動", action: open)
            Button("編集…", action: edit)
            Button("保存場所を表示", action: showStorage)
            if isRunning {
                Divider()
                Button("再起動…", action: restart)
                Button("終了…", role: .destructive, action: stop)
            }
        }
    }

    private var lastUsedText: String {
        guard let date = profile.lastOpenedAt else { return "未使用" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct StatusLabel: View {
    let isRunning: Bool
    let isLaunching: Bool
    let isStopping: Bool

    var body: some View {
        HStack(spacing: 5) {
            if isLaunching || isStopping {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: isRunning ? "circle.fill" : "circle")
                    .font(.system(size: 7))
            }
            Text(statusText)
        }
        .font(.caption)
        .foregroundStyle(isRunning && !isStopping ? Color.green : Color.secondary)
        .frame(minWidth: 56, alignment: .leading)
    }

    private var statusText: String {
        if isStopping { return "終了中" }
        if isLaunching { return "起動中" }
        return isRunning ? "起動中" : "停止中"
    }
}

private struct ArchiveScreen: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        Group {
            if model.archivedProfiles.isEmpty {
                NativeEmptyState(
                    icon: "archivebox",
                    title: "アーカイブは空です",
                    message: "使わないプロフィールを隠すと、ここから復元できます。"
                )
            } else {
                List {
                    ForEach(model.archivedProfiles) { profile in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color(hex: profile.colorHex))
                                .frame(width: 9, height: 9)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                    .fontWeight(.medium)
                                Text("\(profile.purpose) ・ データ保持中")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button("復元") { model.restore(profile) }
                            Button {
                                model.showStorage(for: profile)
                            } label: {
                                Label("保存場所を表示", systemImage: "folder")
                            }
                            .labelStyle(.iconOnly)
                            .help("保存場所をFinderで表示")
                        }
                        .padding(.vertical, 5)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("アーカイブ")
    }
}

private struct SettingsScreen: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        Form {
            Section("ウィンドウ") {
                Toggle("Claudeを開いたらランチャーを閉じる", isOn: $model.closeAfterOpening)
                Text("メニューバーのアイコンから、いつでもプロフィールを起動できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("ターミナル") {
                TextField(
                    "CLIが呼び出すclaude",
                    text: $model.cliClaudeExecutable,
                    prompt: Text(CLIShimStore.defaultExecutable)
                )
                Text("プロフィールのCLIコマンドが起動するClaude Codeです。空欄ならPATH上のclaudeを使います。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("保存データ") {
                Text("プロフィール設定と追加したClaudeのログイン領域は、このMacだけに保存されます。")
                    .foregroundStyle(.secondary)
                Button("保存フォルダを開く", systemImage: "folder") {
                    model.showLauncherStorage()
                }
            }

            Section("プロフィール間の共有") {
                LabeledContent("Claude設定", value: "完全同期")
                LabeledContent("会話の記憶", value: "共有")
                Text("Agents・Rules・Skills・Hooks・権限設定・Pluginsを共通化します。認証とDesktopの履歴一覧はプロフィールごとに分かれます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("診断") {
                LabeledContent("Claude Desktop") {
                    NativeHealthValue(
                        value: model.isClaudeInstalled ? "検出済み" : "未検出",
                        isHealthy: model.isClaudeInstalled
                    )
                }
                LabeledContent("登録プロフィール", value: "\(model.activeProfiles.count)件")
                LabeledContent("起動中", value: "\(model.runningCount)件")
            }

            Section {
                LabeledContent("バージョン", value: appVersion)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("設定")
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}

private struct NativeHealthValue: View {
    let value: String
    let isHealthy: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isHealthy ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

private struct NativeEmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

private struct ProfileEditorSheet: View {
    let profile: ClaudeProfile?
    /// Every profile, used to reject a CLI suffix that another active profile already uses.
    let allProfiles: [ClaudeProfile]
    /// Result of the login-shell PATH check; only an explicit `false` shows the PATH note.
    let isCLIDirectoryOnLoginPath: Bool?
    /// name, purpose, color, CLI suffix (nil = no command).
    let onSave: (String, String, String, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var purpose: String
    @State private var selectedColor: String
    @State private var cliSuffix: String

    private let colors = ["5968E8", "2F7D62", "D08954", "A94F68", "6C5AA8"]

    init(
        profile: ClaudeProfile?,
        allProfiles: [ClaudeProfile],
        isCLIDirectoryOnLoginPath: Bool?,
        onSave: @escaping (String, String, String, String?) -> Void
    ) {
        self.profile = profile
        self.allProfiles = allProfiles
        self.isCLIDirectoryOnLoginPath = isCLIDirectoryOnLoginPath
        self.onSave = onSave
        _name = State(initialValue: profile?.name ?? "")
        _purpose = State(initialValue: profile?.purpose ?? "")
        _selectedColor = State(initialValue: profile?.colorHex ?? "5968E8")
        _cliSuffix = State(initialValue: profile?.cliCommandSuffix ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名前", text: $name, prompt: Text("例：レビュー用"))
                    TextField("用途", text: $purpose, prompt: Text("例：コードレビュー"))
                }

                Section("識別色") {
                    HStack(spacing: 12) {
                        ForEach(colors, id: \.self) { color in
                            Button {
                                selectedColor = color
                            } label: {
                                Circle()
                                    .fill(Color(hex: color))
                                    .frame(width: 22, height: 22)
                                    .overlay {
                                        if selectedColor == color {
                                            Image(systemName: "checkmark")
                                                .font(.caption.bold())
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("識別色")
                            .accessibilityAddTraits(selectedColor == color ? .isSelected : [])
                        }
                    }
                }

                // The default profile is served by plain `claude`, so it gets no command.
                if profile?.isDefault != true {
                    cliCommandSection
                }

                Section {
                    Text(
                        profile == nil
                            ? "独立したログイン領域を作成します。初回起動後、その画面でログインしてください。"
                            : "ログイン情報や保存データは変更されません。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(profile == nil ? "新しいプロフィール" : "プロフィールを編集")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(profile == nil ? "作成" : "保存") {
                        onSave(
                            trimmedName,
                            trimmedPurpose,
                            selectedColor,
                            trimmedSuffix.isEmpty ? nil : trimmedSuffix
                        )
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || trimmedPurpose.isEmpty || suffixProblem != nil)
                }
            }
        }
        // Taller than before to fit the CLI command section.
        .frame(width: 480, height: profile?.isDefault == true ? 330 : 470)
    }

    /// "claude-" fixed label + suffix field, with the validation reason, a one-line
    /// explanation, and a PATH note when ~/.local/bin is not on the login shell's PATH.
    private var cliCommandSection: some View {
        Section("CLIコマンド") {
            HStack(spacing: 0) {
                Text(CLIShimStore.commandPrefix)
                    .monospaced()
                    .foregroundStyle(.secondary)
                TextField("CLIコマンド", text: $cliSuffix, prompt: Text("例：review"))
                    .labelsHidden()
                    .monospaced()
                    .autocorrectionDisabled()
            }

            if let message = suffixProblemMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(
                trimmedSuffix.isEmpty
                    ? "名前を入れると、ターミナルからこのプロフィールでClaude Codeを起動できます。"
                    : "ターミナルで\(CLIShimStore.commandPrefix)\(trimmedSuffix)と打つとこのプロフィールでClaude Codeが起動します。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if isCLIDirectoryOnLoginPath == false {
                Text("~/.local/binがログインシェルのPATHに含まれていないため、PATHへの追加が必要です。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var trimmedSuffix: String {
        cliSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Why the typed suffix cannot be saved, or nil when it is fine (empty is fine).
    private var suffixProblem: CLICommandSuffixProblem? {
        CLIShimStore.problem(forSuffix: trimmedSuffix, profileID: profile?.id, among: allProfiles)
    }

    private var suffixProblemMessage: String? {
        switch suffixProblem {
        case .invalidFormat:
            return "英数字で始め、英数字と . _ - だけを使った41文字以内で入力してください。"
        case .duplicate:
            return "\(CLIShimStore.commandPrefix)\(trimmedSuffix)は別のプロフィールで使われています。"
        case nil:
            return nil
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedPurpose: String {
        purpose.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension View {
    /// Styles the per-profile primary action ("起動" / "表示") as a standard prominent
    /// macOS button using the system accent color.
    ///
    /// The profile's own color is deliberately NOT used as the button tint: saturated
    /// per-profile tints on a prominent (glass) button looked garish in dark mode, and
    /// standard macOS apps keep primary buttons on the accent color anyway. The profile
    /// color stays on the card's rail and swatch, which is enough to tell profiles apart.
    @ViewBuilder
    func nativeProfileAction() -> some View {
        if #available(macOS 26.0, *) {
            self
                .buttonStyle(.glassProminent)
                .controlSize(.small)
        } else {
            self
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }
}

private extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}

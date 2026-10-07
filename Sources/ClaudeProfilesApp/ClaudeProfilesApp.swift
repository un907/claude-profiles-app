// App entry point for Claude Profiles.
//
// Declares the two scenes (the profile management window and the menu-bar extra),
// the single-instance guard (LauncherAppDelegate), and the Sparkle 2 updater that
// checks the GitHub Releases appcast configured in Info.plist (SUFeedURL).

import AppKit
import Darwin
import Sparkle
import SwiftUI

@main
struct ClaudeProfilesApp: App {
    @NSApplicationDelegateAdaptor(LauncherAppDelegate.self) private var appDelegate
    @StateObject private var model = LauncherModel.shared

    /// The one Sparkle updater for the app's lifetime.
    ///
    /// Held on the App struct (Sparkle's documented SwiftUI pattern) rather than in the
    /// delegate, so the delegate stays limited to the single-instance lock. With
    /// `startingUpdater: true` Sparkle begins its scheduled checks right away, using the
    /// SUFeedURL / SUPublicEDKey / SUScheduledCheckInterval keys from Info.plist.
    /// A duplicate launch also constructs this briefly before the lock check terminates
    /// it; that is harmless because no check runs within that window.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        Window("Claude Profiles", id: "launcher") {
            LauncherView(model: model)
        }
        .defaultSize(width: 760, height: 520)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarCommandsView(model: model, updaterController: updaterController)
        } label: {
            Image(systemName: model.runningCount > 0
                ? "square.stack.3d.up.fill"
                : "square.stack.3d.up")
            .accessibilityLabel("Claude Profiles")
        }
        .menuBarExtraStyle(.menu)
    }
}

private final class LauncherAppDelegate: NSObject, NSApplicationDelegate {
    private var lockFileDescriptor: Int32 = -1

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard acquireSingleInstanceLock() else {
            activateExistingInstance()
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
            return
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard lockFileDescriptor >= 0 else { return }
        flock(lockFileDescriptor, LOCK_UN)
        Darwin.close(lockFileDescriptor)
        lockFileDescriptor = -1
    }

    private func acquireSingleInstanceLock() -> Bool {
        let fileManager = FileManager.default
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return fallbackHasNoExistingInstance()
        }

        let supportRoot = applicationSupport
            .appendingPathComponent("Claude Profiles Launcher", isDirectory: true)
        do {
            try fileManager.createDirectory(at: supportRoot, withIntermediateDirectories: true)
        } catch {
            return fallbackHasNoExistingInstance()
        }

        let lockPath = supportRoot.appendingPathComponent("launcher.lock").path
        let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            return fallbackHasNoExistingInstance()
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return false
        }
        lockFileDescriptor = descriptor
        return true
    }

    private func fallbackHasNoExistingInstance() -> Bool {
        // The fallback ID only matters when running the bare SwiftPM binary (no bundle);
        // it mirrors CFBundleIdentifier in Resources/Info.plist.
        NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "io.github.un907.claudeprofiles"
        ).allSatisfy { $0.processIdentifier == ProcessInfo.processInfo.processIdentifier }
    }

    private func activateExistingInstance() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "io.github.un907.claudeprofiles"
        )
        .first { $0.processIdentifier != currentPID }?
        .activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }
}

private struct MenuBarCommandsView: View {
    @ObservedObject var model: LauncherModel
    /// Shared updater owned by ClaudeProfilesApp; used for the manual update check item.
    let updaterController: SPUStandardUpdaterController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(model.activeProfiles) { profile in
            Button {
                model.open(profile)
            } label: {
                Label(
                    model.isRunning(profile)
                        ? "\(profile.name)を表示"
                        : "\(profile.name)を起動",
                    systemImage: model.isRunning(profile)
                        ? "circle.fill"
                        : "play"
                )
            }
            .disabled(model.isLaunching(profile) || model.isStopping(profile))
        }

        Divider()

        Button("残りをすべて起動", systemImage: "play.fill") {
            model.startAll()
        }
        .disabled(remainingProfileCount == 0)

        Divider()

        Button("プロフィールを管理…", systemImage: "macwindow") {
            openWindow(id: "launcher")
            NSApp.activate(ignoringOtherApps: true)
        }

        // Manual update check. The app is LSUIElement (no Dock icon), so activate it
        // first; otherwise Sparkle's update window can open behind the frontmost app.
        Button("アップデートを確認…", systemImage: "arrow.triangle.2.circlepath") {
            NSApp.activate(ignoringOtherApps: true)
            updaterController.checkForUpdates(nil)
        }

        Button("Claude Profilesを終了", systemImage: "power") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private var remainingProfileCount: Int {
        model.activeProfiles.filter {
            !model.isRunning($0) && !model.isLaunching($0)
        }.count
    }
}

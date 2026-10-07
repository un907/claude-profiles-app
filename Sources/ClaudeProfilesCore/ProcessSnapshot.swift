import Foundation

public struct ClaudeProcessSnapshot: Equatable, Sendable {
    public let pid: Int32
    public let command: String

    public init(pid: Int32, command: String) {
        self.pid = pid
        self.command = command
    }
}

public enum ClaudeProcessParser {
    private static let executablePrefix = "/Applications/Claude.app/Contents/MacOS/Claude"

    public static func parse(_ output: String) -> [ClaudeProcessSnapshot] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard
                parts.count == 2,
                let pid = Int32(parts[0])
            else {
                return nil
            }

            let command = String(parts[1])
            guard command == executablePrefix || command.hasPrefix(executablePrefix + " ") else {
                return nil
            }

            return ClaudeProcessSnapshot(pid: pid, command: command)
        }
    }

    public static func pid(
        forUserDataPath path: String,
        in snapshots: [ClaudeProcessSnapshot]
    ) -> Int32? {
        snapshots.first(where: { containsArgument($0.command, value: path) })?.pid
    }

    public static func defaultProfilePID(in snapshots: [ClaudeProcessSnapshot]) -> Int32? {
        snapshots.first(where: { !$0.command.contains("--user-data-dir=") })?.pid
    }

    private static func containsArgument(_ command: String, value: String) -> Bool {
        let argument = "--user-data-dir=\(value)"
        guard let range = command.range(of: argument) else {
            return false
        }

        guard range.upperBound != command.endIndex else {
            return true
        }

        return command[range.upperBound].isWhitespace
    }
}

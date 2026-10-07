// A launchable Claude Desktop profile as stored in profiles.json.

import Foundation

public struct ClaudeProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var purpose: String
    public var colorHex: String
    public var userDataPath: String
    public var claudeConfigPath: String
    public var isDefault: Bool
    public var isArchived: Bool
    public var lastOpenedAt: Date?
    /// Suffix of the terminal command `claude-<suffix>` for this profile, or nil when the
    /// profile has no command (see CLIShimStore). Optional so profiles.json files written
    /// before this field existed still decode.
    public var cliCommandSuffix: String?

    public init(
        id: UUID = UUID(),
        name: String,
        purpose: String,
        colorHex: String,
        userDataPath: String,
        claudeConfigPath: String,
        isDefault: Bool = false,
        isArchived: Bool = false,
        lastOpenedAt: Date? = nil,
        cliCommandSuffix: String? = nil
    ) {
        self.id = id
        self.name = name
        self.purpose = purpose
        self.colorHex = colorHex
        self.userDataPath = userDataPath
        self.claudeConfigPath = claudeConfigPath
        self.isDefault = isDefault
        self.isArchived = isArchived
        self.lastOpenedAt = lastOpenedAt
        self.cliCommandSuffix = cliCommandSuffix
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, purpose, colorHex, userDataPath, claudeConfigPath
        case isDefault, isArchived, lastOpenedAt, cliCommandSuffix
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        purpose = try container.decode(String.self, forKey: .purpose)
        colorHex = try container.decode(String.self, forKey: .colorHex)
        userDataPath = try container.decode(String.self, forKey: .userDataPath)
        claudeConfigPath = try container.decode(String.self, forKey: .claudeConfigPath)
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        lastOpenedAt = try container.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        cliCommandSuffix = try container.decodeIfPresent(String.self, forKey: .cliCommandSuffix)
    }
}

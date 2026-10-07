import Foundation

public struct SharedProjectsPreparation: Equatable, Sendable {
    public let importedFileCount: Int
    public let backupPath: String?
    public let wasAlreadyShared: Bool

    public init(
        importedFileCount: Int,
        backupPath: String?,
        wasAlreadyShared: Bool
    ) {
        self.importedFileCount = importedFileCount
        self.backupPath = backupPath
        self.wasAlreadyShared = wasAlreadyShared
    }
}

public enum SharedProjectsStoreError: LocalizedError, Equatable, Sendable {
    case conflictingItem(String)
    case projectsLinkPointsElsewhere(String)
    case unsupportedProjectsItem(String)

    public var errorDescription: String? {
        switch self {
        case .conflictingItem(let path):
            return "同じIDで内容が異なる履歴（\(path)）があります。履歴は変更していません。"
        case .projectsLinkPointsElsewhere(let path):
            return "既存の履歴リンクが別の保存先を指しています（\(path)）。"
        case .unsupportedProjectsItem(let path):
            return "履歴保存先の形式を確認できません（\(path)）。"
        }
    }
}

public struct SharedProjectsStore {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Makes a profile use the default profile's complete `projects` directory.
    /// Existing profile data is merged only after a conflict-free preflight and
    /// is retained in a timestamp-independent UUID backup directory.
    public func prepare(
        profileConfigPath: String,
        sharedConfigPath: String,
        backupRootPath: String
    ) throws -> SharedProjectsPreparation {
        let profileConfig = URL(fileURLWithPath: profileConfigPath, isDirectory: true)
        let sharedConfig = URL(fileURLWithPath: sharedConfigPath, isDirectory: true)
        let profileProjects = profileConfig.appendingPathComponent("projects", isDirectory: true)
        let sharedProjects = sharedConfig.appendingPathComponent("projects", isDirectory: true)

        if normalized(profileProjects) == normalized(sharedProjects) {
            return SharedProjectsPreparation(
                importedFileCount: 0,
                backupPath: nil,
                wasAlreadyShared: true
            )
        }

        try fileManager.createDirectory(at: sharedProjects, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: profileConfig, withIntermediateDirectories: true)

        switch try itemType(at: profileProjects) {
        case nil:
            try fileManager.createSymbolicLink(
                atPath: profileProjects.path,
                withDestinationPath: sharedProjects.path
            )
            return SharedProjectsPreparation(
                importedFileCount: 0,
                backupPath: nil,
                wasAlreadyShared: false
            )

        case .typeSymbolicLink:
            guard try resolvedLink(at: profileProjects) == normalized(sharedProjects) else {
                throw SharedProjectsStoreError.projectsLinkPointsElsewhere(profileProjects.path)
            }
            return SharedProjectsPreparation(
                importedFileCount: 0,
                backupPath: nil,
                wasAlreadyShared: true
            )

        case .typeDirectory:
            let items = try fileManager.contentsOfDirectory(
                at: profileProjects,
                includingPropertiesForKeys: nil
            )
            if items.isEmpty {
                try fileManager.removeItem(at: profileProjects)
                try fileManager.createSymbolicLink(
                    atPath: profileProjects.path,
                    withDestinationPath: sharedProjects.path
                )
                return SharedProjectsPreparation(
                    importedFileCount: 0,
                    backupPath: nil,
                    wasAlreadyShared: false
                )
            }

            try validateMerge(source: profileProjects, destination: sharedProjects, relativePath: "")

            let backupRoot = URL(fileURLWithPath: backupRootPath, isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let backupProjects = backupRoot.appendingPathComponent("projects", isDirectory: true)
            try fileManager.createDirectory(
                at: backupRoot.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)
            try fileManager.moveItem(at: profileProjects, to: backupProjects)

            do {
                let importedFileCount = try merge(
                    source: backupProjects,
                    destination: sharedProjects
                )
                try fileManager.createSymbolicLink(
                    atPath: profileProjects.path,
                    withDestinationPath: sharedProjects.path
                )
                return SharedProjectsPreparation(
                    importedFileCount: importedFileCount,
                    backupPath: backupProjects.path,
                    wasAlreadyShared: false
                )
            } catch {
                if try itemType(at: profileProjects) != nil {
                    try? fileManager.removeItem(at: profileProjects)
                }
                if try itemType(at: profileProjects) == nil {
                    try? fileManager.moveItem(at: backupProjects, to: profileProjects)
                }
                throw error
            }

        default:
            throw SharedProjectsStoreError.unsupportedProjectsItem(profileProjects.path)
        }
    }

    private func validateMerge(
        source: URL,
        destination: URL,
        relativePath: String
    ) throws {
        for sourceItem in try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil
        ) {
            let name = sourceItem.lastPathComponent
            let itemRelativePath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
            let destinationItem = destination.appendingPathComponent(name)
            guard let destinationType = try itemType(at: destinationItem) else { continue }
            guard let sourceType = try itemType(at: sourceItem) else { continue }

            if sourceType == .typeDirectory, try isEmptyDirectory(sourceItem) {
                continue
            } else if sourceType == .typeDirectory, destinationType == .typeDirectory {
                try validateMerge(
                    source: sourceItem,
                    destination: destinationItem,
                    relativePath: itemRelativePath
                )
            } else if sourceType == .typeRegular,
                      destinationType == .typeRegular,
                      fileManager.contentsEqual(
                        atPath: sourceItem.path,
                        andPath: destinationItem.path
                      ) {
                continue
            } else if sourceType == .typeSymbolicLink,
                      destinationType == .typeSymbolicLink,
                      try resolvedLink(at: sourceItem) == resolvedLink(at: destinationItem) {
                continue
            } else {
                throw SharedProjectsStoreError.conflictingItem(itemRelativePath)
            }
        }
    }

    private func merge(source: URL, destination: URL) throws -> Int {
        var importedFileCount = 0

        for sourceItem in try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil
        ) {
            let destinationItem = destination.appendingPathComponent(sourceItem.lastPathComponent)
            guard let destinationType = try itemType(at: destinationItem) else {
                try fileManager.copyItem(at: sourceItem, to: destinationItem)
                importedFileCount += try regularFileCount(at: sourceItem)
                continue
            }
            guard let sourceType = try itemType(at: sourceItem) else { continue }

            if sourceType == .typeDirectory, try isEmptyDirectory(sourceItem) {
                continue
            } else if sourceType == .typeDirectory, destinationType == .typeDirectory {
                importedFileCount += try merge(source: sourceItem, destination: destinationItem)
            } else if sourceType == .typeRegular,
                      destinationType == .typeRegular,
                      fileManager.contentsEqual(
                        atPath: sourceItem.path,
                        andPath: destinationItem.path
                      ) {
                continue
            } else if sourceType == .typeSymbolicLink,
                      destinationType == .typeSymbolicLink,
                      try resolvedLink(at: sourceItem) == resolvedLink(at: destinationItem) {
                continue
            } else {
                throw SharedProjectsStoreError.conflictingItem(sourceItem.lastPathComponent)
            }
        }

        return importedFileCount
    }

    private func regularFileCount(at url: URL) throws -> Int {
        guard let type = try itemType(at: url) else { return 0 }
        if type == .typeRegular { return 1 }
        guard type == .typeDirectory else { return 0 }

        return try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        ).reduce(0) { count, item in
            count + (try regularFileCount(at: item))
        }
    }

    private func isEmptyDirectory(_ url: URL) throws -> Bool {
        try fileManager.contentsOfDirectory(atPath: url.path).isEmpty
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
            destinationURL = URL(fileURLWithPath: destination, isDirectory: true)
        } else {
            destinationURL = url.deletingLastPathComponent()
                .appendingPathComponent(destination, isDirectory: true)
        }
        return normalized(destinationURL)
    }

    private func normalized(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

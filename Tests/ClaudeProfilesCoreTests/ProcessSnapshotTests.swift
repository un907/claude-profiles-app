import XCTest
@testable import ClaudeProfilesCore

final class ProcessSnapshotTests: XCTestCase {
    func testParsesOnlyClaudeMainProcesses() {
        let output = """
          100 /Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=/tmp/profile-1
          101 /Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper --user-data-dir=/tmp/profile-1
          102 /bin/zsh -c ps -axo pid=,command=
          103 /Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=/tmp/profile-2
        """

        XCTAssertEqual(
            ClaudeProcessParser.parse(output).map(\.pid),
            [100, 103]
        )
    }

    func testFindsExactProfileAndAvoidsPrefixCollision() {
        let snapshots = [
            ClaudeProcessSnapshot(
                pid: 200,
                command: "/Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=/tmp/profile-10"
            ),
            ClaudeProcessSnapshot(
                pid: 201,
                command: "/Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=/tmp/profile-1"
            )
        ]

        XCTAssertEqual(
            ClaudeProcessParser.pid(forUserDataPath: "/tmp/profile-1", in: snapshots),
            201
        )
    }

    func testMatchesProfilePathContainingSpaces() {
        let snapshots = [
            ClaudeProcessSnapshot(
                pid: 300,
                command: "/Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=/Users/me/Library/Application Support/Profile A"
            )
        ]

        XCTAssertEqual(
            ClaudeProcessParser.pid(
                forUserDataPath: "/Users/me/Library/Application Support/Profile A",
                in: snapshots
            ),
            300
        )
    }

    func testFindsDefaultProfileWithoutUserDataArgument() {
        let snapshots = [
            ClaudeProcessSnapshot(
                pid: 400,
                command: "/Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=/tmp/profile-1"
            ),
            ClaudeProcessSnapshot(
                pid: 401,
                command: "/Applications/Claude.app/Contents/MacOS/Claude"
            )
        ]

        XCTAssertEqual(ClaudeProcessParser.defaultProfilePID(in: snapshots), 401)
    }

    func testDecodesLegacyProfileAsNonDefault() throws {
        let data = Data("""
        {
          "id": "B6C072BB-3766-46CF-9665-3A9347AECE32",
          "name": "Claude 1",
          "purpose": "実装",
          "colorHex": "5968E8",
          "userDataPath": "/tmp/profile-1",
          "claudeConfigPath": "/tmp/config-1"
        }
        """.utf8)

        let profile = try JSONDecoder().decode(ClaudeProfile.self, from: data)
        XCTAssertFalse(profile.isDefault)
        XCTAssertFalse(profile.isArchived)
        XCTAssertNil(profile.lastOpenedAt)
    }

    func testRoundTripsProfileManagementFields() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let profile = ClaudeProfile(
            name: "Review",
            purpose: "Code review",
            colorHex: "5968E8",
            userDataPath: "/tmp/profile",
            claudeConfigPath: "/tmp/config",
            isArchived: true,
            lastOpenedAt: date
        )

        let decoded = try JSONDecoder().decode(
            ClaudeProfile.self,
            from: JSONEncoder().encode(profile)
        )

        XCTAssertEqual(decoded, profile)
    }
}

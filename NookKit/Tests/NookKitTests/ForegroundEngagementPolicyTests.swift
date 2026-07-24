import Testing
@testable import NookKit

@Suite("Foreground engagement policy")
struct ForegroundEngagementPolicyTests {
    private let policy = ForegroundEngagementPolicy(inactivityInterval: 600)

    @Test("A visible reader with recent input is engaged")
    func recentReaderActivity() {
        #expect(policy.isEngaged(
            appIsActive: true,
            readerWindowIsAttended: true,
            sessionIsActive: true,
            secondsSinceLastInput: 599
        ))
    }

    @Test("An idle frontmost app yields foreground ownership")
    func idleAppYields() {
        #expect(!policy.isEngaged(
            appIsActive: true,
            readerWindowIsAttended: true,
            sessionIsActive: true,
            secondsSinceLastInput: 600
        ))
    }

    @Test(arguments: [
        (false, true, true),
        (true, false, true),
        (true, true, false),
    ])
    func everyPresenceSignalIsRequired(
        appIsActive: Bool,
        readerWindowIsAttended: Bool,
        sessionIsActive: Bool
    ) {
        #expect(!policy.isEngaged(
            appIsActive: appIsActive,
            readerWindowIsAttended: readerWindowIsAttended,
            sessionIsActive: sessionIsActive,
            secondsSinceLastInput: 0
        ))
    }

    @Test("Invalid idle samples fail closed")
    func invalidIdleSamples() {
        #expect(!policy.isEngaged(
            appIsActive: true,
            readerWindowIsAttended: true,
            sessionIsActive: true,
            secondsSinceLastInput: .infinity
        ))
        #expect(!policy.isEngaged(
            appIsActive: true,
            readerWindowIsAttended: true,
            sessionIsActive: true,
            secondsSinceLastInput: -1
        ))
    }
}

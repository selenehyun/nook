import Foundation

/// Decides whether a desktop reader is genuinely being attended, rather than
/// merely remaining the frontmost process while its user is away.
///
/// This is deliberately platform-neutral so the policy can be tested without
/// AppKit. The macOS app supplies its activation, reader-window, login-session,
/// and system-idle signals.
public struct ForegroundEngagementPolicy: Sendable, Equatable {
    /// Long enough to read without touching the keyboard or trackpad, while still
    /// allowing a Mac left on a desk to yield notification ownership to iPhone.
    public static let readerFriendlyInactivityInterval: TimeInterval = 10 * 60

    public var inactivityInterval: TimeInterval

    public init(inactivityInterval: TimeInterval = Self.readerFriendlyInactivityInterval) {
        self.inactivityInterval = inactivityInterval
    }

    public func isEngaged(
        appIsActive: Bool,
        readerWindowIsAttended: Bool,
        sessionIsActive: Bool,
        secondsSinceLastInput: TimeInterval
    ) -> Bool {
        guard appIsActive, readerWindowIsAttended, sessionIsActive else { return false }
        guard secondsSinceLastInput.isFinite, secondsSinceLastInput >= 0 else { return false }
        return secondsSinceLastInput < inactivityInterval
    }
}

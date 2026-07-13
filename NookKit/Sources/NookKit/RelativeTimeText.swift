import SwiftUI

/// A relative timestamp ("5 minutes ago") that keeps itself current.
///
/// `Text(date, format: .relative(…))` computes its string once, at body
/// evaluation, and never refreshes on its own — so in a list the value goes
/// stale and only jumps to the correct time when something unrelated (a row
/// selection) forces a re-render. Wrapping it in `TimelineView(.everyMinute)`
/// recomputes it against the current time on every minute boundary instead.
///
/// It stays cheap because `TimelineView` only schedules ticks for on-screen
/// content: in a lazily-rendered list, off-screen rows hold no timer, and each
/// tick re-renders just this small text — not the whole row or list. Font,
/// foreground style, and locale are inherited from the environment, so it reads
/// identically to the plain `Text` it replaces.
public struct RelativeTimeText: View {
    private let date: Date
    private let presentation: Date.RelativeFormatStyle.Presentation

    public init(_ date: Date, presentation: Date.RelativeFormatStyle.Presentation = .named) {
        self.date = date
        self.presentation = presentation
    }

    public var body: some View {
        TimelineView(.everyMinute) { _ in
            Text(date, format: .relative(presentation: presentation))
        }
    }
}

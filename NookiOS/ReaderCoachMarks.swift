import SwiftUI
import UIKit

// MARK: - Spotlight scrim

extension View {
    /// Punches the mask shape OUT of this view (the shape's area becomes
    /// transparent) — used to cut a spotlight hole in a dimming scrim.
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay { mask().blendMode(.destinationOut) }
                // destinationOut must composite within its own layer, or the hole
                // isn't punched (and the whole scrim can render wrong).
                .compositingGroup()
        }
    }
}

/// A dimming scrim, optionally with a rounded-rectangle spotlight cut out over a
/// target region. Never takes touches, so the real control inside the spotlight
/// stays usable and the taught gesture can be performed live.
struct CoachScrim: View {
    var spotlight: CGRect?
    var cornerRadius: CGFloat = 20

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .reverseMask {
                    if let spotlight {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .frame(width: spotlight.width, height: spotlight.height)
                            .position(x: spotlight.midX, y: spotlight.midY)
                    }
                }

            if let spotlight {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.9), lineWidth: 2)
                    .frame(width: spotlight.width, height: spotlight.height)
                    .position(x: spotlight.midX, y: spotlight.midY)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The callout card shown by the coach marks: an optional icon, a title, a short
/// message, and the advance / skip controls.
struct CoachCallout: View {
    var systemImage: String? = nil
    var title: LocalizedStringKey
    var message: LocalizedStringKey
    var primaryTitle: LocalizedStringKey
    var onPrimary: () -> Void
    var onSkip: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .semibold))
                    // Nook's signature accent (the asset), not the environment's
                    // default tint which can fall back to system blue here.
                    .foregroundStyle(Color("AccentColor"))
            }
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if let onSkip {
                    Button(action: onSkip) {
                        Text("Skip")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.bordered)
                }
                Button(action: onPrimary) {
                    Text(primaryTitle)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 2)
        }
        .padding(18)
        .frame(maxWidth: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
        .padding(.horizontal, 24)
    }
}

// MARK: - Gesture demo animations (shown over a full dim)

/// A looping double-tap demonstration: a finger taps twice, then a star pops in.
private struct DoubleTapDemo: View {
    var body: some View {
        PhaseAnimator([0, 1, 2, 3, 4]) { p in
            ZStack {
                Image(systemName: "star.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.yellow)
                    .scaleEffect(p >= 3 ? 1 : 0.2)
                    .opacity(p >= 3 ? 1 : 0)
                    .offset(y: -34)
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.white)
                    .scaleEffect(p == 1 || p == 2 ? 0.82 : 1.0)
                    .offset(y: 14)
            }
            .frame(height: 150)
        } animation: { p in
            switch p {
            case 1, 2: .easeInOut(duration: 0.16)
            case 3: .spring(response: 0.35, dampingFraction: 0.5)
            default: .easeInOut(duration: 0.5)
            }
        }
    }
}

/// A looping "pull up" demonstration: chevrons and a hand rise upward.
private struct PullUpDemo: View {
    var body: some View {
        PhaseAnimator([0, 1]) { p in
            VStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Image(systemName: "chevron.up")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9 - Double(i) * 0.22))
                }
                Image(systemName: "hand.point.up.left.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.white)
                    .padding(.top, 4)
            }
            .frame(height: 150)
            .offset(y: p == 1 ? -24 : 12)
            .opacity(p == 1 ? 0.45 : 1)
        } animation: { _ in .easeInOut(duration: 0.9) }
    }
}

/// A looping "swipe from the left" demonstration: a chevron and hand slide right.
private struct SwipeBackDemo: View {
    var body: some View {
        PhaseAnimator([0, 1]) { p in
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                Image(systemName: "hand.point.up.left.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.white)
            }
            .frame(height: 150)
            .offset(x: p == 1 ? 44 : -24)
            .opacity(p == 1 ? 0.5 : 1)
        } animation: { _ in .easeInOut(duration: 0.9) }
    }
}

// MARK: - Reader coach marks

/// The ordered steps of the first-open reader walkthrough.
enum ReaderCoachStep: Int, CaseIterable, Hashable {
    case star, pullNext, original, back

    var next: ReaderCoachStep? { ReaderCoachStep(rawValue: rawValue + 1) }
}

/// The interactive reader coach marks over the real reader. Gesture steps
/// (double-tap star, pull-to-next, swipe-back) use a full dim plus a looping
/// animation that demonstrates the gesture — no spotlight. Only the "read the
/// original" step spotlights a real control (the bottom document button, whose
/// exact frame is passed in from an anchor). Each step advances on the real
/// action (the parent wires those) or the "Next" button; "Skip" ends it. The
/// scrim never takes touches, so the gesture can be tried live.
struct ReaderCoachMarks: View {
    @Binding var step: ReaderCoachStep?
    /// The full-screen space to lay out in (from the hosting overlay's geometry).
    var size: CGSize
    /// The document button's resolved frame (from its anchor); nil falls back to
    /// an approximate bottom-trailing region.
    var originalButtonRect: CGRect?
    var onNext: (ReaderCoachStep) -> Void
    var onSkip: () -> Void

    var body: some View {
        ZStack {
            if let step {
                scrim(step)
                content(step)
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.easeInOut(duration: 0.28), value: step)
    }

    private var fallbackOriginalRect: CGRect {
        CGRect(x: size.width - 74, y: size.height - 86, width: 58, height: 46)
    }

    @ViewBuilder
    private func scrim(_ step: ReaderCoachStep) -> some View {
        if step == .original {
            let rect = (originalButtonRect ?? fallbackOriginalRect).insetBy(dx: -10, dy: -8)
            CoachScrim(spotlight: rect, cornerRadius: min(rect.width, rect.height) / 2)
        } else {
            Rectangle().fill(Color.black.opacity(0.55)).allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func content(_ step: ReaderCoachStep) -> some View {
        switch step {
        case .star:
            VStack(spacing: 24) {
                Spacer()
                DoubleTapDemo()
                Spacer()
                calloutCard(step)
            }
            // Clear the bottom bar (toolbar + home indicator) so the card doesn't
            // overlap it.
            .padding(.bottom, 116)
        case .pullNext:
            VStack(spacing: 24) {
                calloutCard(step)
                Spacer()
                PullUpDemo()
                Spacer().frame(height: 40)
            }
            .padding(.top, 140)
        case .back:
            VStack(spacing: 24) {
                calloutCard(step)
                Spacer()
                SwipeBackDemo()
                Spacer()
            }
            .padding(.top, 140)
        case .original:
            VStack {
                calloutCard(step)
                Spacer()
            }
            // Clear the top navigation bar (its trailing buttons) so the card
            // doesn't overlap them.
            .padding(.top, 140)
        }
    }

    @ViewBuilder
    private func calloutCard(_ step: ReaderCoachStep) -> some View {
        switch step {
        case .star:
            CoachCallout(
                title: "Star what you love",
                message: "Double-tap anywhere on the article to star it — try it now, or tap Next.",
                primaryTitle: "Next", onPrimary: { onNext(.star) }, onSkip: onSkip
            )
        case .pullNext:
            CoachCallout(
                title: "On to the next",
                message: "At the end of a story, keep pulling up past the bottom to jump to the next one.",
                primaryTitle: "Next", onPrimary: { onNext(.pullNext) }, onSkip: onSkip
            )
        case .original:
            CoachCallout(
                systemImage: "doc.plaintext",
                title: "Read the original",
                message: "Tap the highlighted button to open the full web page — with a reader view and translation.",
                primaryTitle: "Next", onPrimary: { onNext(.original) }, onSkip: onSkip
            )
        case .back:
            CoachCallout(
                title: "Back to your list",
                message: "Swipe in from the left edge to return to the article list. That's everything — enjoy Nook!",
                primaryTitle: "Done", onPrimary: { onNext(.back) }
            )
        }
    }
}

// MARK: - Frame measurement (real control positions for accurate spotlights)

/// The measured global frame of the article list's first row.
struct FirstRowFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

extension View {
    /// Reports the window-space frame of the nearest enclosing control. Use this
    /// for a control hosted in a UIKit-backed `.toolbar` (e.g. `.bottomBar`),
    /// where SwiftUI preferences/anchors don't propagate to the content view and a
    /// GeometryReader would measure the wrong coordinate space.
    func reportToolbarButtonFrame(_ onChange: @escaping (CGRect) -> Void) -> some View {
        background(ToolbarButtonFrameReporter(onChange: onChange))
    }
}

/// Bridges out of a UIKit-hosted toolbar: finds the nearest enclosing `UIControl`
/// (the real bar button, not just the SF Symbol glyph) and reports its frame in
/// window coordinates — which line up with a full-screen, safe-area-ignoring
/// SwiftUI coach overlay.
struct ToolbarButtonFrameReporter: UIViewRepresentable {
    var onChange: (CGRect) -> Void

    func makeUIView(context: Context) -> ReporterView { ReporterView(onChange: onChange) }
    func updateUIView(_ view: ReporterView, context: Context) {
        view.onChange = onChange
        view.report()
    }

    final class ReporterView: UIView {
        var onChange: (CGRect) -> Void
        private var last: CGRect = .zero

        init(onChange: @escaping (CGRect) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() { super.didMoveToWindow(); report() }
        override func layoutSubviews() { super.layoutSubviews(); report() }

        func report() {
            guard let window else { return }
            // Prefer the nearest UIControl (the tappable 44pt button); fall back to
            // the immediate host if none is found.
            var candidate: UIView? = self
            var control: UIView?
            while let view = candidate {
                if view is UIControl { control = view; break }
                candidate = view.superview
            }
            let target = control ?? superview ?? self
            let rect = target.convert(target.bounds, to: window)
            guard rect.width > 1, rect.height > 1 else { return }
            if abs(rect.minX - last.minX) > 0.5 || abs(rect.minY - last.minY) > 0.5
                || abs(rect.width - last.width) > 0.5 || abs(rect.height - last.height) > 0.5 {
                last = rect
                // Defer out of the current layout pass to avoid mutating SwiftUI
                // state during a view update.
                DispatchQueue.main.async { [onChange] in onChange(rect) }
            }
        }
    }
}

// MARK: - List "open a story" spotlight

/// A one-step spotlight over the first article row, nudging the user to open a
/// story (which then starts the reader coach marks). Uses the row's measured
/// frame when available, else a sensible top-of-list region.
struct ListTapHint: View {
    /// The first row's global frame, if measured; nil falls back to a region.
    var rowFrame: CGRect?
    var onDismiss: () -> Void

    var body: some View {
        GeometryReader { geo in
            let fallback = CGRect(x: 12, y: geo.size.height * 0.14, width: geo.size.width - 24, height: 96)
            // The overlay ignores safe area, so its local space == global space;
            // the measured global row frame can be used directly (inset a touch).
            let rect = (rowFrame ?? fallback).insetBy(dx: -6, dy: -4)
            ZStack {
                CoachScrim(spotlight: rect, cornerRadius: 16)
                CoachCallout(
                    systemImage: "hand.tap.fill",
                    title: "Open a story",
                    message: "Tap any story to open it in the clean, native reader.",
                    primaryTitle: "Got it",
                    onPrimary: onDismiss
                )
                // Place the card below the spotlighted row (or centered if unknown).
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 90)
            }
        }
        .ignoresSafeArea()
    }
}

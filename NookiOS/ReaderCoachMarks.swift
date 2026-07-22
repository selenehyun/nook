import SwiftUI

// MARK: - Spotlight scrim

extension View {
    /// Punches the mask shape OUT of this view (the shape's area becomes
    /// transparent) — used to cut a spotlight hole in a dimming scrim.
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay { mask().blendMode(.destinationOut) }
        }
    }
}

/// A dimming scrim with a rounded-rectangle spotlight cut out over a target
/// region, plus a caller-supplied callout card. The dim and the highlight ring
/// never take touches, so the real control inside the spotlight stays usable and
/// the taught gesture can be performed live; only the card's buttons are
/// interactive.
struct CoachScrim<Card: View>: View {
    var spotlight: CGRect?
    var cornerRadius: CGFloat = 20
    @ViewBuilder var card: Card

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
                .allowsHitTesting(false)

            if let spotlight {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.85), lineWidth: 2)
                    .frame(width: spotlight.width, height: spotlight.height)
                    .position(x: spotlight.midX, y: spotlight.midY)
                    .allowsHitTesting(false)
            }

            card
        }
    }
}

/// The callout card shown by the coach marks: an icon, a title, a short message,
/// and the advance / skip controls.
struct CoachCallout: View {
    var systemImage: String
    var title: LocalizedStringKey
    var message: LocalizedStringKey
    var primaryTitle: LocalizedStringKey
    var onPrimary: () -> Void
    var onSkip: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.accentColor)
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

// MARK: - Reader coach marks

/// The ordered steps of the first-open reader walkthrough.
enum ReaderCoachStep: Int, CaseIterable, Hashable {
    case star, pullNext, original, back

    var next: ReaderCoachStep? { ReaderCoachStep(rawValue: rawValue + 1) }
}

/// The interactive reader coach marks: a dimmed spotlight over the real reader
/// that walks through the four reading gestures. Each step advances when the user
/// performs the real action (the parent wires those observers) or taps "Next";
/// "Skip" ends it. The reader itself is never blocked — the gesture can be tried
/// live under the scrim.
struct ReaderCoachMarks: View {
    @Binding var step: ReaderCoachStep?
    /// "Next" tapped on the given step — the parent advances (the same path the
    /// live action takes), so all advancement flows through one place.
    var onNext: (ReaderCoachStep) -> Void
    var onSkip: () -> Void

    var body: some View {
        GeometryReader { geo in
            if let step {
                let w = geo.size.width
                let h = geo.size.height
                CoachScrim(spotlight: spot(step, w: w, h: h), cornerRadius: step == .back ? 24 : 20) {
                    callout(step)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: cardAlignment(step))
                        .padding(.top, cardAlignment(step) == .top ? 100 : 0)
                        .padding(.bottom, cardAlignment(step) == .bottom ? 112 : 0)
                }
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.28), value: step)
    }

    /// Keep the card clear of the spotlight: below it when the highlight is high,
    /// above it otherwise.
    private func cardAlignment(_ step: ReaderCoachStep) -> Alignment {
        step == .star ? .bottom : .top
    }

    /// The highlighted region for each step, in full-screen coordinates.
    private func spot(_ step: ReaderCoachStep, w: CGFloat, h: CGFloat) -> CGRect {
        switch step {
        case .star:
            let width = w - 48
            let height = h * 0.30
            return CGRect(x: (w - width) / 2, y: h * 0.26, width: width, height: height)
        case .pullNext:
            let width = w - 40
            let height: CGFloat = 130
            return CGRect(x: (w - width) / 2, y: h - height - 96, width: width, height: height)
        case .original:
            // The document button sits at the trailing end of the bottom bar.
            let size = CGSize(width: 66, height: 52)
            return CGRect(x: w - size.width - 12, y: h - size.height - 24, width: size.width, height: size.height)
        case .back:
            let width: CGFloat = 46
            let height = h * 0.46
            return CGRect(x: 12, y: (h - height) / 2, width: width, height: height)
        }
    }

    @ViewBuilder
    private func callout(_ step: ReaderCoachStep) -> some View {
        switch step {
        case .star:
            CoachCallout(
                systemImage: "star.fill",
                title: "Star what you love",
                message: "Double-tap anywhere on the article to star it — try it now, or tap Next.",
                primaryTitle: "Next",
                onPrimary: { onNext(.star) },
                onSkip: onSkip
            )
        case .pullNext:
            CoachCallout(
                systemImage: "chevron.up",
                title: "On to the next",
                message: "At the end of a story, keep pulling up past the bottom to jump to the next one.",
                primaryTitle: "Next",
                onPrimary: { onNext(.pullNext) },
                onSkip: onSkip
            )
        case .original:
            CoachCallout(
                systemImage: "doc.plaintext",
                title: "Read the original",
                message: "Tap the document button to open the full web page — with a reader view and translation.",
                primaryTitle: "Next",
                onPrimary: { onNext(.original) },
                onSkip: onSkip
            )
        case .back:
            CoachCallout(
                systemImage: "chevron.left",
                title: "Back to your list",
                message: "Swipe in from the left edge to return to the article list. That's everything — enjoy Nook!",
                primaryTitle: "Done",
                onPrimary: { onNext(.back) }
            )
        }
    }
}

// MARK: - List "open a story" hint

/// A one-step spotlight over the top of the article list, shown once after the
/// first feed is added, nudging the user to open a story (which then starts the
/// reader coach marks). Dismisses via its button, or when a story opens.
struct ListTapHint: View {
    var onDismiss: () -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let rect = CGRect(x: 12, y: h * 0.16, width: w - 24, height: 150)
            CoachScrim(spotlight: rect) {
                CoachCallout(
                    systemImage: "hand.tap.fill",
                    title: "Open a story",
                    message: "Tap any story to open it in the clean, native reader.",
                    primaryTitle: "Got it",
                    onPrimary: onDismiss
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 80)
            }
        }
        .ignoresSafeArea()
    }
}

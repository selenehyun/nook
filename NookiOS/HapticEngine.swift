import CoreHaptics
import UIKit

/// Plays the reader's gesture haptics. Core Haptics drives the long-press
/// build-up — quickening tiny taps over a soft rumble, ending in one deep,
/// slightly stronger pulse at the moment the web view opens. A simple feedback
/// generator handles the double-tap star. No-ops on devices without haptics
/// (e.g. the simulator).
@MainActor
final class ReaderHaptics {
    private var engine: CHHapticEngine?
    private var player: CHHapticPatternPlayer?
    private let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    /// The build-up length. The long-press gesture waits a short delay and then
    /// this duration, so the final pulse lands exactly as the press completes.
    static let buildupDuration: Double = 0.42

    init() {
        guard supportsHaptics else { return }
        engine = try? CHHapticEngine()
        engine?.isAutoShutdownEnabled = true
        engine?.resetHandler = { [weak self] in try? self?.engine?.start() }
        try? engine?.start()
    }

    /// A strong pulse for toggling the star (firmer when starring).
    func star(on: Bool) {
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.prepare()
        generator.impactOccurred(intensity: on ? 1.0 : 0.85)
    }

    /// Starts the long-press build-up pattern.
    func startLongPressBuildup() {
        guard supportsHaptics, let engine else { return }
        try? engine.start()

        var events: [CHHapticEvent] = []

        // A continuous rumble swelling underneath the taps.
        events.append(CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.55),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3),
            ],
            relativeTime: 0,
            duration: Self.buildupDuration - 0.05
        ))

        // Taps, sparse at first then quickening and intensifying (ease-in).
        let taps = 7
        for i in 0..<taps {
            let progress = Double(i) / Double(taps)
            let time = pow(progress, 1.6) * (Self.buildupDuration - 0.05)
            let intensity = Float(0.5 + 0.5 * progress)
            events.append(CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6),
                ],
                relativeTime: time
            ))
        }

        // The final deep, strong pulse (low sharpness reads as a heavy "thud"
        // rather than a click).
        events.append(CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.45),
            ],
            relativeTime: Self.buildupDuration - 0.02
        ))

        guard let pattern = try? CHHapticPattern(events: events, parameters: []) else { return }
        player = try? engine.makePlayer(with: pattern)
        try? player?.start(atTime: CHHapticTimeImmediate)
    }

    /// Stops the build-up early (finger lifted before it completed).
    func cancelLongPressBuildup() {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
    }
}

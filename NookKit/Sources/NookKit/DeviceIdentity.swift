import Foundation

/// The stable per-install identity that names this device's sync shard and
/// tie-breaks its HLCs. Persisted in `UserDefaults` and generated once on first
/// use.
///
/// A fresh random `UUID` is deliberate: `identifierForVendor` changes on
/// reinstall and is shared across a vendor's apps, which would either resurrect
/// a stale shard or collide two installs onto one shard. A per-install UUID
/// gives each app instance exactly one shard for its lifetime.
public enum DeviceIdentity {
    public static let defaultsKey = "nookDeviceID"

    /// Returns this install's device id, creating and persisting one on first
    /// access. Reads/writes go through the given defaults (injectable for tests).
    public static func current(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: defaultsKey)
        return generated
    }
}

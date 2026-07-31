import Foundation

/// Remembers when the Guardián was last actually listening (attention socket
/// connected). It is the only input that distinguishes a short socket
/// reconnection from a real absence worth a spoken catch-up.
///
/// Deliberately not the Keychain: this is a non-secret, disposable timestamp,
/// and losing it only costs one skipped catch-up.
public protocol PulseGuardianPresenceStore: Sendable {
    func lastListeningAt() -> Date?
    func recordListening(at date: Date)
}

public final class UserDefaultsPulseGuardianPresenceStore: PulseGuardianPresenceStore, @unchecked Sendable {
    private let key = "pulse.guardian.last-listening-at.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func lastListeningAt() -> Date? {
        let seconds = defaults.double(forKey: key)
        // A missing key reads as 0: that is the first launch, never "1970".
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    public func recordListening(at date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: key)
    }
}

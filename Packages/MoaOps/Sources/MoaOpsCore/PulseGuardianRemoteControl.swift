import Foundation

/// Bridges lock-screen / Dynamic Island buttons to the running app model.
///
/// A `LiveActivityIntent` runs in the app's process (relaunching it in the
/// background if needed) without opening the app or unlocking the phone. The
/// intent can't reach the `@StateObject` model directly, so the model registers
/// its actions here and the intent invokes them through this shared singleton.
@MainActor
public final class PulseGuardianRemoteControl {
    public static let shared = PulseGuardianRemoteControl()
    private init() {}

    /// Toggles microphone capture. Muting is only a capture gate: it never
    /// changes how the Guardián otherwise behaves.
    public var onToggleMic: (() -> Void)?
    /// Starts the Guardián if stopped, stops it if running.
    public var onToggleGuardian: (() async -> Void)?

    public func toggleMic() { onToggleMic?() }
    public func toggleGuardian() async { await onToggleGuardian?() }
}

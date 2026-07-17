#if os(iOS) && canImport(AppIntents)
import AppIntents

/// Lock-screen / Dynamic Island buttons for the Guardián Live Activity.
///
/// `LiveActivityIntent` runs in the app's process (relaunching it in the
/// background if needed) without opening the app or unlocking the phone, so a
/// tap on the lock screen reaches the running Guardián through
/// `PulseGuardianRemoteControl`.
@available(iOS 17.0, *)
public struct PulseToggleMicIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Silenciar o reanudar el micrófono"
    public static var description = IntentDescription("Silencia o reanuda el micrófono del Guardián.")
    public static var isDiscoverable = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        PulseGuardianRemoteControl.shared.toggleMic()
        return .result()
    }
}

/// Single start/stop toggle: starts the Guardián when stopped, stops it when
/// running — mirroring the one in-app button.
@available(iOS 17.0, *)
public struct PulseToggleGuardianIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Activar o detener el Guardián"
    public static var description = IntentDescription("Activa el Guardián si está detenido, o lo detiene si está activo.")
    public static var isDiscoverable = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        await PulseGuardianRemoteControl.shared.toggleGuardian()
        return .result()
    }
}
#endif

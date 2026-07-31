import Foundation
#if os(iOS) && canImport(AudioToolbox)
import AudioToolbox
#endif

/// The two audible transitions of the Guardián. With headphones on and the
/// phone in a pocket, the state of the orb is invisible: without these cues the
/// owner says "Pulse" and starts talking into the void, and never learns when
/// Pulse stopped listening.
///
/// A protocol so the coordinator stays testable: it decides *when* a transition
/// happens, never *how* it sounds.
@MainActor
public protocol PulseEarcons: AnyObject {
    /// "I heard you, I'm opening." Played the instant the wake word fires,
    /// ~1-2s before the Realtime socket is actually ready.
    func wake()
    /// "I stopped listening." Played when the conversation closes for good and
    /// the Guardián goes back to standby.
    func sleep()
}

/// System sounds instead of synthesized PCM: they are served by the system
/// sound server, so they cost no assets, no latency and — crucially — they do
/// not touch the AVAudioEngine that `NativePulseVoiceController` owns. Routing
/// a beep through that engine's player node would interleave it with the
/// Realtime voice buffers and its completion would be counted as a playback
/// drain, which is exactly the signal the coordinator uses to decide that an
/// announcement finished sounding. The capture session (`.playAndRecord`,
/// `.voiceChat`, `.mixWithOthers`) stays active and keeps recording throughout;
/// the cue simply mixes into the current output route, headphones included.
@MainActor
public final class SystemSoundPulseEarcons: PulseEarcons {
    private let wakeSound: UInt32
    private let sleepSound: UInt32

    /// 1113 `begin_record.caf` / 1114 `end_record.caf`: two short, discreet and
    /// clearly distinct tones that already mean "I started/stopped capturing"
    /// on iOS.
    ///
    /// nonisolated: it only stores two constants, and it must be callable from
    /// the coordinator's default argument list, which is evaluated outside the
    /// main actor.
    public nonisolated init(wakeSound: UInt32 = 1113, sleepSound: UInt32 = 1114) {
        self.wakeSound = wakeSound
        self.sleepSound = sleepSound
    }

    public func wake() { play(wakeSound) }
    public func sleep() { play(sleepSound) }

    private func play(_ sound: UInt32) {
        #if os(iOS) && canImport(AudioToolbox)
        AudioServicesPlaySystemSound(SystemSoundID(sound))
        #endif
    }
}

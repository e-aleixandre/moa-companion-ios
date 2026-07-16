import Foundation
import XCTest
@testable import MoaOpsCore

@MainActor
final class PulseGuardianCoordinatorTests: XCTestCase {
    // BUG 1: after the Realtime socket closes and the coordinator returns to
    // standby, on-device wake detection must be re-armed, or "Pulse" only ever
    // wakes the assistant once.
    func testWakeWordIsRearmedAfterHotWindowCloses() async throws {
        let wake = MockWakeWord()
        let realtime = MockRealtime()
        let attention = MockAttentionChannel()
        let coordinator = PulseGuardianCoordinator(service: MockGuardianService(), realtime: realtime, attention: attention, voice: MockVoice(), wakeWord: wake, hotWindow: 0.05)
        await coordinator.start()
        await settle()
        XCTAssertEqual(wake.startCount, 1)

        wake.fire()
        try await waitFor { await realtime.begins() == 1 }
        await settle()
        XCTAssertGreaterThanOrEqual(wake.stopCount, 1)

        await realtime.emit(.listening)
        try await waitFor { wake.startCount >= 2 }
        XCTAssertGreaterThanOrEqual(wake.startCount, 2)
        XCTAssertEqual(coordinator.state, .guardianStandby)
    }

    // A realtime failure must also return to a rearmed standby, not leave the
    // detector permanently silent.
    func testWakeWordIsRearmedAfterRealtimeFailure() async throws {
        let wake = MockWakeWord()
        let realtime = MockRealtime()
        let coordinator = PulseGuardianCoordinator(service: MockGuardianService(), realtime: realtime, attention: MockAttentionChannel(), voice: MockVoice(), wakeWord: wake, hotWindow: 5)
        await coordinator.start()
        await settle()
        wake.fire()
        try await waitFor { await realtime.begins() == 1 }

        await realtime.emit(.failed)
        try await waitFor { wake.startCount >= 2 }
        XCTAssertEqual(coordinator.state, .guardianStandby)
    }

    // BUG 3: raw microphone PCM (continuous capture) must never extend the hot
    // window; only real server-VAD speech does. Otherwise the expensive socket
    // never closes.
    func testRawPCMDoesNotExtendHotWindowButSpeechDoes() async throws {
        let wake = MockWakeWord()
        let realtime = MockRealtime()
        let voice = MockVoice()
        let coordinator = PulseGuardianCoordinator(service: MockGuardianService(), realtime: realtime, attention: MockAttentionChannel(), voice: voice, wakeWord: wake, hotWindow: 0.2)
        await coordinator.start()
        await settle()
        wake.fire()
        try await waitFor { await realtime.begins() == 1 }
        await settle()
        await realtime.emit(.listening)
        await settle()

        // Ongoing raw PCM (no speech) must not stop the socket from closing.
        for _ in 0..<10 { voice.emitPCM(Data([0, 0])); await settle() }
        try await waitFor { coordinator.state == .guardianStandby }
        XCTAssertEqual(coordinator.state, .guardianStandby)
    }

    func testSpeechKeepsCallOpenUntilSilence() async throws {
        let wake = MockWakeWord()
        let realtime = MockRealtime()
        let coordinator = PulseGuardianCoordinator(service: MockGuardianService(), realtime: realtime, attention: MockAttentionChannel(), voice: MockVoice(), wakeWord: wake, hotWindow: 0.2)
        await coordinator.start()
        await settle()
        wake.fire()
        try await waitFor { await realtime.begins() == 1 }
        await settle()
        await realtime.emit(.listening)
        await realtime.emit(.speechStarted)
        await settle()

        // While the owner is speaking, the window timer must not fire.
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNotEqual(coordinator.state, .guardianStandby)
        let ended = await realtime.currentCall()?.wasEnded()
        XCTAssertEqual(ended, false)

        await realtime.emit(.speechStopped)
        try await waitFor { coordinator.state == .guardianStandby }
        XCTAssertEqual(coordinator.state, .guardianStandby)
    }

    private func settle() async { for _ in 0..<40 { await Task.yield() } }
    private func waitFor(_ condition: @escaping () async -> Bool, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition not met before timeout")
    }
}

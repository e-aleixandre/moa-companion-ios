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

    // BUG 2: PCM captured between activation and socket-ready must be buffered
    // and then flushed, in order, once the session is ready — never discarded.
    func testOwnerSpeechDuringWarmupIsBufferedAndFlushedInOrder() async throws {
        let wake = MockWakeWord()
        let realtime = MockRealtime(startsReady: false)
        let voice = MockVoice()
        let coordinator = PulseGuardianCoordinator(service: MockGuardianService(), realtime: realtime, attention: MockAttentionChannel(), voice: voice, wakeWord: wake, hotWindow: 5)
        await coordinator.start()
        await settle()

        wake.fire()
        try await waitFor { await realtime.begins() == 1 }
        await settle()

        // Owner starts talking while the socket is still warming up.
        let frames = [Data([1, 1]), Data([2, 2]), Data([3, 3])]
        for frame in frames { voice.emitPCM(frame) }
        await settle()
        // Nothing forwarded yet: the call is not ready.
        let beforeReady = await realtime.currentCall()?.appendedCount()
        XCTAssertEqual(beforeReady, 0)

        // Session becomes ready -> buffered frames flush in order.
        await realtime.currentCall()?.markReady()
        try await waitFor { (await realtime.currentCall()?.appendedCount() ?? 0) >= frames.count }
        let appended = await realtime.currentCall()?.allAppended()
        XCTAssertEqual(appended, frames)
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

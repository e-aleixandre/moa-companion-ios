import Foundation
import MoaOpsCore

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
import os

@MainActor
public final class PulseGuardianLiveActivityController {
    private let log = Logger(subsystem: "com.moa.pulse", category: "live-activity")
    private var activity: Activity<PulseGuardianActivityAttributes>?

    public init() {}

    public func start(attributes: PulseGuardianActivityAttributes, contentState: PulseGuardianActivityAttributes.ContentState) {
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: contentState, staleDate: nil),
                pushType: nil
            )
        } catch {
            log.error("No se pudo iniciar la Live Activity del Guardián: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func update(_ contentState: PulseGuardianActivityAttributes.ContentState) {
        let activity = activity
        Task { [activity] in
            await activity?.update(.init(state: contentState, staleDate: nil))
        }
    }

    public func end() {
        let activity = activity
        self.activity = nil
        Task { [activity] in
            await activity?.end(nil, dismissalPolicy: .immediate)
        }
    }
}
#else
/// A no-op on platforms where Live Activities are unavailable.
@MainActor
public final class PulseGuardianLiveActivityController {
    public init() {}
    public func start(attributes _: PulseGuardianActivityAttributes, contentState _: PulseGuardianActivityAttributes.ContentState) {}
    public func update(_: PulseGuardianActivityAttributes.ContentState) {}
    public func end() {}
}
#endif

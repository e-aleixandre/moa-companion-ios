@preconcurrency import Foundation

/// A complete snapshot sent by the legacy Pulse Call update stream.
///
/// The stream itself remains in `PulseCallService` until the next migration
/// moves Call Pulse to the generic Serve session API.
public struct OpsSnapshotUpdate: Equatable, Sendable {
    public let version: UInt64
    public let snapshot: OpsSnapshot
    public let isInitial: Bool
}

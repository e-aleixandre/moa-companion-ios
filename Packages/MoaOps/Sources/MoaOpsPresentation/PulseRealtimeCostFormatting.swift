import Foundation
import MoaOpsCore

/// How the cost ledger is read out loud in the UI. Presentation, not truth: the
/// amounts stay USD doubles in Core and only become strings here.
public enum PulseRealtimeCostFormatting {
    /// Placeholder for a bucket with nothing in it. The section is always
    /// present, so an empty ledger has to look empty rather than free.
    public static let empty = "—"

    /// Deliberately not a locale currency formatter: these are OpenAI's USD
    /// prices, and showing them with the phone's currency symbol would claim a
    /// conversion nobody did.
    public static func amount(_ usd: Double) -> String {
        guard usd > 0 else { return "$0,00" }
        // Anything under a cent rounds to "$0,00", which reads as free. Say what
        // it actually is instead.
        if usd < 0.005 { return "<$0,01" }
        return "$" + String(format: "%.2f", usd).replacingOccurrences(of: ".", with: ",")
    }

    public static func sessions(_ count: Int) -> String {
        count == 1 ? "1 sesión" : "\(count) sesiones"
    }

    public static func bucket(_ bucket: PulseRealtimeCostSnapshot.Bucket) -> String {
        bucket.isEmpty ? empty : "\(amount(bucket.costUSD)) · \(sessions(bucket.sessions))"
    }

    public static func lastSession(_ snapshot: PulseRealtimeCostSnapshot) -> String {
        guard let cost = snapshot.lastSessionUSD else { return empty }
        return amount(cost)
    }
}

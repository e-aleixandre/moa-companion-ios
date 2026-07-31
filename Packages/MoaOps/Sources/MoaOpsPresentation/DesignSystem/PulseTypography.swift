import SwiftUI

/// Pulse typographic scale.
///
/// SF Pro for the interface voice; SF Mono for the "technical" bits (session
/// names, servers, commands). No custom fonts: system only.
public enum PulseFont {
    // MARK: SF Pro

    /// Screen title (hero).
    public static let display = Font.system(size: 30, weight: .bold)
    /// Section or secondary-screen title.
    public static let title = Font.system(size: 22, weight: .semibold)
    /// Large state label, buttons.
    public static let headline = Font.system(size: 17, weight: .semibold)
    public static let body = Font.system(size: 16, weight: .regular)
    public static let callout = Font.system(size: 15, weight: .regular)
    public static let footnote = Font.system(size: 13, weight: .regular)
    /// Uppercase micro-labels (section headers, badges).
    public static let micro = Font.system(size: 11, weight: .semibold)

    // MARK: SF Mono — the technical bits

    public static let monoLarge = Font.system(size: 15, weight: .medium, design: .monospaced)
    public static let mono = Font.system(size: 13, weight: .medium, design: .monospaced)
    public static let monoSmall = Font.system(size: 11, weight: .medium, design: .monospaced)
}

extension View {
    /// Uppercase micro-label with wide tracking ("SERVIDOR", "AVISO").
    public func pulseMicroCaps() -> some View {
        font(PulseFont.micro)
            .textCase(.uppercase)
            .tracking(1.4)
    }
}

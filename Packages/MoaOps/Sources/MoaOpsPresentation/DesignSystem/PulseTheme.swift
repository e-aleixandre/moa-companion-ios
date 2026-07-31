import SwiftUI

/// Color tokens of the Pulse design system.
///
/// Dark by default: Pulse is a technical tool used with headphones, often on
/// the move or in low light. The tokens are semantic (surface, text, state
/// tone); views should not use loose colors.
public enum PulseColor {
    // MARK: Backgrounds and surfaces

    /// Base background of every screen. Near-black with a blue-charcoal hint.
    public static let backgroundBase = Color(hex: 0x0B0D10)
    /// Raised surface: cards, rows, containers.
    public static let backgroundRaised = Color(hex: 0x14171C)
    /// Surface on surface: text fields, chips inside cards.
    public static let backgroundOverlay = Color(hex: 0x1C2128)
    /// Hairline stroke for card and control borders.
    public static let hairline = Color.white.opacity(0.08)

    // MARK: Text

    public static let textPrimary = Color(hex: 0xF2F4F7)
    public static let textSecondary = Color(hex: 0x9AA3AF)
    public static let textTertiary = Color(hex: 0x5C6570)
    /// Text over accent fills (primary button).
    public static let textInverse = Color(hex: 0x0B0D10)

    // MARK: Accent and semantics

    /// "Ember": the Pulse accent. Warm, with character, far from system blue.
    public static let ember = Color(hex: 0xFF6D3F)
    /// Cold cyan for "listening" (voice input).
    public static let listening = Color(hex: 0x4FD8EB)
    public static let success = Color(hex: 0x54D273)
    public static let warning = Color(hex: 0xFFC24B)
    public static let danger = Color(hex: 0xFF5D5D)
}

/// Semantic tone reusable by pills, buttons, orb and cards.
public enum PulseTone: Equatable, Sendable {
    case accent
    case listening
    case success
    case warning
    case danger
    case neutral

    public var color: Color {
        switch self {
        case .accent: PulseColor.ember
        case .listening: PulseColor.listening
        case .success: PulseColor.success
        case .warning: PulseColor.warning
        case .danger: PulseColor.danger
        case .neutral: PulseColor.textSecondary
        }
    }
}

extension Color {
    /// Builds an opaque sRGB color from `0xRRGGBB`.
    fileprivate init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}

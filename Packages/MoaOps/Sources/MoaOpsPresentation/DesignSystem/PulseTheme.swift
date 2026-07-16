import SwiftUI

/// Tokens de color del design system de Pulse.
///
/// Oscuro por defecto: Pulse es una herramienta técnica que se usa con cascos,
/// muchas veces en movimiento o con poca luz. Los tokens son semánticos
/// (superficie, texto, tono de estado); las vistas no deben usar colores sueltos.
public enum PulseColor {
    // MARK: Fondos y superficies

    /// Fondo base de toda pantalla. Casi negro con un matiz azul-carbón.
    public static let backgroundBase = Color(hex: 0x0B0D10)
    /// Superficie elevada: tarjetas, filas, contenedores.
    public static let backgroundRaised = Color(hex: 0x14171C)
    /// Superficie sobre superficie: campos de texto, chips dentro de tarjetas.
    public static let backgroundOverlay = Color(hex: 0x1C2128)
    /// Trazo hairline para bordes de tarjetas y controles.
    public static let hairline = Color.white.opacity(0.08)

    // MARK: Texto

    public static let textPrimary = Color(hex: 0xF2F4F7)
    public static let textSecondary = Color(hex: 0x9AA3AF)
    public static let textTertiary = Color(hex: 0x5C6570)
    /// Texto sobre rellenos de acento (botón primario).
    public static let textInverse = Color(hex: 0x0B0D10)

    // MARK: Acento y semánticos

    /// "Ember": el acento de Pulse. Cálido, con carácter, lejos del azul de sistema.
    public static let ember = Color(hex: 0xFF6D3F)
    /// Cian frío para "escuchando" (entrada de voz).
    public static let listening = Color(hex: 0x4FD8EB)
    public static let success = Color(hex: 0x54D273)
    public static let warning = Color(hex: 0xFFC24B)
    public static let danger = Color(hex: 0xFF5D5D)
}

/// Tono semántico reutilizable por pills, botones, orbe y tarjetas.
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
    /// Construye un color sRGB opaco a partir de `0xRRGGBB`.
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

import SwiftUI

/// Escala tipográfica de Pulse.
///
/// SF Pro para la voz de la interfaz; SF Mono para lo "técnico" (nombres de
/// sesión, servidores, comandos). Nada de fuentes custom: solo sistema.
public enum PulseFont {
    // MARK: SF Pro

    /// Título de pantalla (héroe).
    public static let display = Font.system(size: 30, weight: .bold)
    /// Título de sección o de pantalla secundaria.
    public static let title = Font.system(size: 22, weight: .semibold)
    /// Etiqueta de estado grande, botones.
    public static let headline = Font.system(size: 17, weight: .semibold)
    public static let body = Font.system(size: 16, weight: .regular)
    public static let callout = Font.system(size: 15, weight: .regular)
    public static let footnote = Font.system(size: 13, weight: .regular)
    /// Micro-etiquetas en mayúsculas (cabeceras de sección, badges).
    public static let micro = Font.system(size: 11, weight: .semibold)

    // MARK: SF Mono — lo técnico

    public static let monoLarge = Font.system(size: 15, weight: .medium, design: .monospaced)
    public static let mono = Font.system(size: 13, weight: .medium, design: .monospaced)
    public static let monoSmall = Font.system(size: 11, weight: .medium, design: .monospaced)
}

extension View {
    /// Micro-etiqueta en mayúsculas con tracking amplio ("SERVIDOR", "AVISO").
    public func pulseMicroCaps() -> some View {
        font(PulseFont.micro)
            .textCase(.uppercase)
            .tracking(1.4)
    }
}

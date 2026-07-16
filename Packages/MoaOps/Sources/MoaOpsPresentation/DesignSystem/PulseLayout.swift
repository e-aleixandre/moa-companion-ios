import SwiftUI

/// Tokens de espaciado. Escala de 4 pt.
public enum PulseSpacing {
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let sm: CGFloat = 12
    public static let md: CGFloat = 16
    public static let lg: CGFloat = 20
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
}

/// Tokens de radio de esquina.
public enum PulseRadius {
    /// Controles pequeños: campos, chips.
    public static let control: CGFloat = 12
    /// Tarjetas y superficies.
    public static let card: CGFloat = 16
    /// Contenedores grandes (transcript, hojas).
    public static let sheet: CGFloat = 22
}

extension View {
    /// Superficie elevada estándar: relleno raised + hairline + radio de tarjeta.
    public func pulseCard(padding: CGFloat = PulseSpacing.md) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous)
                    .fill(PulseColor.backgroundRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous)
                    .strokeBorder(PulseColor.hairline, lineWidth: 1)
            )
    }

    /// Glow sutil del color dado; la firma lumínica de Pulse.
    public func pulseGlow(_ color: Color, radius: CGFloat = 18, opacity: Double = 0.35) -> some View {
        shadow(color: color.opacity(opacity), radius: radius)
    }

    /// Fondo de pantalla completo: base casi negra con un halo cálido muy tenue
    /// en la parte superior. Fija el esquema oscuro.
    public func pulseScreenBackground() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                ZStack {
                    PulseColor.backgroundBase
                    RadialGradient(
                        colors: [PulseColor.ember.opacity(0.07), .clear],
                        center: UnitPoint(x: 0.5, y: -0.1),
                        startRadius: 0,
                        endRadius: 480
                    )
                }
                .ignoresSafeArea()
            )
            .preferredColorScheme(.dark)
    }
}

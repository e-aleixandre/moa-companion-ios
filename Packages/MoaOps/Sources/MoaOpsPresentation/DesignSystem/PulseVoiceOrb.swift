import SwiftUI

/// Estado visual del orbe de voz.
public enum PulseOrbMode: Equatable, Sendable {
    /// En reposo: respiración lenta.
    case idle
    /// Conectando o reconectando: rotación tenue, expectante.
    case connecting
    /// Escuchando al dueño: anillos cian que se expanden.
    case listening
    /// Pulse habla: latido cálido de acento.
    case speaking

    var tone: PulseTone {
        switch self {
        case .idle, .connecting: .neutral
        case .listening: .listening
        case .speaking: .accent
        }
    }
}

/// El orbe de voz de Pulse: el foco emocional de la pantalla de llamada.
///
/// Dibujado con círculos y gradientes sobre `TimelineView(.animation)`,
/// sin symbol effects (iOS 17-safe). Ligero: 3 capas y un anillo.
public struct PulseVoiceOrb: View {
    public var mode: PulseOrbMode
    public var diameter: CGFloat

    public init(mode: PulseOrbMode, diameter: CGFloat = 148) {
        self.mode = mode
        self.diameter = diameter
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            orb(time: t)
        }
        .frame(width: diameter * 1.5, height: diameter * 1.5)
        .animation(.easeInOut(duration: 0.45), value: mode)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func orb(time t: TimeInterval) -> some View {
        let color = mode.tone == .neutral ? PulseColor.textSecondary : mode.tone.color
        let breath = breathScale(time: t)

        ZStack {
            // Halo exterior difuso.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [color.opacity(haloOpacity), .clear],
                        center: .center,
                        startRadius: diameter * 0.18,
                        endRadius: diameter * 0.75
                    )
                )
                .frame(width: diameter * 1.5, height: diameter * 1.5)
                .scaleEffect(breath)

            // Anillos que se expanden al escuchar.
            if mode == .listening {
                ForEach(0..<2, id: \.self) { index in
                    let progress = ripple(time: t, offset: Double(index) * 0.5)
                    Circle()
                        .strokeBorder(color.opacity(0.55 * (1 - progress)), lineWidth: 1.5)
                        .frame(width: diameter, height: diameter)
                        .scaleEffect(1 + progress * 0.42)
                }
            }

            // Anillo de rotación al conectar.
            if mode == .connecting {
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(color.opacity(0.5), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: diameter * 1.12, height: diameter * 1.12)
                    .rotationEffect(.radians(t.truncatingRemainder(dividingBy: 2) * .pi))
            }

            // Núcleo.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            color.opacity(mode == .idle ? 0.32 : 0.75),
                            color.opacity(mode == .idle ? 0.10 : 0.22),
                            PulseColor.backgroundRaised,
                        ],
                        center: UnitPoint(x: 0.42, y: 0.36),
                        startRadius: 0,
                        endRadius: diameter * 0.62
                    )
                )
                .frame(width: diameter, height: diameter)
                .overlay(Circle().strokeBorder(color.opacity(0.5), lineWidth: 1))
                .scaleEffect(coreScale(time: t, base: breath))
                .pulseGlow(color, radius: 24, opacity: mode == .idle ? 0.12 : 0.4)

            // Brillo especular, arriba a la izquierda.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.22), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: diameter * 0.28
                    )
                )
                .frame(width: diameter * 0.55, height: diameter * 0.55)
                .offset(x: -diameter * 0.16, y: -diameter * 0.18)
                .scaleEffect(breath)
        }
    }

    private var haloOpacity: Double {
        switch mode {
        case .idle: 0.10
        case .connecting: 0.16
        case .listening: 0.26
        case .speaking: 0.34
        }
    }

    /// Respiración senoidal lenta; más viva al hablar.
    private func breathScale(time t: TimeInterval) -> CGFloat {
        let period: Double = mode == .speaking ? 1.1 : 3.6
        let amplitude: Double = mode == .speaking ? 0.045 : 0.02
        return CGFloat(1 + amplitude * sin(t * 2 * .pi / period))
    }

    /// Al hablar, superpone un latido rápido de "amplitud de voz" simulada.
    /// // TODO: cuando el motor exponga niveles de audio reales (RMS del PCM),
    /// // sustituir esta senoide por la amplitud medida.
    private func coreScale(time t: TimeInterval, base: CGFloat) -> CGFloat {
        guard mode == .speaking else { return base }
        let flutter = 0.03 * sin(t * 2 * .pi / 0.27) * sin(t * 2 * .pi / 0.83)
        return base + CGFloat(flutter)
    }

    /// Progreso 0→1 cíclico para los anillos de escucha.
    private func ripple(time t: TimeInterval, offset: Double) -> Double {
        let period = 1.9
        return ((t / period) + offset).truncatingRemainder(dividingBy: 1)
    }
}

#if os(iOS)
#Preview("Orbe · estados") {
    VStack(spacing: PulseSpacing.xl) {
        HStack(spacing: 0) {
            PulseVoiceOrb(mode: .idle, diameter: 90)
            PulseVoiceOrb(mode: .connecting, diameter: 90)
        }
        HStack(spacing: 0) {
            PulseVoiceOrb(mode: .listening, diameter: 90)
            PulseVoiceOrb(mode: .speaking, diameter: 90)
        }
    }
    .pulseScreenBackground()
}
#endif

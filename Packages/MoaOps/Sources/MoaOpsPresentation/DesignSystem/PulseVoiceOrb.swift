import SwiftUI

/// Estado visual del orbe de voz.
public enum PulseOrbMode: Equatable, Sendable {
    /// En reposo: respiración lenta, superficie casi quieta.
    case idle
    /// Conectando o reconectando: cometa orbitando, expectante.
    case connecting
    /// Escuchando al dueño: ondas frías que se expanden.
    case listening
    /// Pulse habla: turbulencia cálida, más energía.
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
/// Ya no es un círculo con gradiente: es un blob orgánico cuyo contorno
/// ondula con senoides desfasadas por ángulo, con una nebulosa interior de
/// "wisps" que orbitan a distintas velocidades (parallax) y una iridiscencia
/// angular que gira lenta. Todo SwiftUI puro sobre `TimelineView(.animation)`
/// a 30 fps, sin symbol effects ni shaders (iOS 17-safe).
public struct PulseVoiceOrb: View {
    public var mode: PulseOrbMode
    public var diameter: CGFloat

    public init(mode: PulseOrbMode, diameter: CGFloat = 148) {
        self.mode = mode
        self.diameter = diameter
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            orb(time: context.date.timeIntervalSinceReferenceDate)
        }
        .frame(width: diameter * 1.5, height: diameter * 1.5)
        .animation(.easeInOut(duration: 0.45), value: mode)
        .accessibilityHidden(true)
    }

    // MARK: - Composición

    @ViewBuilder
    private func orb(time t: TimeInterval) -> some View {
        let color = mode.tone == .neutral ? PulseColor.textSecondary : mode.tone.color
        let breath = breathScale(time: t)
        let wobble = wobbleAmplitude(time: t)

        ZStack {
            haloLayer(color: color, time: t, wobble: wobble, breath: breath)

            if mode == .listening {
                listeningRipples(color: color, time: t)
            }

            if mode == .connecting {
                connectingComet(color: color, time: t)
            }

            coreLayer(color: color, time: t, wobble: wobble, breath: breath)
        }
        // Aísla los blendModes internos para que no "sumen" contra lo que
        // haya debajo del orbe en la pantalla.
        .compositingGroup()
    }

    /// Halo exterior: un blob más deformado y difuso que el núcleo, para que
    /// el resplandor también se sienta orgánico y sin bordes duros.
    private func haloLayer(color: Color, time t: TimeInterval, wobble: Double, breath: CGFloat) -> some View {
        OrbBlobShape(time: t, wobble: wobble * 1.7, speed: flowSpeed * 0.55, phase: 1.3)
            .fill(
                RadialGradient(
                    colors: [color.opacity(haloOpacity), color.opacity(0)],
                    center: .center,
                    startRadius: diameter * 0.18,
                    endRadius: diameter * 0.7
                )
            )
            .frame(width: diameter * 1.4, height: diameter * 1.4)
            .blur(radius: 10)
            .scaleEffect(breath)
    }

    /// Núcleo: base de volumen + nebulosa de wisps + iridiscencia + especular,
    /// todo recortado por el contorno orgánico.
    private func coreLayer(color: Color, time t: TimeInterval, wobble: Double, breath: CGFloat) -> some View {
        let energetic = mode == .listening || mode == .speaking
        // El mismo blob para el clip y el trazo del borde: deben coincidir.
        let rim = OrbBlobShape(time: t, wobble: wobble, speed: flowSpeed, phase: 0)

        return ZStack {
            // Volumen base: gradiente descentrado hacia arriba-izquierda.
            RadialGradient(
                colors: [
                    color.opacity(mode == .idle ? 0.34 : 0.72),
                    color.opacity(mode == .idle ? 0.12 : 0.24),
                    PulseColor.backgroundRaised,
                ],
                center: UnitPoint(x: 0.40, y: 0.34),
                startRadius: 0,
                endRadius: diameter * 0.66
            )

            // Nebulosa interior: tres manchas difusas que orbitan a
            // velocidades y sentidos distintos → sensación de profundidad.
            wisp(color: color, time: t, orbit: diameter * 0.22, size: diameter * 0.62,
                 speed: flowSpeed * 0.45, phase: 0.0, opacity: energetic ? 0.50 : 0.28)
            wisp(color: color, time: t, orbit: diameter * 0.30, size: diameter * 0.46,
                 speed: -flowSpeed * 0.28, phase: 2.4, opacity: energetic ? 0.36 : 0.20)
            wisp(color: .white, time: t, orbit: diameter * 0.16, size: diameter * 0.34,
                 speed: flowSpeed * 0.6, phase: 4.2, opacity: energetic ? 0.16 : 0.09)

            // Iridiscencia: barrido angular que gira despacio. Se funde a
            // `color.opacity(0)` (no `.clear`) para no ensuciar el tono.
            AngularGradient(
                colors: [
                    color.opacity(0),
                    color.opacity(0.30),
                    color.opacity(0),
                    Color.white.opacity(0.12),
                    color.opacity(0),
                ],
                center: .center,
                angle: .radians(t * flowSpeed * 0.5)
            )
            .blendMode(.plusLighter)
            .opacity(mode == .idle ? 0.55 : 0.95)

            // Brillo especular arriba-izquierda: ancla la "materialidad".
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.20), Color.white.opacity(0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: diameter * 0.26
                    )
                )
                .frame(width: diameter * 0.5, height: diameter * 0.5)
                .offset(x: -diameter * 0.15, y: -diameter * 0.18)
        }
        .frame(width: diameter, height: diameter)
        .clipShape(rim)
        // Borde suave: un pelo de blur mata el aliasing del contorno curvo.
        .overlay(
            rim
                .stroke(color.opacity(0.45), lineWidth: 1)
                .blur(radius: 0.6)
        )
        .compositingGroup()
        .scaleEffect(coreScale(time: t, base: breath))
        .pulseGlow(color, radius: 26, opacity: mode == .idle ? 0.14 : 0.42)
    }

    /// Mancha luminosa difusa que orbita el centro del núcleo.
    private func wisp(color: Color, time t: TimeInterval, orbit: CGFloat, size: CGFloat,
                      speed: Double, phase: Double, opacity: Double) -> some View {
        let angle = t * speed + phase
        return Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(opacity), color.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: size * 0.5
                )
            )
            .frame(width: size, height: size)
            .offset(x: CGFloat(cos(angle)) * orbit, y: CGFloat(sin(angle)) * orbit)
            .blur(radius: size * 0.12)
            .blendMode(.plusLighter)
    }

    /// Ondas de escucha: contornos orgánicos (no círculos) que se expanden
    /// y desvanecen, como ondas en agua fría.
    private func listeningRipples(color: Color, time t: TimeInterval) -> some View {
        ForEach(0..<3, id: \.self) { index in
            let progress = ripple(time: t, offset: Double(index) / 3)
            let fade = (1 - progress) * (1 - progress)
            OrbBlobShape(time: t * 0.6, wobble: 0.02, speed: 0.5, phase: Double(index) * 1.7)
                .stroke(color.opacity(0.5 * fade), lineWidth: 1.2)
                .frame(width: diameter, height: diameter)
                .scaleEffect(0.9 + progress * 0.55)
                .blur(radius: 0.5)
        }
    }

    /// Cometa de conexión: un arco-estela con cabeza brillante orbitando el
    /// núcleo. La estela usa un gradiente angular alineado con el trim para
    /// que se desvanezca hacia la cola.
    private func connectingComet(color: Color, time t: TimeInterval) -> some View {
        let radius = diameter * 0.58
        let sweep = 0.28
        let headAngle = sweep * 2 * .pi
        let spin = t.truncatingRemainder(dividingBy: 4) / 4 * 2 * .pi
        return ZStack {
            Circle()
                .trim(from: 0, to: sweep)
                .stroke(
                    AngularGradient(
                        colors: [color.opacity(0), color.opacity(0.7)],
                        center: .center,
                        startAngle: .zero,
                        endAngle: .radians(headAngle)
                    ),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
                .frame(width: radius * 2, height: radius * 2)
            Circle()
                .fill(color.opacity(0.9))
                .frame(width: 5, height: 5)
                .offset(x: radius * CGFloat(cos(headAngle)), y: radius * CGFloat(sin(headAngle)))
                .pulseGlow(color, radius: 6, opacity: 0.8)
        }
        .rotationEffect(.radians(spin))
    }

    // MARK: - Parámetros por modo

    private var haloOpacity: Double {
        switch mode {
        case .idle: 0.10
        case .connecting: 0.16
        case .listening: 0.26
        case .speaking: 0.34
        }
    }

    /// Velocidad del "flujo" interno (deformación, wisps, iridiscencia).
    private var flowSpeed: Double {
        switch mode {
        case .idle: 0.35
        case .connecting: 0.7
        case .listening: 0.9
        case .speaking: 2.2
        }
    }

    /// Amplitud de la deformación del contorno. Al hablar se modula con un
    /// batido de dos senoides para simular turbulencia de voz.
    private func wobbleAmplitude(time t: TimeInterval) -> Double {
        switch mode {
        case .idle: 0.018
        case .connecting: 0.030
        case .listening: 0.035
        case .speaking: 0.055 + 0.030 * abs(sin(t * 2 * .pi / 0.31) * sin(t * 2 * .pi / 0.9))
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

    /// Progreso 0→1 cíclico para las ondas de escucha.
    private func ripple(time t: TimeInterval, offset: Double) -> Double {
        let period = 1.9
        return ((t / period) + offset).truncatingRemainder(dividingBy: 1)
    }
}

// MARK: - Contorno orgánico

/// Blob de curvas Bézier: el radio de cada punto de control oscila con tres
/// senoides de frecuencia angular distinta (3, 5 y 2 lóbulos) desfasadas en
/// el tiempo, y los puntos se unen con un spline Catmull-Rom cerrado. El
/// radio base se encoge en `wobble` para que la deformación nunca desborde
/// el rect (evita recortes duros al usarlo como `clipShape`).
private struct OrbBlobShape: Shape {
    var time: Double
    var wobble: Double
    var speed: Double
    var phase: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let base = min(rect.width, rect.height) / 2 * CGFloat(1 - wobble)
        let count = 12
        let t = time * speed

        var points: [CGPoint] = []
        points.reserveCapacity(count)
        for index in 0..<count {
            let angle = Double(index) / Double(count) * 2 * .pi
            // Suma normalizada (0.55 + 0.30 + 0.15 = 1) para acotar el offset.
            let offset =
                0.55 * sin(angle * 3 + t * 1.9 + phase)
                + 0.30 * sin(angle * 5 - t * 1.3 + phase * 2.1)
                + 0.15 * sin(angle * 2 + t * 0.7 + phase * 0.6)
            let radius = base * CGFloat(1 + wobble * offset)
            points.append(CGPoint(
                x: center.x + CGFloat(cos(angle)) * radius,
                y: center.y + CGFloat(sin(angle)) * radius
            ))
        }

        // Catmull-Rom cerrado → tramos cúbicos suaves sin esquinas.
        var path = Path()
        path.move(to: points[0])
        for index in 0..<count {
            let p0 = points[(index - 1 + count) % count]
            let p1 = points[index]
            let p2 = points[(index + 1) % count]
            let p3 = points[(index + 2) % count]
            let control1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let control2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: control1, control2: control2)
        }
        path.closeSubpath()
        return path
    }
}

#if os(iOS)
#Preview("Orbe · estados") {
    VStack(spacing: PulseSpacing.xl) {
        HStack(spacing: 0) {
            VStack(spacing: PulseSpacing.xs) {
                PulseVoiceOrb(mode: .idle, diameter: 90)
                Text("idle").font(.caption).foregroundStyle(PulseColor.textSecondary)
            }
            VStack(spacing: PulseSpacing.xs) {
                PulseVoiceOrb(mode: .connecting, diameter: 90)
                Text("connecting").font(.caption).foregroundStyle(PulseColor.textSecondary)
            }
        }
        HStack(spacing: 0) {
            VStack(spacing: PulseSpacing.xs) {
                PulseVoiceOrb(mode: .listening, diameter: 90)
                Text("listening").font(.caption).foregroundStyle(PulseColor.textSecondary)
            }
            VStack(spacing: PulseSpacing.xs) {
                PulseVoiceOrb(mode: .speaking, diameter: 90)
                Text("speaking").font(.caption).foregroundStyle(PulseColor.textSecondary)
            }
        }
    }
    .pulseScreenBackground()
}
#endif

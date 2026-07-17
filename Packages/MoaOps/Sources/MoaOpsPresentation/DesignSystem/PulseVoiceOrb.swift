import SwiftUI

/// Estado visual del orbe de voz.
public enum PulseOrbMode: Equatable, Sendable {
    /// En reposo: nebulosa fría y serena, deriva muy lenta.
    case idle
    /// Conectando o reconectando: una veta de luz circula, expectante.
    case connecting
    /// Escuchando al dueño: aurora cian, más luminosa y con más flujo.
    case listening
    /// Pulse habla: nebulosa cálida ember con vetas crema, más energía.
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
/// Una esfera de cristal perfecta con una nebulosa dentro: nubes de color
/// muy difuminadas que derivan en órbitas lentas, se cruzan y se funden
/// como tinta en agua oscura. El contorno es un círculo limpio; todo el
/// arte vive en el relleno. SwiftUI puro sobre `TimelineView(.animation)`
/// a 30 fps, compuesto en GPU con `drawingGroup()` (iOS 17-safe, sin
/// symbol effects ni shaders).
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
        .animation(.easeInOut(duration: 0.6), value: mode)
        .accessibilityHidden(true)
    }

    // MARK: - Composición

    @ViewBuilder
    private func orb(time t: TimeInterval) -> some View {
        let breath = breathScale(time: t)

        ZStack {
            // Halo exterior difuso, respira con la esfera.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [glowColor.opacity(haloOpacity), glowColor.opacity(0)],
                        center: .center,
                        startRadius: diameter * 0.20,
                        endRadius: diameter * 0.72
                    )
                )
                .frame(width: diameter * 1.5, height: diameter * 1.5)
                .scaleEffect(breath)

            sphere(time: t)
                .scaleEffect(coreScale(time: t, base: breath))
                .pulseGlow(glowColor, radius: 26, opacity: mode == .idle ? 0.14 : 0.40)
        }
    }

    /// La esfera: base oscura + nebulosa + volumen (sombra/especular),
    /// todo recortado por un círculo perfecto y con borde de cristal.
    private func sphere(time t: TimeInterval) -> some View {
        ZStack {
            // Base oscura con un matiz del modo arriba: da profundidad y
            // evita que las nubes floten sobre negro puro.
            RadialGradient(
                colors: [
                    tintColor.opacity(0.30),
                    PulseColor.backgroundRaised,
                    PulseColor.backgroundBase,
                ],
                center: UnitPoint(x: 0.5, y: 0.40),
                startRadius: 0,
                endRadius: diameter * 0.70
            )

            // Nebulosa: las nubes giran juntas muy despacio ADEMÁS de sus
            // órbitas propias, para que las mezclas nunca se repitan igual.
            ZStack {
                ForEach(0..<Self.clouds.count, id: \.self) { index in
                    cloud(Self.clouds[index], color: palette[index], time: t)
                }
            }
            .rotationEffect(.radians(t * 0.05 * flowSpeed))

            if mode == .connecting {
                connectingStreak(time: t)
            }

            // Sombra interior desde abajo: vende el volumen esférico.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.black.opacity(0.42), Color.black.opacity(0)],
                        center: UnitPoint(x: 0.5, y: 1.18),
                        startRadius: diameter * 0.1,
                        endRadius: diameter * 0.85
                    )
                )

            // Brillo especular arriba-izquierda: highlight de cristal.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.18), Color.white.opacity(0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: diameter * 0.26
                    )
                )
                .frame(width: diameter * 0.52, height: diameter * 0.52)
                .offset(x: -diameter * 0.15, y: -diameter * 0.19)
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        // Todo el interior (blurs + blendModes) se compone en GPU de una vez.
        .drawingGroup()
        // Borde de cristal: más luz arriba, casi nada abajo.
        .overlay(
            Circle().strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(0.30), Color.white.opacity(0.04)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
        )
    }

    /// Una nube: elipse rellena con gradiente color→transparente, muy
    /// difuminada, que deriva en una órbita senoidal lenta con fase propia
    /// y rota sobre sí misma. `plusLighter` hace que al cruzarse SUMEN luz,
    /// que es lo que da el efecto acuarela.
    private func cloud(_ spec: CloudSpec, color: Color, time t: TimeInterval) -> some View {
        let flow = flowSpeed
        let x = sin(t * spec.freqX * flow + spec.phase) * Double(spec.orbit)
        let y = cos(t * spec.freqY * flow + spec.phase * 1.7) * Double(spec.orbit) * 0.8
        let width = diameter * spec.size
        return Ellipse()
            .fill(
                RadialGradient(
                    colors: [color.opacity(spec.baseOpacity * luminosity), color.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: width * 0.5
                )
            )
            .frame(width: width, height: width * spec.aspect)
            .rotationEffect(.radians(t * spec.spin * flow + spec.phase))
            .offset(x: diameter * CGFloat(x), y: diameter * CGFloat(y))
            .blur(radius: diameter * 0.055)
            .blendMode(.plusLighter)
    }

    /// Veta de luz que circula por el interior mientras conecta.
    private func connectingStreak(time t: TimeInterval) -> some View {
        let angle = t * 0.9
        let orbit = diameter * 0.30
        return Ellipse()
            .fill(
                RadialGradient(
                    colors: [Color.white.opacity(0.34), Color.white.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter * 0.22
                )
            )
            .frame(width: diameter * 0.44, height: diameter * 0.20)
            // La veta apunta en la dirección de avance (tangente a la órbita).
            .rotationEffect(.radians(angle + .pi / 2))
            .offset(x: CGFloat(cos(angle)) * orbit, y: CGFloat(sin(angle)) * orbit)
            .blur(radius: diameter * 0.03)
            .blendMode(.plusLighter)
    }

    // MARK: - Nubes

    private struct CloudSpec {
        let size: CGFloat       // ancho relativo al diámetro
        let aspect: CGFloat     // alto = ancho * aspect (elipse, no bola)
        let orbit: CGFloat      // radio de deriva relativo al diámetro
        let freqX: Double       // rad/s antes del multiplicador de modo
        let freqY: Double
        let phase: Double
        let spin: Double        // rotación propia, rad/s
        let baseOpacity: Double
    }

    /// Frecuencias inconmensurables entre sí y fases repartidas: el patrón
    /// de mezcla tarda minutos en parecerse a sí mismo.
    private static let clouds: [CloudSpec] = [
        CloudSpec(size: 0.95, aspect: 0.80, orbit: 0.15, freqX: 0.13, freqY: 0.17, phase: 0.0, spin: 0.05, baseOpacity: 0.85),
        CloudSpec(size: 0.70, aspect: 0.60, orbit: 0.24, freqX: 0.21, freqY: 0.15, phase: 2.1, spin: -0.08, baseOpacity: 0.70),
        CloudSpec(size: 0.55, aspect: 0.90, orbit: 0.28, freqX: 0.17, freqY: 0.23, phase: 4.0, spin: 0.06, baseOpacity: 0.34),
        CloudSpec(size: 0.80, aspect: 0.55, orbit: 0.20, freqX: 0.11, freqY: 0.19, phase: 5.3, spin: -0.04, baseOpacity: 0.60),
        CloudSpec(size: 0.48, aspect: 0.75, orbit: 0.30, freqX: 0.25, freqY: 0.13, phase: 1.2, spin: 0.09, baseOpacity: 0.50),
    ]

    /// Un color por nube, alineado con `clouds`. La posición 2 es siempre la
    /// veta clara (blanco → crema sobre ember, bruma sobre cian).
    private var palette: [Color] {
        switch mode {
        case .idle, .connecting:
            [
                PulseColor.listening,
                PulseColor.textSecondary,
                Color.white,
                PulseColor.listening,
                PulseColor.textSecondary,
            ]
        case .listening:
            [
                PulseColor.listening,
                PulseColor.listening,
                Color.white,
                PulseColor.listening,
                PulseColor.textSecondary,
            ]
        case .speaking:
            [
                PulseColor.ember,
                PulseColor.warning,
                Color.white,
                PulseColor.ember,
                PulseColor.warning,
            ]
        }
    }

    // MARK: - Parámetros por modo

    /// Color del halo/glow exterior; el interior lo pone la paleta.
    private var glowColor: Color {
        mode.tone == .neutral ? PulseColor.textSecondary : mode.tone.color
    }

    /// Matiz de la base oscura bajo la nebulosa.
    private var tintColor: Color {
        switch mode {
        case .idle, .connecting, .listening: PulseColor.listening
        case .speaking: PulseColor.ember
        }
    }

    private var haloOpacity: Double {
        switch mode {
        case .idle: 0.10
        case .connecting: 0.16
        case .listening: 0.26
        case .speaking: 0.32
        }
    }

    /// Multiplicador de velocidad del flujo interno.
    private var flowSpeed: Double {
        switch mode {
        case .idle: 0.9
        case .connecting: 1.6
        case .listening: 2.4
        case .speaking: 4.0
        }
    }

    /// Brillo global de las nubes. En reposo la nebulosa es tenue; al
    /// escuchar/hablar sube la luz, no solo la velocidad.
    private var luminosity: Double {
        switch mode {
        case .idle: 0.30
        case .connecting: 0.38
        case .listening: 0.55
        case .speaking: 0.60
        }
    }

    /// Respiración senoidal lenta; más viva al hablar.
    private func breathScale(time t: TimeInterval) -> CGFloat {
        let period: Double = mode == .speaking ? 1.1 : 3.6
        let amplitude: Double = mode == .speaking ? 0.040 : 0.018
        return CGFloat(1 + amplitude * sin(t * 2 * .pi / period))
    }

    /// Al hablar, superpone un latido rápido de "amplitud de voz" simulada.
    /// // TODO: cuando el motor exponga niveles de audio reales (RMS del PCM),
    /// // sustituir esta senoide por la amplitud medida.
    private func coreScale(time t: TimeInterval, base: CGFloat) -> CGFloat {
        guard mode == .speaking else { return base }
        let flutter = 0.025 * sin(t * 2 * .pi / 0.27) * sin(t * 2 * .pi / 0.83)
        return base + CGFloat(flutter)
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

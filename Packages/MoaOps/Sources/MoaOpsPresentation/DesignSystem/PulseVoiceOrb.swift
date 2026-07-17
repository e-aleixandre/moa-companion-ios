import SwiftUI

/// Estado visual del orbe de voz.
public enum PulseOrbMode: Equatable, Sendable {
    /// En reposo: nebulosa fría y serena, deriva muy lenta.
    case idle
    /// Conectando o despertando: una veta de luz circula, expectante.
    case connecting
    /// Escuchando al dueño: aurora cian que florece con su voz.
    case listening
    /// Pulse piensa/resuelve: vórtice dorado concentrado hacia dentro.
    case thinking
    /// Pulse habla: nebulosa cálida ember que late con su voz.
    case speaking

    var tone: PulseTone {
        switch self {
        case .idle, .connecting: .neutral
        case .listening: .listening
        case .thinking: .warning
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
    /// Nivel 0..1 de la voz relevante (la del dueño al escuchar, la de Pulse
    /// al hablar). Llega ya suavizado con envolvente desde la capa de audio;
    /// aquí solo se traduce a luz, escala y densidad de nebulosa.
    public var level: Float

    public init(mode: PulseOrbMode, diameter: CGFloat = 148, level: Float = 0) {
        self.mode = mode
        self.diameter = diameter
        self.level = level
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
            // Halo exterior difuso: respira con la esfera y FLORECE con la voz
            // — es la capa que más se ve de reojo, así que lleva la reacción
            // más generosa al nivel.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [glowColor.opacity(haloOpacity + 0.30 * boost), glowColor.opacity(0)],
                        center: .center,
                        startRadius: diameter * 0.20,
                        endRadius: diameter * (0.72 + 0.10 * boost)
                    )
                )
                .frame(width: diameter * 1.5, height: diameter * 1.5)
                .scaleEffect(breath + CGFloat(0.05 * boost))

            sphere(time: t)
                .scaleEffect(coreScale(time: t, base: breath))
                .pulseGlow(glowColor, radius: 26, opacity: mode == .idle ? 0.10 : 0.40)

            // El instante de DESPERTAR: al entrar en escucha, la vista se
            // inserta y su onAppear dispara una única onda que se expande y
            // se apaga — el "abrir los ojos" al oír «Pulse». Ligada a la
            // inserción (no a onChange) para no depender de APIs con firma
            // distinta entre iOS 17 y macOS 13.
            if mode == .listening {
                WakeBloomRing(color: PulseColor.listening, diameter: diameter)
            }
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
            // Al pensar, el conjunto gira mucho más rápido y las órbitas se
            // contraen (orbitScale): la nebulosa se vuelve un vórtice denso y
            // concentrado, "mirando hacia dentro" — lo contrario de escuchar,
            // que se abre hacia el dueño.
            ZStack {
                ForEach(0..<Self.clouds.count, id: \.self) { index in
                    cloud(Self.clouds[index], color: palette[index], time: t)
                }
            }
            .rotationEffect(.radians(t * nebulaSpin))

            if mode == .connecting {
                connectingStreak(time: t)
            }

            if mode == .thinking {
                thinkingMotes(time: t)
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
            .offset(x: diameter * CGFloat(x) * orbitScale, y: diameter * CGFloat(y) * orbitScale)
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

    /// Dos motas de luz en contrarrotación cerrada: el "engranaje" visible
    /// del pensamiento. Pequeñas y rápidas para leerse como actividad
    /// interna, no como señal hacia el dueño.
    private func thinkingMotes(time t: TimeInterval) -> some View {
        ForEach(0..<2, id: \.self) { index in
            let direction: Double = index == 0 ? 1 : -1
            let angle = t * 1.6 * direction + Double(index) * .pi
            let orbit = diameter * (index == 0 ? 0.18 : 0.12)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.40), Color.white.opacity(0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: diameter * 0.10
                    )
                )
                .frame(width: diameter * 0.20, height: diameter * 0.20)
                .offset(x: CGFloat(cos(angle)) * orbit, y: CGFloat(sin(angle)) * orbit)
                .blur(radius: diameter * 0.02)
                .blendMode(.plusLighter)
        }
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
        case .thinking:
            [
                PulseColor.warning,
                PulseColor.ember,
                Color.white,
                PulseColor.warning,
                PulseColor.ember,
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

    /// Nivel de voz saneado a 0..1 en Double, listo para mezclar en opacidades.
    private var boost: Double {
        Double(min(max(level, 0), 1))
    }

    /// Color del halo/glow exterior; el interior lo pone la paleta.
    private var glowColor: Color {
        mode.tone == .neutral ? PulseColor.textSecondary : mode.tone.color
    }

    /// Matiz de la base oscura bajo la nebulosa.
    private var tintColor: Color {
        switch mode {
        case .idle, .connecting, .listening: PulseColor.listening
        case .thinking: PulseColor.warning
        case .speaking: PulseColor.ember
        }
    }

    private var haloOpacity: Double {
        switch mode {
        case .idle: 0.06
        case .connecting: 0.16
        case .listening: 0.24
        case .thinking: 0.20
        case .speaking: 0.30
        }
    }

    /// Multiplicador de velocidad del flujo interno.
    private var flowSpeed: Double {
        switch mode {
        case .idle: 0.7
        case .connecting: 1.6
        case .listening: 2.4
        case .thinking: 3.0
        case .speaking: 4.0
        }
    }

    /// Rotación de conjunto de la nebulosa. Al pensar es un orden de
    /// magnitud mayor: el giro colectivo ES el gesto de concentración.
    private var nebulaSpin: Double {
        mode == .thinking ? 0.55 : 0.05 * flowSpeed
    }

    /// Contracción de las órbitas de deriva de las nubes (vórtice al pensar).
    private var orbitScale: CGFloat {
        mode == .thinking ? 0.55 : 1.0
    }

    /// Brillo global de las nubes. En reposo la nebulosa es apenas un rescoldo
    /// (dormida); al escuchar/hablar sube la luz base Y ADEMÁS florece con el
    /// nivel de voz: la voz literalmente ilumina la nebulosa.
    private var luminosity: Double {
        let base: Double = switch mode {
        case .idle: 0.20
        case .connecting: 0.38
        case .listening: 0.50
        case .thinking: 0.52
        case .speaking: 0.55
        }
        let voiceGain: Double = switch mode {
        case .listening, .speaking: 0.55
        default: 0
        }
        return base + voiceGain * boost
    }

    /// Respiración senoidal. Dormido respira más hondo y lento (período
    /// largo) — el gesto universal de "está dormido"; hablando es más corta
    /// porque el latido real lo pone la voz en `coreScale`.
    private func breathScale(time t: TimeInterval) -> CGFloat {
        let period: Double
        let amplitude: Double
        switch mode {
        case .idle: period = 5.2; amplitude = 0.022
        case .connecting: period = 2.4; amplitude = 0.02
        case .listening: period = 3.2; amplitude = 0.015
        case .thinking: period = 1.6; amplitude = 0.012
        case .speaking: period = 1.4; amplitude = 0.015
        }
        return CGFloat(1 + amplitude * sin(t * 2 * .pi / period))
    }

    /// Latido por voz REAL: la envolvente del RMS empuja la escala. Al hablar
    /// late con la voz de Pulse (gesto grande); al escuchar asiente con la del
    /// dueño (gesto sutil: te está oyendo, no compitiendo contigo).
    private func coreScale(time t: TimeInterval, base: CGFloat) -> CGFloat {
        switch mode {
        case .speaking: base + CGFloat(0.065 * boost)
        case .listening: base + CGFloat(0.030 * boost)
        default: base
        }
    }
}

// MARK: - Onda de despertar

/// Anillo que se expande una sola vez cuando el orbe empieza a escuchar.
private struct WakeBloomRing: View {
    let color: Color
    let diameter: CGFloat
    @State private var bloomed = false

    var body: some View {
        Circle()
            .strokeBorder(color.opacity(bloomed ? 0 : 0.65), lineWidth: 2)
            .frame(width: diameter, height: diameter)
            .scaleEffect(bloomed ? 1.45 : 0.95)
            .blur(radius: 1)
            .onAppear {
                withAnimation(.easeOut(duration: 0.9)) { bloomed = true }
            }
            .allowsHitTesting(false)
    }
}

#if os(iOS)
#Preview("Orbe · estados") {
    VStack(spacing: PulseSpacing.xl) {
        HStack(spacing: 0) {
            VStack(spacing: PulseSpacing.xs) {
                PulseVoiceOrb(mode: .idle, diameter: 80)
                Text("idle").font(.caption).foregroundStyle(PulseColor.textSecondary)
            }
            VStack(spacing: PulseSpacing.xs) {
                PulseVoiceOrb(mode: .connecting, diameter: 80)
                Text("connecting").font(.caption).foregroundStyle(PulseColor.textSecondary)
            }
            VStack(spacing: PulseSpacing.xs) {
                PulseVoiceOrb(mode: .thinking, diameter: 80)
                Text("thinking").font(.caption).foregroundStyle(PulseColor.textSecondary)
            }
        }
        HStack(spacing: 0) {
            VStack(spacing: PulseSpacing.xs) {
                PulseVoiceOrb(mode: .listening, diameter: 80)
                Text("listening").font(.caption).foregroundStyle(PulseColor.textSecondary)
            }
            VStack(spacing: PulseSpacing.xs) {
                PulseVoiceOrb(mode: .speaking, diameter: 80)
                Text("speaking").font(.caption).foregroundStyle(PulseColor.textSecondary)
            }
        }
    }
    .pulseScreenBackground()
}

#Preview("Orbe · reactivo a la voz") {
    VStack(spacing: PulseSpacing.xl) {
        HStack(spacing: 0) {
            ForEach([Float(0.0), 0.4, 0.9], id: \.self) { level in
                VStack(spacing: PulseSpacing.xs) {
                    PulseVoiceOrb(mode: .listening, diameter: 80, level: level)
                    Text("escucha \(level, specifier: "%.1f")")
                        .font(.caption).foregroundStyle(PulseColor.textSecondary)
                }
            }
        }
        HStack(spacing: 0) {
            ForEach([Float(0.0), 0.4, 0.9], id: \.self) { level in
                VStack(spacing: PulseSpacing.xs) {
                    PulseVoiceOrb(mode: .speaking, diameter: 80, level: level)
                    Text("habla \(level, specifier: "%.1f")")
                        .font(.caption).foregroundStyle(PulseColor.textSecondary)
                }
            }
        }
    }
    .pulseScreenBackground()
}
#endif

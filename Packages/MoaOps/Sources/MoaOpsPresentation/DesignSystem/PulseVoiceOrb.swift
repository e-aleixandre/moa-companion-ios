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

    /// Memoria continua del orbe entre frames (fases integradas y parámetros
    /// suavizados). Es una clase a propósito: mutarla durante el tick del
    /// TimelineView no dispara invalidaciones extra de SwiftUI.
    @State private var dynamics = OrbDynamics()

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
        // Un solo punto de verdad por frame: todos los parámetros que dependen
        // del modo salen ya SUAVIZADOS de aquí, nunca directos de un switch.
        let f = dynamics.advance(to: t, mode: mode, boost: boost)
        let breath = CGFloat(1 + f.breathAmplitude * sin(f.breathPhase))

        ZStack {
            // Halo exterior difuso: respira con la esfera y FLORECE con la voz
            // — es la capa que más se ve de reojo, así que lleva la reacción
            // más generosa al nivel.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [glowColor.opacity(f.haloOpacity + 0.30 * boost), glowColor.opacity(0)],
                        center: .center,
                        startRadius: diameter * 0.20,
                        endRadius: diameter * (0.72 + 0.10 * boost)
                    )
                )
                .frame(width: diameter * 1.5, height: diameter * 1.5)
                .scaleEffect(breath + CGFloat(0.05 * boost))

            sphere(frame: f, time: t)
                .scaleEffect(breath + CGFloat(f.voiceScale * boost))
                .pulseGlow(glowColor, radius: 26, opacity: f.glowStrength)

            // El instante de DESPERTAR: al entrar en escucha, la vista se
            // inserta y su onAppear dispara una única onda que se expande y
            // se apaga — el "abrir los ojos" al oír «Pulse». Ligada a la
            // inserción (no a onChange) para no depender de APIs con firma
            // distinta entre iOS 17 y macOS 13.
            if mode == .listening {
                WakeBloomRing(color: PulseColor.listening, diameter: diameter)
                    .transition(.opacity)
            }
        }
    }

    /// La esfera: base oscura + nebulosa + volumen (sombra/especular),
    /// todo recortado por un círculo perfecto y con borde de cristal.
    private func sphere(frame f: OrbDynamics.Frame, time t: TimeInterval) -> some View {
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
                    cloud(Self.clouds[index], color: palette[index], frame: f)
                }
            }
            .rotationEffect(.radians(f.spinPhase))

            // Los adornos por-modo entran y salen con fundido: la animación
            // implícita de `mode` solo gobierna ya colores y estas transiciones.
            if mode == .connecting {
                connectingStreak(time: t)
                    .transition(.opacity)
            }

            if mode == .thinking {
                ZStack { thinkingMotes(time: t) }
                    .transition(.opacity)
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
    private func cloud(_ spec: CloudSpec, color: Color, frame f: OrbDynamics.Frame) -> some View {
        // Las órbitas se calculan sobre la FASE integrada, no sobre `t` por un
        // multiplicador de modo: así un cambio de velocidad nunca teletransporta
        // la nube, solo acelera o frena su deriva desde donde está.
        let x = sin(f.flowPhase * spec.freqX + spec.phase) * Double(spec.orbit)
        let y = cos(f.flowPhase * spec.freqY + spec.phase * 1.7) * Double(spec.orbit) * 0.8
        let width = diameter * spec.size
        return Ellipse()
            .fill(
                RadialGradient(
                    colors: [color.opacity(spec.baseOpacity * f.luminosity), color.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: width * 0.5
                )
            )
            .frame(width: width, height: width * spec.aspect)
            .rotationEffect(.radians(f.flowPhase * spec.spin + spec.phase))
            .offset(x: diameter * CGFloat(x) * f.orbitScale, y: diameter * CGFloat(y) * f.orbitScale)
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

}

// MARK: - Dinámica continua entre estados

/// Memoria del orbe entre frames. La causa del salto errático al cambiar de
/// estado era doble: (1) el movimiento multiplicaba el tiempo ABSOLUTO por
/// una velocidad por-modo (`t * flowSpeed`), y como `t` es enorme, cambiar el
/// multiplicador producía saltos de fase de millones de radianes que la
/// animación implícita encima intentaba recorrer en 0.6 s (giro/teletransporte
/// frenético); (2) opacidades, órbitas y respiración salían de un switch y
/// cambiaban de golpe. Aquí las velocidades se INTEGRAN en fases
/// (`fase += velocidad · dt`) y cada parámetro PERSIGUE su objetivo de modo
/// con una envolvente exponencial (τ ≈ 0.55 s, independiente del framerate):
/// el cruce de estado es una rampa continua, nunca un corte.
private final class OrbDynamics {
    struct Frame {
        var flowPhase: Double
        var spinPhase: Double
        var breathPhase: Double
        var breathAmplitude: Double
        var orbitScale: CGFloat
        var haloOpacity: Double
        var luminosity: Double
        var voiceScale: Double
        var glowStrength: Double
    }

    /// Valores de régimen de cada modo (los mismos que antes vivían en los
    /// switch de la vista, ahora como objetivos a perseguir).
    private struct Targets {
        var flowSpeed: Double
        var spinSpeed: Double
        var breathRate: Double
        var breathAmplitude: Double
        var orbitScale: Double
        var haloOpacity: Double
        var luminosityBase: Double
        var voiceGain: Double
        var voiceScale: Double
        var glowStrength: Double

        init(mode: PulseOrbMode) {
            // Respiración: dormido más honda y lenta; hablando corta porque el
            // latido real lo pone la voz vía voiceScale. Al pensar, el giro de
            // conjunto (spinSpeed) es un orden de magnitud mayor y las órbitas
            // se contraen: el vórtice de concentración.
            switch mode {
            case .idle:
                flowSpeed = 0.7; spinSpeed = 0.035
                breathRate = 2 * .pi / 5.2; breathAmplitude = 0.022
                orbitScale = 1.0; haloOpacity = 0.06; luminosityBase = 0.20
                voiceGain = 0; voiceScale = 0; glowStrength = 0.10
            case .connecting:
                flowSpeed = 1.6; spinSpeed = 0.08
                breathRate = 2 * .pi / 2.4; breathAmplitude = 0.02
                orbitScale = 1.0; haloOpacity = 0.16; luminosityBase = 0.38
                voiceGain = 0; voiceScale = 0; glowStrength = 0.40
            case .listening:
                flowSpeed = 2.4; spinSpeed = 0.12
                breathRate = 2 * .pi / 3.2; breathAmplitude = 0.015
                orbitScale = 1.0; haloOpacity = 0.24; luminosityBase = 0.50
                voiceGain = 0.55; voiceScale = 0.030; glowStrength = 0.40
            case .thinking:
                flowSpeed = 3.0; spinSpeed = 0.55
                breathRate = 2 * .pi / 1.6; breathAmplitude = 0.012
                orbitScale = 0.55; haloOpacity = 0.20; luminosityBase = 0.52
                voiceGain = 0; voiceScale = 0; glowStrength = 0.40
            case .speaking:
                flowSpeed = 4.0; spinSpeed = 0.20
                breathRate = 2 * .pi / 1.4; breathAmplitude = 0.015
                orbitScale = 1.0; haloOpacity = 0.30; luminosityBase = 0.55
                voiceGain = 0.55; voiceScale = 0.065; glowStrength = 0.40
            }
        }
    }

    private var lastTime: TimeInterval?
    private var current: Targets = Targets(mode: .idle)
    private var flowPhase = 0.0
    private var spinPhase = 0.0
    private var breathPhase = 0.0

    func advance(to t: TimeInterval, mode: PulseOrbMode, boost: Double) -> Frame {
        let targets = Targets(mode: mode)

        if let last = lastTime {
            // dt acotado: tras una pausa larga (background, preview congelada)
            // el orbe continúa suave desde donde estaba, sin teletransportes.
            let dt = min(max(t - last, 0), 0.1)
            // Envolvente exponencial hacia el objetivo, estable a cualquier fps.
            let k = 1 - exp(-dt / 0.55)
            current.flowSpeed += (targets.flowSpeed - current.flowSpeed) * k
            current.spinSpeed += (targets.spinSpeed - current.spinSpeed) * k
            current.breathRate += (targets.breathRate - current.breathRate) * k
            current.breathAmplitude += (targets.breathAmplitude - current.breathAmplitude) * k
            current.orbitScale += (targets.orbitScale - current.orbitScale) * k
            current.haloOpacity += (targets.haloOpacity - current.haloOpacity) * k
            current.luminosityBase += (targets.luminosityBase - current.luminosityBase) * k
            current.voiceGain += (targets.voiceGain - current.voiceGain) * k
            current.voiceScale += (targets.voiceScale - current.voiceScale) * k
            current.glowStrength += (targets.glowStrength - current.glowStrength) * k
            flowPhase += current.flowSpeed * dt
            spinPhase += current.spinSpeed * dt
            breathPhase += current.breathRate * dt
        } else {
            // Primer frame: nace ya en régimen del modo actual, sin rampa.
            current = targets
        }
        lastTime = t

        return Frame(
            flowPhase: flowPhase,
            spinPhase: spinPhase,
            breathPhase: breathPhase,
            breathAmplitude: current.breathAmplitude,
            orbitScale: CGFloat(current.orbitScale),
            haloOpacity: current.haloOpacity,
            // La voz ilumina la nebulosa; su ganancia también entra en rampa,
            // así el brillo por voz no aparece de golpe al entrar en escucha.
            luminosity: current.luminosityBase + current.voiceGain * boost,
            voiceScale: current.voiceScale,
            glowStrength: current.glowStrength
        )
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

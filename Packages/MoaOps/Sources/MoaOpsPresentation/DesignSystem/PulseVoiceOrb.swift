import SwiftUI

/// Visual state of the voice orb.
public enum PulseOrbMode: Equatable, Sendable {
    /// At rest: cold, serene nebula, very slow drift.
    case idle
    /// Connecting or waking up: a streak of light circulates, expectant.
    case connecting
    /// Listening to the owner: cyan aurora that blooms with their voice.
    case listening
    /// Pulse thinks/works something out: golden vortex focused inward.
    case thinking
    /// Pulse speaks: warm ember nebula that beats with its voice.
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

/// The Pulse voice orb: the emotional focal point of the call screen.
///
/// A perfect glass sphere with a nebula inside: heavily blurred clouds of
/// color drifting along slow orbits, crossing and blending like ink in
/// dark water. The outline is a clean circle; all the art lives in the
/// fill. Pure SwiftUI on top of `TimelineView(.animation)` at 30 fps,
/// GPU-composited with `drawingGroup()` (iOS 17-safe, no symbol effects
/// or shaders).
public struct PulseVoiceOrb: View {
    public var mode: PulseOrbMode
    public var diameter: CGFloat
    /// 0..1 level of the relevant voice (the owner's while listening, Pulse's
    /// while speaking). It arrives already envelope-smoothed from the audio
    /// layer; here it is only translated into light, scale and nebula density.
    public var level: Float

    public init(mode: PulseOrbMode, diameter: CGFloat = 148, level: Float = 0) {
        self.mode = mode
        self.diameter = diameter
        self.level = level
    }

    /// Continuous memory of the orb across frames (integrated phases and
    /// smoothed parameters). It is a class on purpose: mutating it during the
    /// TimelineView tick does not trigger extra SwiftUI invalidations.
    @State private var dynamics = OrbDynamics()

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            orb(time: context.date.timeIntervalSinceReferenceDate)
        }
        .frame(width: diameter * 1.5, height: diameter * 1.5)
        .animation(.easeInOut(duration: 0.6), value: mode)
        .accessibilityHidden(true)
    }

    // MARK: - Composition

    @ViewBuilder
    private func orb(time t: TimeInterval) -> some View {
        // A single source of truth per frame: every mode-dependent parameter
        // comes out of here already SMOOTHED, never straight from a switch.
        let f = dynamics.advance(to: t, mode: mode, boost: boost)
        let breath = CGFloat(1 + f.breathAmplitude * sin(f.breathPhase))

        ZStack {
            // Diffuse outer halo: breathes with the sphere and BLOOMS with the
            // voice — it is the layer most often seen out of the corner of the
            // eye, so it carries the most generous reaction to the level.
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

            // The WAKE moment: on entering listening, the view is inserted
            // and its onAppear fires a single ring that expands and fades
            // out — the "opening of the eyes" upon hearing «Pulse». Tied to
            // insertion (not onChange) to avoid depending on APIs whose
            // signature differs between iOS 17 and macOS 13.
            if mode == .listening {
                WakeBloomRing(color: PulseColor.listening, diameter: diameter)
                    .transition(.opacity)
            }
        }
    }

    /// The sphere: dark base + nebula + volume (shadow/specular), all
    /// clipped by a perfect circle and framed with a glass rim.
    private func sphere(frame f: OrbDynamics.Frame, time t: TimeInterval) -> some View {
        ZStack {
            // Dark base with a hint of the mode's tint at the top: adds depth
            // and keeps the clouds from floating over pure black.
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

            // Nebula: the clouds rotate together very slowly IN ADDITION to
            // their own orbits, so the blends never repeat the same way.
            // While thinking, the ensemble spins much faster and the orbits
            // contract (orbitScale): the nebula becomes a dense, focused
            // vortex, "looking inward" — the opposite of listening, which
            // opens up toward the owner.
            ZStack {
                ForEach(0..<Self.clouds.count, id: \.self) { index in
                    cloud(Self.clouds[index], color: palette[index], frame: f)
                }
            }
            .rotationEffect(.radians(f.spinPhase))

            // Per-mode embellishments fade in and out: the implicit `mode`
            // animation now only governs colors and these transitions.
            if mode == .connecting {
                connectingStreak(time: t)
                    .transition(.opacity)
            }

            if mode == .thinking {
                ZStack { thinkingMotes(time: t) }
                    .transition(.opacity)
            }

            // Inner shadow from below: sells the spherical volume.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.black.opacity(0.42), Color.black.opacity(0)],
                        center: UnitPoint(x: 0.5, y: 1.18),
                        startRadius: diameter * 0.1,
                        endRadius: diameter * 0.85
                    )
                )

            // Specular shine top-left: glass highlight.
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
        // The whole interior (blurs + blendModes) is GPU-composited at once.
        .drawingGroup()
        // Glass rim: more light at the top, almost none at the bottom.
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

    /// One cloud: an ellipse filled with a color→transparent gradient,
    /// heavily blurred, drifting along a slow sinusoidal orbit with its own
    /// phase and rotating on itself. `plusLighter` makes crossings ADD
    /// light, which is what produces the watercolor effect.
    private func cloud(_ spec: CloudSpec, color: Color, frame f: OrbDynamics.Frame) -> some View {
        // Orbits are computed from the integrated PHASE, not from `t` times a
        // per-mode multiplier: that way a speed change never teleports the
        // cloud, it only speeds up or slows down its drift from where it is.
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

    /// Streak of light circulating inside while connecting.
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
            // The streak points in the direction of travel (tangent to the orbit).
            .rotationEffect(.radians(angle + .pi / 2))
            .offset(x: CGFloat(cos(angle)) * orbit, y: CGFloat(sin(angle)) * orbit)
            .blur(radius: diameter * 0.03)
            .blendMode(.plusLighter)
    }

    /// Two motes of light in tight counter-rotation: the visible "gears" of
    /// thought. Small and fast so they read as internal activity, not as a
    /// signal directed at the owner.
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

    // MARK: - Clouds

    private struct CloudSpec {
        let size: CGFloat       // width relative to the diameter
        let aspect: CGFloat     // height = width * aspect (ellipse, not a ball)
        let orbit: CGFloat      // drift radius relative to the diameter
        let freqX: Double       // rad/s before the mode multiplier
        let freqY: Double
        let phase: Double
        let spin: Double        // self-rotation, rad/s
        let baseOpacity: Double
    }

    /// Mutually incommensurable frequencies and spread-out phases: the
    /// blending pattern takes minutes to resemble itself again.
    private static let clouds: [CloudSpec] = [
        CloudSpec(size: 0.95, aspect: 0.80, orbit: 0.15, freqX: 0.13, freqY: 0.17, phase: 0.0, spin: 0.05, baseOpacity: 0.85),
        CloudSpec(size: 0.70, aspect: 0.60, orbit: 0.24, freqX: 0.21, freqY: 0.15, phase: 2.1, spin: -0.08, baseOpacity: 0.70),
        CloudSpec(size: 0.55, aspect: 0.90, orbit: 0.28, freqX: 0.17, freqY: 0.23, phase: 4.0, spin: 0.06, baseOpacity: 0.34),
        CloudSpec(size: 0.80, aspect: 0.55, orbit: 0.20, freqX: 0.11, freqY: 0.19, phase: 5.3, spin: -0.04, baseOpacity: 0.60),
        CloudSpec(size: 0.48, aspect: 0.75, orbit: 0.30, freqX: 0.25, freqY: 0.13, phase: 1.2, spin: 0.09, baseOpacity: 0.50),
    ]

    /// One color per cloud, aligned with `clouds`. Position 2 is always the
    /// light streak (white → cream over ember, mist over cyan).
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

    // MARK: - Per-mode parameters

    /// Voice level sanitized to 0..1 as a Double, ready to blend into opacities.
    private var boost: Double {
        Double(min(max(level, 0), 1))
    }

    /// Color of the outer halo/glow; the interior comes from the palette.
    private var glowColor: Color {
        mode.tone == .neutral ? PulseColor.textSecondary : mode.tone.color
    }

    /// Tint of the dark base under the nebula.
    private var tintColor: Color {
        switch mode {
        case .idle, .connecting, .listening: PulseColor.listening
        case .thinking: PulseColor.warning
        case .speaking: PulseColor.ember
        }
    }

}

// MARK: - Continuous dynamics between states

/// Memory of the orb across frames. The erratic jump on state change had a
/// twofold cause: (1) the motion multiplied ABSOLUTE time by a per-mode
/// speed (`t * flowSpeed`), and since `t` is huge, changing the multiplier
/// produced phase jumps of millions of radians that the implicit animation
/// on top then tried to traverse in 0.6 s (frantic spinning/teleporting);
/// (2) opacities, orbits and breathing came from a switch and changed
/// abruptly. Here the speeds are INTEGRATED into phases
/// (`phase += speed · dt`) and each parameter CHASES its mode target with
/// an exponential envelope (τ ≈ 0.55 s, framerate-independent): the state
/// crossover is a continuous ramp, never a cut.
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

    /// Steady-state values for each mode (the same ones that used to live in
    /// the view's switches, now expressed as targets to chase).
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
            // Breathing: deeper and slower while asleep; short while speaking
            // because the real beat comes from the voice via voiceScale. While
            // thinking, the ensemble spin (spinSpeed) is an order of magnitude
            // larger and the orbits contract: the concentration vortex.
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
            // Clamped dt: after a long pause (background, frozen preview) the
            // orb resumes smoothly from where it was, with no teleporting.
            let dt = min(max(t - last, 0), 0.1)
            // Exponential envelope toward the target, stable at any fps.
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
            // First frame: born already at the current mode's steady state, no ramp.
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
            // The voice lights up the nebula; its gain also ramps in, so the
            // voice-driven glow never pops in abruptly when listening starts.
            luminosity: current.luminosityBase + current.voiceGain * boost,
            voiceScale: current.voiceScale,
            glowStrength: current.glowStrength
        )
    }
}

// MARK: - Wake ring

/// Ring that expands a single time when the orb starts listening.
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

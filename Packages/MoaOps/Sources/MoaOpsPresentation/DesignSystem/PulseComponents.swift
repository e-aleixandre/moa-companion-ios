import SwiftUI

// MARK: - Botones

/// Botón primario: relleno de acento (o del tono dado), texto oscuro, glow sutil.
/// La pieza protagonista (Llamar / Colgar).
public struct PulsePrimaryButtonStyle: ButtonStyle {
    public var tone: PulseTone

    public init(tone: PulseTone = .accent) { self.tone = tone }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PulseFont.headline)
            .foregroundStyle(PulseColor.textInverse)
            .padding(.vertical, 15)
            .padding(.horizontal, PulseSpacing.xl)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous)
                    .fill(tone.color)
            )
            .pulseGlow(tone.color, radius: 16, opacity: configuration.isPressed ? 0.15 : 0.35)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Botón secundario: superficie elevada con hairline, texto claro.
public struct PulseSecondaryButtonStyle: ButtonStyle {
    public var tone: PulseTone

    public init(tone: PulseTone = .neutral) { self.tone = tone }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PulseFont.headline)
            .foregroundStyle(tone == .neutral ? PulseColor.textPrimary : tone.color)
            .padding(.vertical, 14)
            .padding(.horizontal, PulseSpacing.lg)
            .background(
                RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous)
                    .fill(PulseColor.backgroundRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous)
                    .strokeBorder(PulseColor.hairline, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Botón circular de icono (silenciar, ajustes).
public struct PulseIconButtonStyle: ButtonStyle {
    public var tone: PulseTone
    public var diameter: CGFloat

    public init(tone: PulseTone = .neutral, diameter: CGFloat = 52) {
        self.tone = tone
        self.diameter = diameter
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: diameter * 0.36, weight: .medium))
            .foregroundStyle(tone == .neutral ? PulseColor.textPrimary : tone.color)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(PulseColor.backgroundRaised))
            .overlay(Circle().strokeBorder(PulseColor.hairline, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Pill de estado

/// Badge de estado con punto de color: "Escuchando", "Reconectando (2)"…
public struct PulseStatusPill: View {
    public var text: String
    public var tone: PulseTone
    /// Si el punto debe parpadear suavemente (estados transitorios).
    public var pulses: Bool

    public init(_ text: String, tone: PulseTone, pulses: Bool = false) {
        self.text = text
        self.tone = tone
        self.pulses = pulses
    }

    public var body: some View {
        HStack(spacing: PulseSpacing.xs) {
            dot
            Text(text)
                .font(PulseFont.footnote.weight(.medium))
                .foregroundStyle(PulseColor.textPrimary)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, PulseSpacing.sm)
        .background(Capsule().fill(PulseColor.backgroundRaised))
        .overlay(Capsule().strokeBorder(tone.color.opacity(0.25), lineWidth: 1))
    }

    @ViewBuilder
    private var dot: some View {
        if pulses {
            // Parpadeo sin @State animado: texto y flag pueden cambiar sin
            // dejar una animación repeatForever huérfana.
            TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: false)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                dotShape.opacity(0.65 + 0.35 * sin(t * 2 * .pi / 1.6))
            }
        } else {
            dotShape
        }
    }

    private var dotShape: some View {
        Circle()
            .fill(tone.color)
            .frame(width: 7, height: 7)
            .pulseGlow(tone.color, radius: 5, opacity: 0.6)
    }
}

// MARK: - Mensaje al usuario

/// Aviso inline (error, información) con tono semántico.
public struct PulseInlineNotice: View {
    public var text: String
    public var tone: PulseTone

    public init(_ text: String, tone: PulseTone = .danger) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PulseSpacing.xs) {
            Image(systemName: tone == .danger ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(PulseFont.footnote)
        }
        .foregroundStyle(tone.color)
        .padding(PulseSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: PulseRadius.control, style: .continuous)
                .fill(tone.color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: PulseRadius.control, style: .continuous)
                .strokeBorder(tone.color.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - Campo de texto

/// Campo de texto sobre superficie overlay; opción monoespaciada para
/// direcciones, códigos y demás material técnico.
public struct PulseTextField: View {
    public var placeholder: String
    @Binding public var text: String
    public var monospaced: Bool

    public init(_ placeholder: String, text: Binding<String>, monospaced: Bool = false) {
        self.placeholder = placeholder
        self._text = text
        self.monospaced = monospaced
    }

    public var body: some View {
        TextField(placeholder, text: $text)
            .font(monospaced ? PulseFont.monoLarge : PulseFont.body)
            .foregroundStyle(PulseColor.textPrimary)
            .tint(PulseColor.ember)
            .autocorrectionDisabled()
            .padding(.vertical, 12)
            .padding(.horizontal, PulseSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: PulseRadius.control, style: .continuous)
                    .fill(PulseColor.backgroundOverlay)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PulseRadius.control, style: .continuous)
                    .strokeBorder(PulseColor.hairline, lineWidth: 1)
            )
    }
}

// MARK: - Transcript

/// Burbuja de transcript: dueño a la derecha con tinte de acento, Pulse a la
/// izquierda sobre superficie.
public struct PulseCaptionBubble: View {
    public var text: String
    public var isOwner: Bool

    public init(text: String, isOwner: Bool) {
        self.text = text
        self.isOwner = isOwner
    }

    public var body: some View {
        Text(text)
            .font(PulseFont.callout)
            .foregroundStyle(PulseColor.textPrimary)
            .padding(.vertical, 9)
            .padding(.horizontal, PulseSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: PulseRadius.control, style: .continuous)
                    .fill(isOwner ? PulseColor.ember.opacity(0.16) : PulseColor.backgroundRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PulseRadius.control, style: .continuous)
                    .strokeBorder(
                        isOwner ? PulseColor.ember.opacity(0.28) : PulseColor.hairline,
                        lineWidth: 1
                    )
            )
            .frame(maxWidth: .infinity, alignment: isOwner ? .trailing : .leading)
    }
}

// MARK: - Cabecera de sección

/// Micro-cabecera en mayúsculas para agrupar contenido ("SERVIDOR", "TRANSCRIPCIÓN").
public struct PulseSectionHeader: View {
    public var title: String

    public init(_ title: String) { self.title = title }

    public var body: some View {
        Text(title)
            .pulseMicroCaps()
            .foregroundStyle(PulseColor.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Previews

#if os(iOS)
#Preview("Componentes") {
    ScrollView {
        VStack(alignment: .leading, spacing: PulseSpacing.lg) {
            PulseSectionHeader("Botones")
            Button("Llamar a Pulse") {}.buttonStyle(PulsePrimaryButtonStyle())
            Button("Colgar") {}.buttonStyle(PulsePrimaryButtonStyle(tone: .danger))
            Button("Introducir manualmente") {}.buttonStyle(PulseSecondaryButtonStyle())
            HStack(spacing: PulseSpacing.md) {
                Button { } label: { Image(systemName: "mic.fill") }
                    .buttonStyle(PulseIconButtonStyle())
                Button { } label: { Image(systemName: "mic.slash.fill") }
                    .buttonStyle(PulseIconButtonStyle(tone: .danger))
                Button { } label: { Image(systemName: "gearshape.fill") }
                    .buttonStyle(PulseIconButtonStyle(diameter: 40))
            }

            PulseSectionHeader("Estado")
            HStack(spacing: PulseSpacing.xs) {
                PulseStatusPill("Escuchando", tone: .listening, pulses: true)
                PulseStatusPill("Pulse responde", tone: .accent)
            }
            HStack(spacing: PulseSpacing.xs) {
                PulseStatusPill("Reconectando (2)", tone: .warning, pulses: true)
                PulseStatusPill("Lista para llamar", tone: .neutral)
            }
            PulseInlineNotice("No se pudo iniciar el micrófono. Comprueba el permiso.")
            PulseInlineNotice("Conversación continua activa.", tone: .success)

            PulseSectionHeader("Campo y transcript")
            PulseTextField("https://moa.example", text: .constant("https://moa.tail.net"), monospaced: true)
            PulseCaptionBubble(text: "Distribuciones ha terminado los tests.", isOwner: false)
            PulseCaptionBubble(text: "Vale, despliega a staging.", isOwner: true)
        }
        .padding(PulseSpacing.lg)
    }
    .pulseScreenBackground()
}
#endif

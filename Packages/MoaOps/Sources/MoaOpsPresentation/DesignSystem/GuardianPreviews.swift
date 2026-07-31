import SwiftUI

//  Guardian preview components
//
//  Design-system pieces for the future "Guardian mode": Pulse watching
//  sessions in the background and notifying the owner. They are NOT wired
//  to any engine (it doesn't exist yet): they receive data via parameters
//  and are demoed with mocks in the #Previews. When the engine arrives,
//  only the data needs to be hooked up.

// MARK: - Guardian state

/// States that the Guardian engine will expose.
/// // TODO: once the engine exists, map its real enum to these cases
/// // (or replace this enum with the engine's if it lives in MoaOpsCore).
public enum PulseGuardianMode: Hashable, Sendable, CaseIterable {
    case watching
    case listening
    case speaking
    case resolving
    case reconnecting

    public var spanishLabel: String {
        switch self {
        case .watching: "Vigilando"
        case .listening: "Escuchando"
        case .speaking: "Hablando"
        case .resolving: "Resolviendo"
        case .reconnecting: "Reconectando"
        }
    }

    public var tone: PulseTone {
        switch self {
        case .watching: .success
        case .listening: .listening
        case .speaking: .accent
        case .resolving: .warning
        case .reconnecting: .warning
        }
    }

    public var orbMode: PulseOrbMode {
        switch self {
        case .watching: .idle
        case .listening: .listening
        case .speaking: .speaking
        case .resolving: .thinking
        case .reconnecting: .connecting
        }
    }
}

/// Guardian status header: orb + mode + watch summary.
public struct PulseGuardianStatusView: View {
    public var mode: PulseGuardianMode
    public var watchedSessions: Int
    public var pendingAlerts: Int

    public init(mode: PulseGuardianMode, watchedSessions: Int, pendingAlerts: Int) {
        self.mode = mode
        self.watchedSessions = watchedSessions
        self.pendingAlerts = pendingAlerts
    }

    public var body: some View {
        VStack(spacing: PulseSpacing.sm) {
            PulseVoiceOrb(mode: mode.orbMode, diameter: 120)
            PulseStatusPill(mode.spanishLabel, tone: mode.tone, pulses: mode == .reconnecting)
            HStack(spacing: PulseSpacing.md) {
                metric(value: watchedSessions, label: watchedSessions == 1 ? "sesión vigilada" : "sesiones vigiladas")
                if pendingAlerts > 0 {
                    metric(value: pendingAlerts, label: pendingAlerts == 1 ? "aviso pendiente" : "avisos pendientes", tone: .warning)
                }
            }
        }
    }

    private func metric(value: Int, label: String, tone: PulseTone = .neutral) -> some View {
        HStack(spacing: PulseSpacing.xxs) {
            Text("\(value)")
                .font(PulseFont.mono)
                .foregroundStyle(tone == .neutral ? PulseColor.textPrimary : tone.color)
            Text(label)
                .font(PulseFont.footnote)
                .foregroundStyle(PulseColor.textSecondary)
        }
    }
}

// MARK: - Watched session card

/// Summarized state of a session the Guardian watches.
/// // TODO: replace with the engine's real model (moa session id,
/// // agent state, timestamps).
public struct PulseGuardianSessionPreview: Identifiable, Equatable, Sendable {
    public enum Activity: Equatable, Sendable {
        case working
        case waiting
        case finished
        case failed

        public var spanishLabel: String {
            switch self {
            case .working: "Trabajando"
            case .waiting: "Espera respuesta"
            case .finished: "Terminada"
            case .failed: "Con errores"
            }
        }

        public var tone: PulseTone {
            switch self {
            case .working: .accent
            case .waiting: .warning
            case .finished: .success
            case .failed: .danger
            }
        }
    }

    public let id: String
    public let name: String
    public let detail: String
    public let activity: Activity

    public init(id: String, name: String, detail: String, activity: Activity) {
        self.id = id
        self.name = name
        self.detail = detail
        self.activity = activity
    }
}

/// Watched-session row/card: name in mono (it is a technical identifier),
/// latest detail and activity pill.
public struct PulseGuardianSessionRow: View {
    public var session: PulseGuardianSessionPreview

    public init(session: PulseGuardianSessionPreview) { self.session = session }

    public var body: some View {
        HStack(spacing: PulseSpacing.sm) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(session.activity.tone.color)
                .frame(width: 3)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: PulseSpacing.xxs) {
                Text(session.name)
                    .font(PulseFont.monoLarge)
                    .foregroundStyle(PulseColor.textPrimary)
                    .lineLimit(1)
                Text(session.detail)
                    .font(PulseFont.footnote)
                    .foregroundStyle(PulseColor.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: PulseSpacing.xs)
            PulseStatusPill(
                session.activity.spanishLabel,
                tone: session.activity.tone,
                pulses: session.activity == .waiting
            )
        }
        .pulseCard(padding: PulseSpacing.sm)
    }
}

// MARK: - Incoming alert / briefing

/// Alert the Guardian wants to tell the owner about ("Distribuciones terminó").
/// // TODO: real engine model (id, source session, urgency, timestamp).
public struct PulseGuardianAlertPreview: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let tone: PulseTone
    public let timeLabel: String

    public init(id: String, title: String, body: String, tone: PulseTone, timeLabel: String) {
        self.id = id
        self.title = title
        self.body = body
        self.tone = tone
        self.timeLabel = timeLabel
    }
}

/// Incoming alert card, with optional actions (listen/dismiss).
public struct PulseGuardianAlertCard: View {
    public var alert: PulseGuardianAlertPreview
    public var onListen: (() -> Void)?
    public var onDismiss: (() -> Void)?

    public init(
        alert: PulseGuardianAlertPreview,
        onListen: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.alert = alert
        self.onListen = onListen
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: PulseSpacing.xs) {
                    Circle()
                        .fill(alert.tone.color)
                        .frame(width: 8, height: 8)
                        .pulseGlow(alert.tone.color, radius: 6, opacity: 0.7)
                    Text("Aviso")
                        .pulseMicroCaps()
                        .foregroundStyle(alert.tone.color)
                }
                Spacer()
                Text(alert.timeLabel)
                    .font(PulseFont.monoSmall)
                    .foregroundStyle(PulseColor.textTertiary)
            }
            VStack(alignment: .leading, spacing: PulseSpacing.xxs) {
                Text(alert.title)
                    .font(PulseFont.headline)
                    .foregroundStyle(PulseColor.textPrimary)
                Text(alert.body)
                    .font(PulseFont.callout)
                    .foregroundStyle(PulseColor.textSecondary)
            }
            if onListen != nil || onDismiss != nil {
                HStack(spacing: PulseSpacing.xs) {
                    if let onListen {
                        Button {
                            onListen()
                        } label: {
                            Label("Escuchar", systemImage: "waveform")
                                .font(PulseFont.footnote.weight(.semibold))
                        }
                        .buttonStyle(PulseSecondaryButtonStyle(tone: .accent))
                    }
                    if let onDismiss {
                        Button {
                            onDismiss()
                        } label: {
                            Text("Descartar")
                                .font(PulseFont.footnote.weight(.semibold))
                        }
                        .buttonStyle(PulseSecondaryButtonStyle())
                    }
                }
            }
        }
        .pulseCard()
        .overlay(
            RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous)
                .strokeBorder(alert.tone.color.opacity(0.30), lineWidth: 1)
        )
    }
}

// MARK: - Pending counter

/// Compact badge of pending alerts, for headers or tab bars.
public struct PulseGuardianPendingBadge: View {
    public var count: Int

    public init(count: Int) { self.count = count }

    public var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(PulseFont.monoSmall)
                .foregroundStyle(PulseColor.textInverse)
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(Capsule().fill(PulseColor.warning))
                .pulseGlow(PulseColor.warning, radius: 8, opacity: 0.4)
                .accessibilityLabel("\(count) avisos pendientes")
        }
    }
}

// MARK: - Previews (mock data)

#if os(iOS)
private let mockSessions: [PulseGuardianSessionPreview] = [
    .init(id: "1", name: "distribuciones", detail: "go test ./... en curso · 3 min", activity: .working),
    .init(id: "2", name: "pulse-redesign", detail: "Necesita decidir el color de acento", activity: .waiting),
    .init(id: "3", name: "verifier-tools", detail: "Merge limpio, checks en verde", activity: .finished),
    .init(id: "4", name: "queue-rail", detail: "2 tests rotos en pkg/serve", activity: .failed),
]

#Preview("Guardián · pantalla") {
    ScrollView {
        VStack(spacing: PulseSpacing.lg) {
            HStack {
                Text("Guardián")
                    .font(PulseFont.title)
                    .foregroundStyle(PulseColor.textPrimary)
                Spacer()
                PulseGuardianPendingBadge(count: 2)
            }
            PulseGuardianStatusView(mode: .watching, watchedSessions: 4, pendingAlerts: 2)
            PulseGuardianAlertCard(
                alert: .init(
                    id: "a1",
                    title: "Distribuciones terminó",
                    body: "Los tests pasan y la rama está lista para revisar.",
                    tone: .success,
                    timeLabel: "hace 2 min"
                ),
                onListen: {},
                onDismiss: {}
            )
            VStack(alignment: .leading, spacing: PulseSpacing.xs) {
                PulseSectionHeader("Sesiones vigiladas")
                ForEach(mockSessions) { session in
                    PulseGuardianSessionRow(session: session)
                }
            }
        }
        .padding(PulseSpacing.lg)
    }
    .pulseScreenBackground()
}

#Preview("Guardián · estados") {
    ScrollView {
        VStack(spacing: PulseSpacing.xl) {
            ForEach(PulseGuardianMode.allCases, id: \.self) { mode in
                PulseGuardianStatusView(mode: mode, watchedSessions: 3, pendingAlerts: mode == .watching ? 0 : 1)
            }
        }
        .padding(PulseSpacing.lg)
    }
    .pulseScreenBackground()
}
#endif

// Widget Extension "PulseWidgetExtension" — bundle com.ealeixandre.moa.pulse.LiveActivity.
// La "cara" del Guardián en isla dinámica / pantalla de bloqueo. No mantiene la app viva.
import ActivityKit
import AppIntents
import MoaOpsCore
import SwiftUI
import WidgetKit

struct PulseWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PulseGuardianActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color(red: 1.0, green: 0.43, blue: 0.25))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pulse · \(context.state.stateLabel)")
                        .font(.headline)
                        .lineLimit(1)
                    Text(summary(for: context.state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                controls(for: context.state)
            }
            .padding(.horizontal, 4)
            .activityBackgroundTint(Color(red: 0.043, green: 0.051, blue: 0.063))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "waveform.circle.fill")
                        .foregroundStyle(Color(red: 1.0, green: 0.43, blue: 0.25))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.sessionCount) sesiones")
                        .font(.caption.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.stateLabel)
                            .font(.headline)
                        Text(summary(for: context.state))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        HStack(spacing: 8) { controls(for: context.state) }
                    }
                }
            } compactLeading: {
                Image(systemName: "waveform")
                    .foregroundStyle(Color(red: 1.0, green: 0.43, blue: 0.25))
            } compactTrailing: {
                Text(context.state.pendingCount > 0 ? "!\(context.state.pendingCount)" : "●")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(context.state.pendingCount > 0 ? .yellow : .green)
            } minimal: {
                Image(systemName: context.state.pendingCount > 0 ? "exclamationmark.circle.fill" : "waveform")
                    .foregroundStyle(context.state.pendingCount > 0 ? .yellow : Color(red: 1.0, green: 0.43, blue: 0.25))
            }
            .widgetURL(URL(string: "moapulse://guardian"))
            .keylineTint(Color(red: 1.0, green: 0.43, blue: 0.25))
        }
    }

    /// Lock-screen controls: a mic mute toggle (only while running) and the
    /// single start/stop toggle. The intents run in the app process without
    /// unlocking the phone.
    @ViewBuilder
    private func controls(for state: PulseGuardianActivityAttributes.ContentState) -> some View {
        if #available(iOS 17.0, *) {
            HStack(spacing: 8) {
                if state.isRunning {
                    Button(intent: PulseToggleMicIntent()) {
                        Image(systemName: state.micMuted ? "mic.slash.fill" : "mic.fill")
                    }
                    .tint(state.micMuted ? .red : .white)
                    .accessibilityLabel(state.micMuted ? "Reanudar micrófono" : "Silenciar micrófono")
                }
                Button(intent: PulseToggleGuardianIntent()) {
                    Image(systemName: state.isRunning ? "stop.fill" : "play.fill")
                }
                .tint(state.isRunning ? .red : Color(red: 1.0, green: 0.43, blue: 0.25))
                .accessibilityLabel(state.isRunning ? "Detener Guardián" : "Activar Guardián")
            }
            .buttonStyle(.bordered)
            .font(.caption)
        }
    }

    private func summary(for state: PulseGuardianActivityAttributes.ContentState) -> String {
        if !state.isRunning { return "Guardián detenido" }
        if state.micMuted { return "Micrófono silenciado" }
        if let event = state.lastEventLine, !event.isEmpty { return event }
        if state.pendingCount > 0 { return "\(state.pendingCount) decisiones pendientes" }
        return "\(state.sessionCount) sesiones vigiladas"
    }
}

@main
struct PulseWidgetBundle: WidgetBundle {
    var body: some Widget {
        PulseWidgetLiveActivity()
    }
}

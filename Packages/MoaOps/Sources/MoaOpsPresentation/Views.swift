import SwiftUI
import MoaOpsCore

public struct MoaOpsRootView: View {
    @ObservedObject private var model: MoaOpsAppModel
    @State private var showingConfiguration = false
    @State private var selectedCard: PulseCard?

    public init(model: MoaOpsAppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let pulse = model.pulse {
                        PulseHomeView(
                            pulse: pulse,
                            sections: model.pulseSections,
                            historyUnavailable: model.historyUnavailable,
                            onSelect: { selectedCard = $0 }
                        )
                    } else {
                        PulseWelcomeView(model: model)
                    }
                    if let message = model.userMessage {
                        SafeMessageView(message: message, dismiss: model.clearMessage)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 28)
            }
            .background(Color.secondary.opacity(0.08))
            .navigationTitle("Moa Pulse")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button("Servidor", systemImage: "gearshape") { showingConfiguration = true }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Actualizar", systemImage: "arrow.clockwise") {
                        Task { await model.refresh() }
                    }
                    .disabled(model.isLoading || model.isTestingConnection)
                }
            }
            .sheet(isPresented: $showingConfiguration) {
                NavigationStack {
                    ServerConfigurationView(model: model)
                        .padding()
                        .navigationTitle("Servidor de Moa")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Listo") { showingConfiguration = false }
                            }
                        }
                }
                .presentationDetents([.medium])
            }
            .sheet(item: $selectedCard) { card in
                PulseDetailSheet(card: card, model: model)
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

private struct PulseWelcomeView: View {
    @ObservedObject var model: MoaOpsAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "waveform.path.ecg.rectangle.fill")
                .font(.system(size: 46))
                .foregroundStyle(.tint)
                .padding(.top, 28)
            Text("Tu día con Moa, de un vistazo.")
                .font(.largeTitle.bold())
            Text("Pulse prioriza lo que necesita de ti y conserva solo hechos seguros del servidor.")
                .font(.body)
                .foregroundStyle(.secondary)
            ServerConfigurationView(model: model)
        }
    }
}

public struct ServerConfigurationView: View {
    @ObservedObject private var model: MoaOpsAppModel

    public init(model: MoaOpsAppModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Conectar Pulse")
                .font(.headline)
            Text("Introduce la dirección de tu servidor Moa. La app no guarda credenciales.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("https://moa.example", text: $model.serverURLText)
                .textFieldStyle(.roundedBorder)
#if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
#endif
                .autocorrectionDisabled()
            Button(model.isTestingConnection ? "Conectando…" : "Abrir Pulse") {
                Task { await model.testConnection() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isTestingConnection || model.serverURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct PulseHomeView: View {
    let pulse: OpsPulse
    let sections: [PulseSection]
    let historyUnavailable: Bool
    let onSelect: (PulseCard) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PulseHero(summary: pulse.summary)
            if historyUnavailable {
                Label("El historial anterior ya no está disponible; se muestra el estado actual.", systemImage: "clock.arrow.circlepath")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if pulse.changes.requested && pulse.changes.truncated {
                Label("Se muestran los cambios retenidos más recientes; puede haber más.", systemImage: "rectangle.3.group.bubble")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if sections.isEmpty {
                AllClearView()
            } else {
                ForEach(sections) { section in
                    PulseSectionView(section: section, onSelect: onSelect)
                }
            }
            Text("Actualizado ") + Text(pulse.generatedAt, style: .relative)
        }
    }
}

private struct PulseHero: View {
    let summary: OpsPulseSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if summary.needsAttention > 0 {
                Text("Ahora")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(heroLine)
                    .font(.title.bold())
            } else {
                Label("Todo en orden", systemImage: "checkmark.circle.fill")
                    .font(.title.bold())
                    .foregroundStyle(.green)
                Text(summary.inProgress > 0 ? "\(summary.inProgress) en marcha · \(summary.onTrack) en buen camino" : "No hay nada que requiera tu atención.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            LinearGradient(colors: [.indigo.opacity(0.18), .teal.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
    }

    private var heroLine: String {
        let attention = "\(summary.needsAttention) \(summary.needsAttention == 1 ? "necesita" : "necesitan") de ti"
        guard summary.inProgress > 0 else { return attention }
        return "\(attention) · \(summary.inProgress) en marcha"
    }
}

private struct AllClearView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.title)
                .foregroundStyle(.teal)
            Text("Nada urgente por ahora")
                .font(.headline)
            Text("Pulse te avisará aquí cuando haya una decisión o una comprobación que revisar.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct PulseSectionView: View {
    let section: PulseSection
    let onSelect: (PulseCard) -> Void
    @State private var expanded: Bool

    init(section: PulseSection, onSelect: @escaping (PulseCard) -> Void) {
        self.section = section
        self.onSelect = onSelect
        _expanded = State(initialValue: section.kind == .needsAttention || section.kind == .changes)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(spacing: 10) {
                ForEach(section.cards) { card in
                    Button { onSelect(card) } label: {
                        PulseCardView(card: card)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Text(section.kind.title)
                    .font(.headline)
                Spacer()
                Text("\(section.cards.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PulseCardView: View {
    let card: PulseCard

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.category)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tint)
                    Text(card.title)
                        .font(.headline)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            Text(card.categoryDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(card.lifecycle)
                Text("·")
                Text(card.activity)
                if let verification = card.verification {
                    Text("·")
                    Text(verification)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Label(card.freshness, systemImage: "clock")
                Spacer()
                Text(card.project)
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct PulseDetailSheet: View {
    let card: PulseCard
    @ObservedObject var model: MoaOpsAppModel
    @State private var showingComposer = false

    var body: some View {
        NavigationStack {
            List {
                Section("Situación") {
                    LabeledContent("Categoría", value: card.category)
                    LabeledContent("Ciclo", value: card.lifecycle)
                    LabeledContent("Actividad", value: card.activity)
                    if let verification = card.verification {
                        LabeledContent("Verificación", value: verification)
                    }
                    LabeledContent("Actualidad", value: card.freshness)
                    if let observedAt = card.observedAt {
                        LabeledContent("Observado", value: observedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                Section("Hechos y evidencia") {
                    if card.facts.isEmpty {
                        Text("No hay evidencia adicional para mostrar.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(card.facts) { fact in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(fact.title)
                            HStack {
                                Text(fact.provenance)
                                if let at = fact.at {
                                    Text("·")
                                    Text(at, style: .relative)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                if let target = card.instructionTarget {
                    Section {
                        Button("Dar una instrucción a \(target.title)") {
                            model.beginInstruction(for: card)
                            showingComposer = true
                        }
                        .buttonStyle(.borderedProminent)
                    } footer: {
                        Text("La entrega de una instrucción no confirma que el trabajo esté terminado.")
                    }
                }
            }
            .navigationTitle(card.title)
            .sheet(isPresented: $showingComposer, onDismiss: model.closeInstruction) {
                DirectedInstructionSheet(model: model)
                    .presentationDetents([.medium])
            }
        }
    }
}

private struct DirectedInstructionSheet: View {
    @ObservedObject var model: MoaOpsAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if let target = model.activeInstructionTarget {
                    Text("Enviar a")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(target.title)
                        .font(.title3.bold())
                    Text(target.project)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("La instrucción se enviará solo a esta sesión resuelta por Pulse.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                TextEditor(text: $text)
                    .padding(8)
                    .frame(minHeight: 112)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel("Instrucción")
                if let receipt = model.instructionReceipt {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(receipt.message, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("La entrega no es una confirmación de finalización. Revisa Pulse para ver el progreso.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(model.isSendingInstruction ? "Enviando…" : "Enviar instrucción") {
                    Task {
                        await model.submitInstruction(text: text)
                        if model.instructionReceipt != nil { text = "" }
                    }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(model.isSendingInstruction || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            .navigationTitle("Instrucción dirigida")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
    }
}

private struct SafeMessageView: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
            Spacer()
            Button("Cerrar", action: dismiss)
                .font(.caption)
        }
        .font(.footnote)
        .foregroundStyle(.orange)
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

import SwiftUI
import MoaOpsCore

public struct MoaCompanionRootView: View {
    @ObservedObject private var model: MoaCompanionAppModel
    @State private var showingConfiguration = false

    public init(model: MoaCompanionAppModel) { self.model = model }

    public var body: some View {
        TabView {
            NavigationStack {
                MoaHomeView(model: model)
                    .navigationTitle("Moa")
                    .toolbar { settingsToolbar }
            }
            .tabItem { Label("Moa", systemImage: "sparkles") }

            NavigationStack {
                ConversationsView(model: model)
                    .navigationTitle("Conversaciones")
                    .toolbar { settingsToolbar }
            }
            .tabItem { Label("Conversaciones", systemImage: "bubble.left.and.bubble.right") }

            NavigationStack {
                PulseStatusView(model: model)
                    .navigationTitle("Estado")
                    .toolbar { settingsToolbar }
            }
            .tabItem { Label("Estado", systemImage: "waveform.path.ecg") }
        }
        .sheet(isPresented: $showingConfiguration) {
            NavigationStack {
                CompanionConfigurationView(model: model)
                    .padding()
                    .navigationTitle("Servidor de Moa")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { showingConfiguration = false } } }
            }
            .presentationDetents([.medium])
        }
    }

    @ToolbarContentBuilder private var settingsToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) { Button("Servidor", systemImage: "gearshape") { showingConfiguration = true } }
        ToolbarItem(placement: .primaryAction) { Button("Actualizar", systemImage: "arrow.clockwise") { Task { await model.refreshSessions(); await model.refreshPulse() } }.disabled(model.isLoading) }
    }
}

public struct CompanionConfigurationView: View {
    @ObservedObject var model: MoaCompanionAppModel

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Conectar Moa").font(.headline)
            Text("El token solo crea la sesión de cookie y permanece en memoria mientras la app está abierta.").font(.footnote).foregroundStyle(.secondary)
            TextField("https://moa.example", text: $model.serverURLText).textFieldStyle(.roundedBorder).autocorrectionDisabled()
#if os(iOS)
                .textInputAutocapitalization(.never).keyboardType(.URL)
#endif
            SecureField("Token de acceso (opcional)", text: $model.accessToken).textFieldStyle(.roundedBorder).autocorrectionDisabled()
#if os(iOS)
                .textInputAutocapitalization(.never)
#endif
            Button(model.isLoading ? "Conectando…" : "Abrir Moa") { Task { await model.connect() } }
                .buttonStyle(.borderedProminent).disabled(model.isLoading || model.serverURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let message = model.userMessage { CompanionMessageView(message: message) }
        }
        .padding().background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct MoaHomeView: View {
    @ObservedObject var model: MoaCompanionAppModel
    @State private var actionItem: ConversationBriefingItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if model.sessions.isEmpty {
                    welcome
                } else {
                    selection
                    Button(model.isGeneratingBriefing ? "Preparando…" : "Ponme al día") { Task { await model.generateBriefing() } }
                        .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                        .disabled(model.selectedSessionIDs.isEmpty || model.isGeneratingBriefing)
                    if let briefing = model.briefing { briefingView(briefing) }
                }
                if let message = model.userMessage { CompanionMessageView(message: message) }
            }
            .padding()
        }
        .background(Color.secondary.opacity(0.08))
        .sheet(item: $actionItem) { item in
            SuggestedActionSheet(model: model, item: item).presentationDetents([.medium, .large])
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "sparkles").font(.system(size: 46)).foregroundStyle(.tint)
            Text("Conversaciones y contexto, en un solo lugar.").font(.largeTitle.bold())
            Text("Elige hasta tres conversaciones y pide un briefing breve. Los hechos operativos verificados se separan del resumen de conversación.").foregroundStyle(.secondary)
            CompanionConfigurationView(model: model)
        }.padding(.top, 30)
    }

    private var selection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Para este briefing").font(.headline)
            Text("Selecciona hasta 3 conversaciones. Priorizamos las activas y recientes.").font(.footnote).foregroundStyle(.secondary)
            ForEach(model.sessions.prefix(8)) { session in
                Button { model.toggleSelection(session) } label: {
                    HStack {
                        Image(systemName: model.selectedSessionIDs.contains(session.id) ? "checkmark.circle.fill" : "circle")
                        VStack(alignment: .leading) { Text(session.title).lineLimit(1); Text(session.state).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if session.isLive { Text("ACTIVA").font(.caption2.bold()).foregroundStyle(.green) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }.buttonStyle(.plain)
            }
            Text("\(model.selectedSessionIDs.count)/3 seleccionadas").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func briefingView(_ briefing: ConversationBriefing) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Briefing").font(.title2.bold())
            if briefing.mode == "template" {
                Label("Plantilla segura: no se generó un resumen de conversación.", systemImage: "doc.text").font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Resumen de conversación · síntesis del servidor (30–60 s)").font(.footnote).foregroundStyle(.secondary)
            }
            if !briefing.verifiedOps.isEmpty {
                Text("Moa verificó").font(.headline)
                ForEach(briefing.verifiedOps.filter(CompanionMapper.isVerified)) { fact in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fact.text)
                        Text(CompanionMapper.provenanceLabel(fact.provenance) + " · " + fact.sourceID).font(.caption).foregroundStyle(.secondary)
                    }.padding(12).background(.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            if !briefing.items.isEmpty {
                Text("Resumen de conversación").font(.headline)
                ForEach(briefing.items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.text)
                        Text(CompanionMapper.provenanceLabel(item.provenance)).font(.caption).foregroundStyle(.secondary)
                        Text("Fuentes: " + item.sourceIDs.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary)
                        if CompanionMapper.actionProposal(item: item, sessions: model.sessions) != nil {
                            Button("Preparar instrucción dirigida") { actionItem = item }.buttonStyle(.bordered)
                        }
                    }.padding(12).background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            } else if briefing.verifiedOps.isEmpty {
                Text("Aún no hay material suficiente para un briefing.").foregroundStyle(.secondary)
            }
        }
    }
}

private struct ConversationsView: View {
    @ObservedObject var model: MoaCompanionAppModel
    var body: some View {
        List {
            if model.sessions.isEmpty { Text("Conecta con Moa para ver conversaciones autorizadas.").foregroundStyle(.secondary) }
            ForEach(model.sessions) { session in
                NavigationLink { ConversationDetailView(model: model, session: session) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.title).lineLimit(1)
                        HStack { Text(session.state); Text("·"); Text(session.updated, style: .relative) }.font(.caption).foregroundStyle(.secondary)
                        if session.isLive { Text("ACTIVA · superposición en directo").font(.caption2).foregroundStyle(.green) }
                        else { Text("Guardada · solo lectura; no se reanuda automáticamente").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            }
        }.task { if model.sessions.isEmpty { await model.connect() } }
    }
}

private struct ConversationDetailView: View {
    @ObservedObject var model: MoaCompanionAppModel
    let session: CompanionSession

    var body: some View {
        VStack(spacing: 0) {
            if model.activeConversation?.id == session.id {
                if model.conversationWasReset { Label("La rama cambió o el cursor caducó; se recargó el historial.", systemImage: "arrow.clockwise").font(.footnote).foregroundStyle(.orange).padding(.horizontal) }
                if session.isLive && model.liveHistoryIsBounded { Label("Directo: el inicio es una cola limitada; el historial completo se carga por páginas.", systemImage: "dot.radiowaves.left.and.right").font(.footnote).foregroundStyle(.secondary).padding(.horizontal) }
                List {
                    ForEach(model.conversationMessages) { message in MessageRow(message: message) }
                    if !model.livePartialText.isEmpty { MessageRow(message: .init(id: "partial", role: "assistant", text: model.livePartialText)) }
                    if model.conversationHasMore { Button(model.conversationIsLoading ? "Cargando…" : "Cargar más") { Task { await model.loadMoreConversation() } }.disabled(model.conversationIsLoading) }
                }
                if session.isLive { composer }
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.openConversation(session) }
        .onDisappear { Task { await model.closeConversation() } }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let receipt = model.chatReceipt { Text(receipt.action == .send ? "Mensaje aceptado por Moa." : "Mensaje dirigido a una ejecución activa.").font(.caption).foregroundStyle(.secondary) }
            HStack(alignment: .bottom) {
                TextField("Escribe a Moa", text: $model.chatText, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4)
                Button(model.isSendingChat ? "…" : "Enviar") { Task { await model.sendChat() } }.buttonStyle(.borderedProminent).disabled(model.isSendingChat || model.chatText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding().background(.bar)
    }
}

private struct MessageRow: View {
    let message: ConversationMessage
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(message.role == "user" ? "Tú" : "Moa").font(.caption.bold()).foregroundStyle(message.role == "user" ? .tint : .secondary)
            Text(message.text)
            if message.truncated || message.omitted { Text(message.truncated ? "Texto recortado por el servidor." : "Parte no textual omitida por el servidor.").font(.caption2).foregroundStyle(.secondary) }
        }.padding(.vertical, 5)
    }
}

private struct SuggestedActionSheet: View {
    @ObservedObject var model: MoaCompanionAppModel
    let item: ConversationBriefingItem
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if let proposal = model.actionProposal {
                    Text("Confirmar instrucción dirigida").font(.title3.bold())
                    Text("Destino exacto").font(.caption.bold()).foregroundStyle(.secondary)
                    Text(proposal.target.title).font(.headline)
                    Text("ID autorizado: \(proposal.target.id)").font(.caption).foregroundStyle(.secondary)
                    Text("Esta acción es distinta de enviar un chat. Confirma el texto exacto antes de entregarla.").font(.footnote).foregroundStyle(.secondary)
                    TextEditor(text: $model.actionText).frame(minHeight: 120).padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    if let receipt = model.actionReceipt { Label(receipt.message, systemImage: "checkmark.circle.fill").foregroundStyle(.green); Text(receipt.completionNotice).font(.footnote).foregroundStyle(.secondary) }
                    Button(model.isSendingAction ? "Enviando…" : "Confirmar y entregar") { Task { await model.submitSuggestedAction() } }.buttonStyle(.borderedProminent).disabled(model.isSendingAction || model.actionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else { Text("El destino autorizado ya no está disponible.") }
                Spacer()
            }.padding().navigationTitle("Acción propuesta").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { model.cancelSuggestedAction(); dismiss() } } }
        }.onAppear { model.beginSuggestedAction(item) }
    }
}

private struct PulseStatusView: View {
    @ObservedObject var model: MoaCompanionAppModel
    var body: some View {
        List {
            if let pulse = model.pulse {
                Section("Pulse") {
                    LabeledContent("Necesita atención", value: "\(pulse.summary.needsAttention)")
                    LabeledContent("En marcha", value: "\(pulse.summary.inProgress)")
                    LabeledContent("Sin observación reciente", value: "\(pulse.summary.staleWork)")
                }
                ForEach(PresentationMapper.pulseSections(for: pulse)) { section in
                    Section(section.kind.title) { ForEach(section.cards) { card in Text(card.title).font(.headline); Text(card.categoryDetail).font(.caption).foregroundStyle(.secondary) } }
                }
            } else { Text("Pulse es un estado secundario. Actualiza tras conectar para ver el estado operativo.").foregroundStyle(.secondary) }
        }
    }
}

private struct CompanionMessageView: View {
    let message: String
    var body: some View { Label(message, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange).padding(10).background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10)) }
}

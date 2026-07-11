import Foundation
import SwiftUI
import MoaOpsCore

public struct BriefingActionProposal: Equatable, Sendable, Identifiable {
    public let target: CompanionSession
    public let sourceIDs: [String]
    public let summaryText: String
    public var id: String { target.id + ":" + sourceIDs.joined(separator: ":") }
}

public enum CompanionMapper {
    public static func defaultSelection(in sessions: [CompanionSession]) -> [String] {
        Array(sessions.sorted {
            if $0.isLive != $1.isLive { return $0.isLive && !$1.isLive }
            return $0.updated > $1.updated
        }.prefix(3).map(\.id))
    }

    /// Toggling is bounded and id-based: the app never resolves a title or other
    /// free text into a session target.
    public static func toggling(sessionID: String, selected: [String], maximum: Int = 3) -> [String] {
        if let index = selected.firstIndex(of: sessionID) {
            var next = selected
            next.remove(at: index)
            return next
        }
        guard selected.count < maximum else { return selected }
        return selected + [sessionID]
    }

    public static func isVerified(_ fact: ConversationBriefingFact) -> Bool {
        fact.provenance == "verified_ops"
    }

    public static func provenanceLabel(_ value: String) -> String {
        switch value {
        case "verified_ops": return "Moa verificó · Ops"
        case "user_provided": return "Resumen de conversación · aportado por ti"
        case "agent_reported": return "Resumen de conversación · informado por Moa"
        default: return "Resumen de conversación · procedencia no verificada"
        }
    }

    public static func actionProposal(item: ConversationBriefingItem, sessions: [CompanionSession]) -> BriefingActionProposal? {
        guard let action = item.suggestedAction,
              action.kind == "directed_instruction",
              let target = sessions.first(where: { $0.id == action.targetID }) else { return nil }
        return .init(target: target, sourceIDs: item.sourceIDs, summaryText: item.text)
    }
}

@MainActor
public final class MoaCompanionAppModel: ObservableObject {
    public typealias ServiceFactory = @Sendable (URL, String?) throws -> any MoaCompanionPresentationService

    @Published public var serverURLText: String
    /// This is process-only input. Neither this model nor its service writes it
    /// to defaults, logs, URLs, or the transcript.
    @Published public var accessToken = ""
    @Published public private(set) var sessions: [CompanionSession] = []
    @Published public private(set) var selectedSessionIDs: [String] = []
    @Published public private(set) var briefing: ConversationBriefing?
    @Published public private(set) var isLoading = false
    @Published public private(set) var isGeneratingBriefing = false
    @Published public private(set) var userMessage: String?
    @Published public private(set) var activeConversation: CompanionSession?
    @Published public private(set) var conversationMessages: [ConversationMessage] = []
    @Published public private(set) var conversationHasMore = false
    @Published public private(set) var conversationIsLoading = false
    @Published public private(set) var conversationWasReset = false
    @Published public private(set) var livePartialText = ""
    @Published public private(set) var liveState = ""
    @Published public private(set) var liveHistoryIsBounded = false
    @Published public var chatText = ""
    @Published public private(set) var chatReceipt: ConversationSendResponse?
    @Published public private(set) var isSendingChat = false
    @Published public private(set) var actionProposal: BriefingActionProposal?
    @Published public var actionText = "" {
        didSet {
            if pendingActionInstruction?.text != actionText.trimmingCharacters(in: .whitespacesAndNewlines) { pendingActionInstruction = nil }
        }
    }
    @Published public private(set) var actionReceipt: OpsInstructionReceipt?
    @Published public private(set) var isSendingAction = false
    @Published public private(set) var pulse: OpsPulse?

    private let serviceFactory: ServiceFactory
    private var service: (any MoaCompanionPresentationService)?
    private var conversationCursor: String?
    private var conversationBranch: ConversationBranch?
    private var liveTask: Task<Void, Never>?
    private var pendingActionInstruction: OpsInstructionRequest?

    public init(serverURLText: String = "", serviceFactory: @escaping ServiceFactory = { baseURL, token in
        let auth: (any MoaOpsAuthenticationBootstrap)?
        if let token {
            auth = CookieTokenBootstrap(token: token)
        } else {
            auth = nil
        }
        return try MoaCompanionLiveService(baseURL: baseURL, authentication: auth)
    }) {
        self.serverURLText = serverURLText
        self.serviceFactory = serviceFactory
    }

    deinit { liveTask?.cancel() }

    public func connect() async {
        guard let configuration = validConfiguration() else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let newService = try serviceFactory(configuration.baseURL, nonEmptyAccessToken)
            let loaded = try await newService.loadSessions()
            service = newService
            sessions = sorted(loaded)
            selectedSessionIDs = CompanionMapper.defaultSelection(in: sessions)
            briefing = nil
            userMessage = nil
            await refreshPulse()
        } catch {
            userMessage = message(for: error)
        }
    }

    public func refreshSessions() async {
        guard let service else { await connect(); return }
        isLoading = true
        defer { isLoading = false }
        do {
            sessions = sorted(try await service.loadSessions())
            selectedSessionIDs = selectedSessionIDs.filter { id in sessions.contains(where: { $0.id == id }) }
            if selectedSessionIDs.isEmpty { selectedSessionIDs = CompanionMapper.defaultSelection(in: sessions) }
            userMessage = nil
        } catch { userMessage = message(for: error) }
    }

    public func toggleSelection(_ session: CompanionSession) {
        selectedSessionIDs = CompanionMapper.toggling(sessionID: session.id, selected: selectedSessionIDs)
        briefing = nil
    }

    public func generateBriefing() async {
        guard let service else { userMessage = "Conecta con Moa antes de pedir el briefing."; return }
        guard !selectedSessionIDs.isEmpty, selectedSessionIDs.count <= 3 else {
            userMessage = "Selecciona entre una y tres conversaciones."; return
        }
        isGeneratingBriefing = true
        defer { isGeneratingBriefing = false }
        do {
            briefing = try await service.loadBriefing(sessionIDs: selectedSessionIDs)
            userMessage = nil
        } catch { userMessage = message(for: error) }
    }

    public func openConversation(_ session: CompanionSession) async {
        await closeConversation()
        activeConversation = session
        conversationWasReset = false
        conversationMessages = []
        conversationCursor = nil
        conversationBranch = nil
        await loadConversation(cursor: nil, replacing: true)
        guard session.isLive, let service else { return }
        await service.startConversationUpdates(sessionID: session.id)
        let stream = await service.conversationUpdates()
        liveTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.applyLive(event)
            }
        }
    }

    public func loadMoreConversation() async {
        guard let conversationCursor else { return }
        await loadConversation(cursor: conversationCursor, replacing: false)
    }

    private func loadConversation(cursor: String?, replacing: Bool) async {
        guard let service, let conversation = activeConversation else { return }
        conversationIsLoading = true
        defer { conversationIsLoading = false }
        do {
            let page = try await service.loadConversation(sessionID: conversation.id, limit: 50, cursor: cursor)
            guard page.sessionID == conversation.id else { throw MoaOpsClientError.decoding }
            if !replacing, let branch = conversationBranch, branch != page.branch {
                // A branch transition invalidates an assembled page set. Start a
                // new authoritative history rather than combining two branches.
                conversationWasReset = true
                await loadConversation(cursor: nil, replacing: true)
                return
            }
            conversationBranch = page.branch
            conversationMessages = replacing ? page.messages : merge(page.messages, into: conversationMessages)
            conversationCursor = page.nextCursor
            conversationHasMore = page.hasMore && page.nextCursor != nil
            userMessage = nil
        } catch let error as MoaOpsClientError where error == .conversationResetRequired && cursor != nil {
            conversationWasReset = true
            await loadConversation(cursor: nil, replacing: true)
        } catch { userMessage = message(for: error) }
    }

    private func applyLive(_ event: ConversationLiveEvent) {
        var state = ConversationLiveState(messages: conversationMessages, state: liveState, partialText: livePartialText, historyIsBounded: liveHistoryIsBounded)
        state.apply(event)
        conversationMessages = state.messages
        liveState = state.state
        livePartialText = state.partialText
        liveHistoryIsBounded = state.historyIsBounded
    }

    public func sendChat() async {
        guard let service, let conversation = activeConversation else { return }
        let text = chatText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4_000 else { userMessage = "Escribe un mensaje de hasta 4.000 caracteres."; return }
        isSendingChat = true
        chatReceipt = nil
        defer { isSendingChat = false }
        do {
            // The accepted response is a receipt, not a locally invented chat
            // bubble. REST reload/WS remain the only transcript authority.
            chatReceipt = try await service.sendConversation(sessionID: conversation.id, text: text)
            chatText = ""
            userMessage = nil
        } catch { userMessage = message(for: error) }
    }

    public func beginSuggestedAction(_ item: ConversationBriefingItem) {
        actionProposal = CompanionMapper.actionProposal(item: item, sessions: sessions)
        actionText = ""
        actionReceipt = nil
        pendingActionInstruction = nil
        if actionProposal == nil { userMessage = "La acción propuesta ya no tiene un destino autorizado disponible." }
    }

    public func cancelSuggestedAction() {
        actionProposal = nil
        actionText = ""
        actionReceipt = nil
        pendingActionInstruction = nil
    }

    public func submitSuggestedAction() async {
        guard let service, let proposal = actionProposal else { return }
        let text = actionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4_000 else { userMessage = "Confirma el texto de la instrucción (máximo 4.000 caracteres)."; return }
        let instruction: OpsInstructionRequest
        if let pendingActionInstruction, pendingActionInstruction.target == proposal.target.id, pendingActionInstruction.text == text {
            instruction = pendingActionInstruction
        } else {
            instruction = .init(target: proposal.target.id, text: text)
            pendingActionInstruction = instruction
        }
        isSendingAction = true
        defer { isSendingAction = false }
        do {
            let response = try await service.submitInstruction(instruction)
            actionReceipt = .init(title: proposal.target.title, action: response.action)
            pendingActionInstruction = nil
            actionText = ""
            userMessage = nil
        } catch { userMessage = message(for: error) }
    }

    public func refreshPulse() async {
        guard let service else { return }
        do { pulse = try await service.loadPulse(cursor: nil) } catch { /* Estado is optional secondary surface. */ }
    }

    public func closeConversation() async {
        liveTask?.cancel()
        liveTask = nil
        if let service { await service.stopConversationUpdates() }
        livePartialText = ""
        liveHistoryIsBounded = false
    }

    public func disconnect() {
        let current = service
        service = nil
        liveTask?.cancel()
        sessions = []
        selectedSessionIDs = []
        activeConversation = nil
        conversationMessages = []
        briefing = nil
        pulse = nil
        accessToken = ""
        Task { await current?.invalidate() }
    }

    private func sorted(_ sessions: [CompanionSession]) -> [CompanionSession] {
        sessions.sorted { $0.updated > $1.updated }
    }

    private var nonEmptyAccessToken: String? {
        let value = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func validConfiguration() -> ServerConfiguration? {
        do { return try ServerConfiguration(urlText: serverURLText) }
        catch { userMessage = "Introduce una dirección http:// o https:// válida."; return nil }
    }

    private func merge(_ incoming: [ConversationMessage], into current: [ConversationMessage]) -> [ConversationMessage] {
        var result = current
        var positions = Dictionary(uniqueKeysWithValues: current.enumerated().map { ($0.element.id, $0.offset) })
        for message in incoming {
            if let index = positions[message.id] { result[index] = message }
            else { positions[message.id] = result.count; result.append(message) }
        }
        return result
    }

    private func message(for error: Error) -> String {
        guard let error = error as? MoaOpsClientError else { return "No se pudo contactar con Moa. Comprueba la conexión e inténtalo de nuevo." }
        switch error {
        case .authentication: return "El servidor no aceptó esta conexión."
        case .conversationResetRequired: return "La conversación cambió; se cargó de nuevo desde el principio."
        case let .httpStatus(code, _):
            switch code {
            case 401, 403: return "No tienes acceso a esta conversación."
            case 404: return "Este servidor no ofrece esta función de Moa."
            case 429: return "Moa está limitando solicitudes. Prueba dentro de un momento."
            default: return "Moa no pudo completar la solicitud. Prueba más tarde."
            }
        case .decoding: return "El servidor envió una respuesta no compatible."
        default: return "No se pudo contactar con Moa. Comprueba la conexión e inténtalo de nuevo."
        }
    }
}

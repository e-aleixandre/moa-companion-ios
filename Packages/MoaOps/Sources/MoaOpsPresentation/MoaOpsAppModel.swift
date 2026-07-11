import Foundation
import SwiftUI
import MoaOpsCore

@MainActor
public final class MoaOpsAppModel: ObservableObject {
    public typealias ServiceFactory = @Sendable (URL, String?) throws -> any MoaOpsPresentationService

    @Published public var serverURLText: String
    /// An optional Serve token held only for this process. It is never written
    /// to UserDefaults, a URL, a log, or an instruction request.
    @Published public var accessToken = ""
    @Published public private(set) var pulse: OpsPulse?
    @Published public private(set) var isLoading = false
    @Published public private(set) var isTestingConnection = false
    @Published public private(set) var userMessage: String?
    @Published public private(set) var historyUnavailable = false
    @Published public private(set) var lastSuccessfulRefreshAt: Date?
    @Published public private(set) var activeInstructionTarget: PulseInstructionTarget?
    @Published public var instructionText = "" {
        didSet {
            if let pendingInstruction,
               pendingInstruction.text != instructionText.trimmingCharacters(in: .whitespacesAndNewlines) {
                self.pendingInstruction = nil
            }
        }
    }
    @Published public private(set) var instructionReceipt: OpsInstructionReceipt?
    @Published public private(set) var isSendingInstruction = false
    @Published public var askText = ""
    @Published public private(set) var askHistory: [OpsAskHistoryEntry] = []
    @Published public private(set) var askFeedback: OpsAskFeedback?
    @Published public private(set) var isAsking = false

    private let serviceFactory: ServiceFactory
    private let cursorStore: PulseCursorStore
    private var service: (any MoaOpsPresentationService)?
    private var pendingInstruction: OpsInstructionRequest?

    public init(
        serverURLText: String = "",
        cursorStore: PulseCursorStore = UserDefaultsPulseCursorStore(),
        serviceFactory: @escaping ServiceFactory = { baseURL, accessToken in
            let authentication: (any MoaOpsAuthenticationBootstrap)?
            if let accessToken {
                authentication = CookieTokenBootstrap(token: accessToken)
            } else {
                authentication = nil
            }
            return try MoaOpsLiveService(baseURL: baseURL, authentication: authentication)
        }
    ) {
        self.serverURLText = serverURLText
        self.cursorStore = cursorStore
        self.serviceFactory = serviceFactory
    }

    public var pulseSections: [PulseSection] {
        guard let pulse else { return [] }
        return PresentationMapper.pulseSections(for: pulse)
    }

    public var pulseIsStale: Bool {
        PresentationMapper.isPulseStale(lastSuccessfulRefreshAt: lastSuccessfulRefreshAt, now: Date())
    }

    public func testConnection() async {
        guard let configuration = validateConfiguration() else { return }
        historyUnavailable = false
        isTestingConnection = true
        defer { isTestingConnection = false }
        do {
            let newService = try serviceFactory(configuration.baseURL, nonEmptyAccessToken)
            let loadedPulse = try await loadPulsePageWithRecovery(using: newService)
            try process(loadedPulse)
            service = newService
            userMessage = nil
        } catch {
            userMessage = pulseMessage(for: error)
        }
    }

    public func refresh() async {
        guard let service else {
            await testConnection()
            return
        }
        historyUnavailable = false
        isLoading = true
        defer { isLoading = false }
        do {
            let loadedPulse = try await loadPulsePageWithRecovery(using: service)
            try process(loadedPulse)
            userMessage = nil
        } catch {
            // A failed page never changes the stored continuation, so retrying
            // remains gap-free and cannot skip an unconsumed page.
            userMessage = pulseMessage(for: error)
        }
    }

    /// Pulse does not maintain a background loop. It refreshes when the host
    /// becomes active, provided it has already rendered a connected Pulse.
    public func refreshOnForeground() async {
        guard pulse != nil, service != nil, !isLoading, !isTestingConnection else { return }
        await refresh()
    }

    public func disconnect() {
        service = nil
        pulse = nil
        accessToken = ""
        lastSuccessfulRefreshAt = nil
        historyUnavailable = false
        cancelInstruction()
    }

    /// Opens the composer only when the current server Pulse item supplied an
    /// exact target id. There is no target text field or local matching path.
    public func beginInstruction(for card: PulseCard) {
        guard let target = card.instructionTarget else { return }
        if activeInstructionTarget != target {
            instructionText = ""
            pendingInstruction = nil
        }
        activeInstructionTarget = target
        instructionReceipt = nil
        userMessage = nil
    }

    /// Closing the composer is an explicit cancellation, so its in-memory
    /// text and id are deliberately not reused.
    public func cancelInstruction() {
        activeInstructionTarget = nil
        instructionText = ""
        pendingInstruction = nil
        instructionReceipt = nil
    }

    public func submitInstruction() async {
        guard let service, let target = activeInstructionTarget else {
            userMessage = "Actualiza Pulse y abre una tarjeta con una instrucción disponible."
            return
        }
        let trimmedText = instructionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            userMessage = "Escribe una instrucción antes de enviarla."
            return
        }
        guard trimmedText.count <= 4_000 else {
            userMessage = "La instrucción debe tener 4.000 caracteres o menos."
            return
        }

        let instruction: OpsInstructionRequest
        if let pendingInstruction,
           pendingInstruction.target == target.id,
           pendingInstruction.text == trimmedText {
            instruction = pendingInstruction
        } else {
            instruction = .init(target: target.id, text: trimmedText)
            pendingInstruction = instruction
        }

        isSendingInstruction = true
        defer { isSendingInstruction = false }
        do {
            let response = try await service.submitInstruction(instruction)
            instructionReceipt = OpsInstructionReceipt(title: target.title, action: response.action)
            pendingInstruction = nil
            instructionText = ""
            userMessage = nil
        } catch {
            // Transport and other uncertain failures intentionally retain this
            // exact request id, target, and text for a safe explicit retry.
            userMessage = pulseMessage(for: error)
        }
    }

    /// Convenience for hosts/tests that do not bind directly to `instructionText`.
    public func submitInstruction(text: String) async {
        instructionText = text
        await submitInstruction()
    }

    public func ask() async {
        guard let service else {
            askFeedback = .unavailable
            return
        }
        let question = askText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.count <= 1_000 else {
            askFeedback = .unsupported
            return
        }
        isAsking = true
        askFeedback = nil
        defer { isAsking = false }
        do {
            let response = try await service.ask(.init(text: question))
            guard let entry = PresentationMapper.askHistoryEntry(question: question, response: response) else {
                askFeedback = .unsupported
                return
            }
            askHistory = PresentationMapper.appendingAskHistory(entry, to: askHistory)
            askText = ""
        } catch {
            askFeedback = .unavailable
        }
    }

    public func clearMessage() {
        userMessage = nil
    }

    private var nonEmptyAccessToken: String? {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private func loadPulsePageWithRecovery(using service: any MoaOpsPresentationService) async throws -> OpsPulse {
        let cursor = cursorStore.cursor()
        do {
            return try await service.loadPulse(cursor: cursor)
        } catch let error as MoaOpsClientError {
            let requiresReset: Bool
            switch error {
            case .pulseResetRequired:
                requiresReset = true
            case let .httpStatus(code, _):
                requiresReset = code == 410
            default:
                requiresReset = false
            }
            guard requiresReset, cursor != nil else { throw error }
            // 410/reset means the opaque stream can no longer continue. Clear
            // it and start exactly one replacement page without a cursor.
            cursorStore.clear()
            let current = try await service.loadPulse(cursor: nil)
            historyUnavailable = true
            return current
        }
    }

    private func process(_ loadedPulse: OpsPulse) throws {
        // Finalized Pulse always issues a polling continuation, including after
        // a final page. Without it, retaining an old cursor could duplicate a
        // page, so leave storage untouched and safely reject the response.
        guard let nextCursor = loadedPulse.changes.nextCursor, !nextCursor.isEmpty else {
            throw MoaOpsClientError.decoding
        }
        pulse = loadedPulse
        lastSuccessfulRefreshAt = Date()
        // The page is rendered before its opaque continuation is committed.
        cursorStore.save(cursor: nextCursor)
    }

    private func validateConfiguration() -> ServerConfiguration? {
        do {
            return try ServerConfiguration(urlText: serverURLText)
        } catch {
            userMessage = "Introduce una dirección http:// o https:// válida."
            return nil
        }
    }

    private func pulseMessage(for error: Error) -> String {
        guard let error = error as? MoaOpsClientError else {
            return "No se pudo actualizar Pulse. Comprueba la conexión e inténtalo de nuevo."
        }
        switch error {
        case .authentication:
            return "El servidor no aceptó esta conexión."
        case let .httpStatus(code, _):
            switch code {
            case 401, 403: return "No tienes acceso a Pulse en este servidor."
            case 404: return "Este servidor todavía no ofrece la API Pulse."
            case 410: return "El historial de cambios ya no está disponible."
            case 429: return "El servidor está limitando las solicitudes. Prueba dentro de un momento."
            default: return "El servidor no pudo actualizar Pulse. Prueba más tarde."
            }
        case .instructionConflict:
            return "La sesión cambió. Abre de nuevo la tarjeta antes de enviar la instrucción."
        case .pulseResetRequired:
            return "El historial de cambios ya no está disponible."
        case .decoding:
            return "El servidor envió una respuesta no compatible."
        default:
            return "No se pudo actualizar Pulse. Comprueba la conexión e inténtalo de nuevo."
        }
    }
}

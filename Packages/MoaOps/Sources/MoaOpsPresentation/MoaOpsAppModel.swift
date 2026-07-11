import Foundation
import SwiftUI
import MoaOpsCore

@MainActor
public final class MoaOpsAppModel: ObservableObject {
    public typealias ServiceFactory = @Sendable (URL) throws -> any MoaOpsPresentationService

    @Published public var serverURLText: String
    @Published public private(set) var pulse: OpsPulse?
    @Published public private(set) var isLoading = false
    @Published public private(set) var isTestingConnection = false
    @Published public private(set) var userMessage: String?
    @Published public private(set) var historyUnavailable = false
    @Published public private(set) var activeInstructionTarget: PulseInstructionTarget?
    @Published public private(set) var instructionReceipt: OpsInstructionReceipt?
    @Published public private(set) var isSendingInstruction = false
    @Published public var askText = ""
    @Published public private(set) var askHistory: [OpsAskHistoryEntry] = []
    @Published public private(set) var askFeedback: OpsAskFeedback?
    @Published public private(set) var isAsking = false

    private let serviceFactory: ServiceFactory
    private let cursorStore: PulseCursorStore
    private var service: (any MoaOpsPresentationService)?
    private let maximumCursorAge: TimeInterval = 31 * 24 * 60 * 60

    public init(
        serverURLText: String = "",
        cursorStore: PulseCursorStore = UserDefaultsPulseCursorStore(),
        serviceFactory: @escaping ServiceFactory = { try MoaOpsLiveService(baseURL: $0) }
    ) {
        self.serverURLText = serverURLText
        self.cursorStore = cursorStore
        self.serviceFactory = serviceFactory
    }

    public var pulseSections: [PulseSection] {
        guard let pulse else { return [] }
        return PresentationMapper.pulseSections(for: pulse)
    }

    public var isAllClear: Bool {
        guard let pulse else { return false }
        return pulse.summary.needsAttention == 0
    }

    public func testConnection() async {
        guard let configuration = validateConfiguration() else { return }
        historyUnavailable = false
        isTestingConnection = true
        defer { isTestingConnection = false }
        do {
            let newService = try serviceFactory(configuration.baseURL)
            let loadedPulse = try await loadPulseWithRecovery(using: newService)
            render(loadedPulse)
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
            let loadedPulse = try await loadPulseWithRecovery(using: service)
            render(loadedPulse)
            userMessage = nil
        } catch {
            userMessage = pulseMessage(for: error)
        }
    }

    public func disconnect() {
        service = nil
        pulse = nil
        activeInstructionTarget = nil
        instructionReceipt = nil
        historyUnavailable = false
    }

    /// Opens the composer only when the current server Pulse item supplied an
    /// exact target id. There is no target text field or local matching path.
    public func beginInstruction(for card: PulseCard) {
        guard let target = card.instructionTarget else { return }
        activeInstructionTarget = target
        instructionReceipt = nil
        userMessage = nil
    }

    public func closeInstruction() {
        activeInstructionTarget = nil
        instructionReceipt = nil
    }

    public func submitInstruction(text: String) async {
        guard let service, let target = activeInstructionTarget else {
            userMessage = "Actualiza Pulse y abre una tarjeta con una instrucción disponible."
            return
        }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            userMessage = "Escribe una instrucción antes de enviarla."
            return
        }
        guard trimmedText.count <= 4_000 else {
            userMessage = "La instrucción debe tener 4.000 caracteres o menos."
            return
        }
        isSendingInstruction = true
        defer { isSendingInstruction = false }
        do {
            let response = try await service.submitInstruction(.init(target: target.id, text: trimmedText))
            instructionReceipt = OpsInstructionReceipt(title: target.title, action: response.action)
            userMessage = nil
        } catch {
            userMessage = pulseMessage(for: error)
        }
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

    private func loadPulseWithRecovery(using service: any MoaOpsPresentationService) async throws -> OpsPulse {
        let cursor = usableCursor()
        do {
            return try await service.loadPulse(since: cursor)
        } catch let error as MoaOpsClientError {
            guard case let .httpStatus(code, _) = error, code == 410, cursor != nil else { throw error }
            // A 410 means the server no longer retains this interval. Retry
            // once without `since`, then explicitly show that changes were lost.
            cursorStore.clear()
            let current = try await service.loadPulse(since: nil)
            historyUnavailable = true
            return current
        }
    }

    private func render(_ loadedPulse: OpsPulse) {
        pulse = loadedPulse
        // `pulse` has been installed before the only persisted value is
        // updated. This is a cursor only, never a response or a secret.
        if isSafeCursor(loadedPulse.generatedAt) {
            cursorStore.save(lastSeen: loadedPulse.generatedAt)
        }
    }

    private func usableCursor() -> Date? {
        guard let cursor = cursorStore.lastSeen(), isSafeCursor(cursor) else {
            if cursorStore.lastSeen() != nil {
                cursorStore.clear()
                historyUnavailable = true
            }
            return nil
        }
        return cursor
    }

    private func isSafeCursor(_ date: Date) -> Bool {
        guard !date.timeIntervalSince1970.isNaN else { return false }
        let now = Date()
        return date <= now.addingTimeInterval(5 * 60) && now.timeIntervalSince(date) <= maximumCursorAge
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
        default:
            return "No se pudo actualizar Pulse. Comprueba la conexión e inténtalo de nuevo."
        }
    }
}

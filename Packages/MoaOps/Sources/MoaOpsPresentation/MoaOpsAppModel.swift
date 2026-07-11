import Foundation
import SwiftUI
import MoaOpsCore

@MainActor
public final class MoaOpsAppModel: ObservableObject {
    public typealias ServiceFactory = @Sendable (URL) throws -> any MoaOpsPresentationService

    @Published public var serverURLText: String
    @Published public private(set) var snapshot: OpsSnapshot?
    @Published public private(set) var sitrep: OpsBriefing?
    @Published public private(set) var blockers: OpsBriefing?
    @Published public private(set) var connection: OpsConnectionState = .disconnected
    @Published public private(set) var isLoading = false
    @Published public private(set) var isTestingConnection = false
    @Published public private(set) var isSnapshotStale = true
    @Published public private(set) var userMessage: String?
    @Published public var selectedSessionID: String?
    @Published public var instructionTargetID: String?
    @Published public private(set) var instructionWasSent = false

    private let serviceFactory: ServiceFactory
    private var service: (any MoaOpsPresentationService)?
    private var updatesTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var lastSnapshotAt: Date?
    private var updateGeneration = UUID()
    private var connectionAttemptID = UUID()

    public init(serverURLText: String = "", serviceFactory: @escaping ServiceFactory = { try MoaOpsLiveService(baseURL: $0) }) {
        self.serverURLText = serverURLText
        self.serviceFactory = serviceFactory
    }

    deinit {
        updatesTask?.cancel()
        stateTask?.cancel()
    }

    public var sessionTargets: [OpsSessionTarget] {
        PresentationMapper.sessionTargets(in: snapshot)
    }

    public var selectedSessionDetail: OpsSessionDetail? {
        guard let selectedSessionID else { return nil }
        return PresentationMapper.detail(sessionID: selectedSessionID, in: snapshot)
    }

    public func testConnection() async {
        guard let configuration = validateConfiguration() else { return }
        let attemptID = UUID()
        connectionAttemptID = attemptID
        isTestingConnection = true
        instructionWasSent = false
        defer {
            if connectionAttemptID == attemptID { isTestingConnection = false }
        }

        do {
            let service = try serviceFactory(configuration.baseURL)
            async let loadedSnapshot = service.loadOverview()
            async let loadedSitrep = service.loadSitrep()
            async let loadedBlockers = service.loadBlockers()
            let (snapshot, sitrep, blockers) = try await (loadedSnapshot, loadedSitrep, loadedBlockers)
            guard connectionAttemptID == attemptID else { return }
            install(snapshot: snapshot, sitrep: sitrep, blockers: blockers, service: service)
            userMessage = nil
            isTestingConnection = false
        } catch {
            guard connectionAttemptID == attemptID else { return }
            connection = .disconnected
            isSnapshotStale = true
            userMessage = PresentationMapper.userMessage(for: error)
        }
    }

    public func refresh() async {
        guard let service else {
            await testConnection()
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            async let loadedSnapshot = service.loadOverview()
            async let loadedSitrep = service.loadSitrep()
            async let loadedBlockers = service.loadBlockers()
            let (newSnapshot, newSitrep, newBlockers) = try await (loadedSnapshot, loadedSitrep, loadedBlockers)
            apply(snapshot: newSnapshot)
            sitrep = newSitrep
            blockers = newBlockers
            userMessage = nil
        } catch {
            isSnapshotStale = true
            userMessage = PresentationMapper.userMessage(for: error)
        }
    }

    public func disconnect() {
        updateGeneration = UUID()
        connectionAttemptID = UUID()
        updatesTask?.cancel()
        stateTask?.cancel()
        updatesTask = nil
        stateTask = nil
        let currentService = service
        service = nil
        connection = .disconnected
        isSnapshotStale = true
        Task { await currentService?.stopUpdates() }
    }

    public func submitInstruction(text: String) async {
        guard let service,
              let targetID = instructionTargetID,
              sessionTargets.contains(where: { $0.id == targetID }) else {
            userMessage = "Choose a current session before sending an instruction."
            return
        }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            userMessage = "Write an instruction before sending it."
            return
        }
        guard trimmedText.count <= 4_000 else {
            userMessage = "Keep instructions to 4,000 characters or fewer."
            return
        }
        instructionWasSent = false
        do {
            _ = try await service.submitInstruction(.init(target: targetID, text: trimmedText))
            instructionWasSent = true
            userMessage = nil
        } catch {
            userMessage = PresentationMapper.userMessage(for: error)
        }
    }

    public func clearMessage() {
        userMessage = nil
    }

    private func validateConfiguration() -> ServerConfiguration? {
        do {
            return try ServerConfiguration(urlText: serverURLText)
        } catch let error as ServerConfigurationError {
            userMessage = error.userMessage
            return nil
        } catch {
            userMessage = "The server address is not valid."
            return nil
        }
    }

    private func install(snapshot: OpsSnapshot, sitrep: OpsBriefing, blockers: OpsBriefing, service: any MoaOpsPresentationService) {
        disconnect()
        self.service = service
        apply(snapshot: snapshot)
        self.sitrep = sitrep
        self.blockers = blockers
        if selectedSessionID == nil { selectedSessionID = sessionTargets.first?.id }
        if instructionTargetID == nil { instructionTargetID = sessionTargets.first?.id }
        startUpdates(for: service)
    }

    private func apply(snapshot: OpsSnapshot) {
        self.snapshot = snapshot
        lastSnapshotAt = Date()
        isSnapshotStale = false
        retainKnownSelection()
    }

    private func retainKnownSelection() {
        let targets = sessionTargets
        if let selectedSessionID, !targets.contains(where: { $0.id == selectedSessionID }) {
            self.selectedSessionID = targets.first?.id
        }
        if let instructionTargetID, !targets.contains(where: { $0.id == instructionTargetID }) {
            self.instructionTargetID = targets.first?.id
        }
    }

    private func startUpdates(for service: any MoaOpsPresentationService) {
        let generation = updateGeneration
        updatesTask = Task { [weak self, service] in
            await service.startUpdates()
            let updates = await service.snapshotUpdates()
            for await update in updates {
                guard !Task.isCancelled else { return }
                guard self?.updateGeneration == generation else { return }
                self?.apply(snapshot: update.snapshot)
            }
        }
        stateTask = Task { [weak self, service] in
            while !Task.isCancelled {
                guard self?.updateGeneration == generation else { return }
                let state = await service.webSocketState()
                guard self?.updateGeneration == generation else { return }
                self?.updateConnection(state)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func updateConnection(_ webSocketState: OpsWebSocketState) {
        connection = OpsConnectionState(webSocketState: webSocketState)
        isSnapshotStale = PresentationMapper.isStale(lastSnapshotAt: lastSnapshotAt, connection: connection, now: Date())
    }
}

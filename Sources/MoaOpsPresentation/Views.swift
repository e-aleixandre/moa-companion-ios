import SwiftUI
import MoaOpsCore

public struct MoaOpsRootView: View {
    @ObservedObject private var model: MoaOpsAppModel

    public init(model: MoaOpsAppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedSessionID) {
                ForEach(model.snapshot?.projects ?? [], id: \.canonicalCWD) { project in
                    Section(project.canonicalCWD) {
                        ForEach(project.sessions, id: \.id) { session in
                            Text(session.title).tag(session.id as String?)
                        }
                    }
                }
            }
            .navigationTitle("Moa Ops")
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ServerConfigurationView(model: model)
                    ConnectionBanner(connection: model.connection, isStale: model.isSnapshotStale)
                    if let message = model.userMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                    SitrepView(sitrep: model.sitrep, blockers: model.blockers)
                    if let detail = model.selectedSessionDetail {
                        SessionDetailView(detail: detail)
                    } else if model.snapshot != nil {
                        EmptySessionSelectionView()
                    }
                    DirectedInstructionComposer(model: model)
                }
                .padding()
            }
            .navigationTitle("Operations")
            .toolbar {
                Button("Refresh") { Task { await model.refresh() } }
                    .disabled(model.isLoading || model.isTestingConnection)
            }
        }
    }
}

public struct ServerConfigurationView: View {
    @ObservedObject private var model: MoaOpsAppModel

    public init(model: MoaOpsAppModel) { self.model = model }

    public var body: some View {
        GroupBox("Server") {
            HStack {
                TextField("https://moa.example", text: $model.serverURLText)
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif
                    .autocorrectionDisabled()
                Button(model.isTestingConnection ? "Testing…" : "Test connection") {
                    Task { await model.testConnection() }
                }
                .disabled(model.isTestingConnection)
            }
        }
    }
}

private struct EmptySessionSelectionView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Select a session")
                .font(.headline)
            Text("Choose a session from the sidebar to view its details.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

public struct ConnectionBanner: View {
    let connection: OpsConnectionState
    let isStale: Bool

    public init(connection: OpsConnectionState, isStale: Bool) {
        self.connection = connection
        self.isStale = isStale
    }

    public var body: some View {
        Label(isStale ? "Snapshot may be stale — \(connection.label)" : connection.label,
              systemImage: isStale ? "clock.badge.exclamationmark" : "dot.radiowaves.left.and.right")
            .foregroundStyle(isStale ? .orange : .green)
    }
}

public struct SitrepView: View {
    let sitrep: OpsBriefing?
    let blockers: OpsBriefing?

    public init(sitrep: OpsBriefing?, blockers: OpsBriefing?) {
        self.sitrep = sitrep
        self.blockers = blockers
    }

    public var body: some View {
        GroupBox("Verified sitrep") {
            if let sitrep {
                VStack(alignment: .leading) {
                    ForEach(sitrep.sessions ?? [], id: \.id) { session in
                        Text("\(session.title): \(PresentationMapper.label(for: session.verification))")
                    }
                    if (sitrep.sessions ?? []).isEmpty { Text("No reported sessions.") }
                }
            } else {
                Text("No verified sitrep loaded.")
            }
        }
        GroupBox("Blockers") {
            if let blockers, !blockers.blockers.isEmpty {
                ForEach(blockers.blockers, id: \.sessionID) { blocker in
                    Text("\(blocker.title): \(blocker.kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)")
                }
            } else {
                Text("No verified blockers reported.")
            }
        }
    }
}

public struct SessionDetailView: View {
    let detail: OpsSessionDetail

    public init(detail: OpsSessionDetail) { self.detail = detail }

    public var body: some View {
        GroupBox(detail.title) {
            Grid(alignment: .leading, verticalSpacing: 8) {
                GridRow { Text("Project"); Text(detail.projectName) }
                GridRow { Text("Lifecycle"); Text(detail.lifecycle) }
                GridRow { Text("Activity"); Text(detail.activity) }
                GridRow { Text("Verification"); Text(detail.verification) }
                GridRow { Text("Jobs"); Text("\(detail.subagentJobs) subagents, \(detail.shellJobs) shell") }
                if let date = detail.lastTransitionAt {
                    GridRow { Text("Last change"); Text(date, style: .relative) }
                }
            }
        }
    }
}

public struct DirectedInstructionComposer: View {
    @ObservedObject private var model: MoaOpsAppModel
    @State private var text = ""

    public init(model: MoaOpsAppModel) { self.model = model }

    public var body: some View {
        GroupBox("Directed instruction") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose a session from the current snapshot. Instructions are never matched by free-form target text.")
                    .font(.footnote)
                Picker("Session", selection: $model.instructionTargetID) {
                    Text("Choose a session").tag(nil as String?)
                    ForEach(model.sessionTargets) { target in
                        Text("\(target.title) — \(target.projectName)").tag(target.id as String?)
                    }
                }
                TextEditor(text: $text)
                    .frame(minHeight: 80)
                    .accessibilityLabel("Instruction")
                Button("Send instruction") {
                    Task {
                        await model.submitInstruction(text: text)
                        if model.instructionWasSent { text = "" }
                    }
                }
                .disabled(model.instructionTargetID == nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

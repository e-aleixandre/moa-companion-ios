import SwiftUI
import MoaOpsCore
#if os(iOS) && canImport(AVFoundation)
import AVFoundation
import UIKit
#endif

// MARK: - Mapeo estado → design system

extension PulseCallState {
    var tone: PulseTone {
        switch self {
        case .disconnected, .ready, .ended: .neutral
        case .connecting, .reconnecting: .warning
        case .listening: .listening
        case .responding: .accent
        case .error: .danger
        }
    }

    var isTransient: Bool {
        switch self {
        case .connecting, .reconnecting: true
        default: false
        }
    }

    var orbMode: PulseOrbMode {
        switch self {
        case .connecting, .reconnecting: .connecting
        case .listening: .listening
        case .responding: .speaking
        case .disconnected, .ready, .ended, .error: .idle
        }
    }
}

// MARK: - Raíz

public struct PulseCallRootView: View {
    @ObservedObject private var model: PulseCallAppModel
    public init(model: PulseCallAppModel) { self.model = model }

    public var body: some View {
        Group {
            if model.rootDestination == .pairing {
                PulsePairingView(model: model)
            } else {
                PulseCallSceneView(model: model)
            }
        }
        .task { await model.start() }
    }
}

// MARK: - Emparejamiento

public struct PulsePairingView: View {
    @ObservedObject var model: PulseCallAppModel
    @State private var baseURL = ""
    @State private var payload = ""
    @State private var label = "iPhone Pulse"
    @State private var showingScanner = false
    @State private var scannerMessage: String?
    @State private var showManualEntry = false

    public init(model: PulseCallAppModel) { self.model = model }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PulseSpacing.lg) {
                PulseVoiceOrb(mode: .idle, diameter: 110)
                    .frame(maxWidth: .infinity)
                    .padding(.top, PulseSpacing.xl)

                VStack(alignment: .leading, spacing: PulseSpacing.xs) {
                    Text("Pulse")
                        .pulseMicroCaps()
                        .foregroundStyle(PulseColor.ember)
                    Text("Llamar a Moa")
                        .font(PulseFont.display)
                        .foregroundStyle(PulseColor.textPrimary)
                    Text("Escanea el QR de Moa o introduce el código temporal manualmente.")
                        .font(PulseFont.callout)
                        .foregroundStyle(PulseColor.textSecondary)
                }

#if os(iOS) && canImport(AVFoundation)
                Button {
                    scannerMessage = nil
                    showingScanner = true
                } label: {
                    Label("Escanear QR de Moa", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(PulsePrimaryButtonStyle())
#endif
                if let scannerMessage {
                    PulseInlineNotice(scannerMessage)
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { showManualEntry.toggle() }
                } label: {
                    HStack {
                        Text("Introducir datos manualmente")
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .rotationEffect(.degrees(showManualEntry ? 180 : 0))
                    }
                }
                .buttonStyle(PulseSecondaryButtonStyle())

                if showManualEntry {
                    VStack(alignment: .leading, spacing: PulseSpacing.sm) {
                        PulseTextField("https://moa.example", text: $baseURL, monospaced: true)
                        PulseTextField("Código moa-pair-v1:…", text: $payload, monospaced: true)
                        PulseTextField("Nombre del dispositivo", text: $label)
                        Button(model.isPairing ? "Emparejando…" : "Emparejar") {
                            Task {
                                await model.claim(baseURLText: baseURL, pairingPayloadText: payload, deviceLabel: label)
                                payload = ""
                            }
                        }
                        .buttonStyle(PulseSecondaryButtonStyle(tone: .accent))
                        .frame(maxWidth: .infinity)
                        .disabled(model.isPairing || baseURL.isEmpty || payload.isEmpty || label.isEmpty)
                        .opacity(model.isPairing || baseURL.isEmpty || payload.isEmpty || label.isEmpty ? 0.5 : 1)
                    }
                    .pulseCard()
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let message = model.userMessage {
                    PulseInlineNotice(message)
                }
            }
            .padding(PulseSpacing.lg)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .pulseScreenBackground()
#if os(iOS) && canImport(AVFoundation)
        .sheet(isPresented: $showingScanner) {
            PulseQRScannerView { value in
                do {
                    _ = try PulsePairingEnvelope(parsing: value)
                    Task { await model.claimQRCode(value, deviceLabel: label) }
                } catch {
                    scannerMessage = "El QR no es un emparejamiento de Pulse válido."
                }
                showingScanner = false
            }
        }
#endif
    }
}

// MARK: - Llamada

public struct PulseCallSceneView: View {
    @ObservedObject var model: PulseCallAppModel
    @State private var showingSettings = false

    public init(model: PulseCallAppModel) { self.model = model }

    public var body: some View {
        VStack(spacing: PulseSpacing.md) {
            header

            Spacer(minLength: 0)

            PulseVoiceOrb(mode: model.state.orbMode)

            VStack(spacing: PulseSpacing.xs) {
                PulseStatusPill(
                    model.state.spanishLabel,
                    tone: model.state.tone,
                    pulses: model.state.isTransient
                )
                Text(model.isCallActive
                    ? "Conversación continua · habla con normalidad"
                    : "Inicia una llamada para hablar con tus sesiones.")
                    .font(PulseFont.footnote)
                    .foregroundStyle(PulseColor.textSecondary)
                    .multilineTextAlignment(.center)
            }

            if let message = model.userMessage {
                PulseInlineNotice(message)
            }

            transcript

            controls
        }
        .padding(PulseSpacing.lg)
        .pulseScreenBackground()
        .sheet(isPresented: $showingSettings) { PulseCallSettingsView(model: model) }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pulse")
                    .font(PulseFont.title)
                    .foregroundStyle(PulseColor.textPrimary)
                Text(model.serverName)
                    .font(PulseFont.monoSmall)
                    .foregroundStyle(PulseColor.textSecondary)
            }
            Spacer()
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
            }
            .buttonStyle(PulseIconButtonStyle(diameter: 40))
            .accessibilityLabel("Ajustes")
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if model.captions.isEmpty {
            Spacer(minLength: 0)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: PulseSpacing.xs) {
                    ForEach(model.captions) { caption in
                        PulseCaptionBubble(text: caption.text, isOwner: caption.isOwner)
                    }
                }
                .padding(PulseSpacing.sm)
            }
            .frame(maxHeight: 220)
            .background(
                RoundedRectangle(cornerRadius: PulseRadius.sheet, style: .continuous)
                    .fill(PulseColor.backgroundBase.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PulseRadius.sheet, style: .continuous)
                    .strokeBorder(PulseColor.hairline, lineWidth: 1)
            )
        }
    }

    private var controls: some View {
        HStack(spacing: PulseSpacing.md) {
            Button {
                model.isMuted.toggle()
            } label: {
                Image(systemName: model.isMuted ? "mic.slash.fill" : "mic.fill")
            }
            .buttonStyle(PulseIconButtonStyle(tone: model.isMuted ? .danger : .neutral, diameter: 56))
            .accessibilityLabel(model.isMuted ? "Activar micrófono" : "Silenciar micrófono")

            if model.isCallActive || model.isConnectingOrReconnecting {
                Button("Colgar") { model.endCall() }
                    .buttonStyle(PulsePrimaryButtonStyle(tone: .danger))
            } else {
                Button("Llamar a Pulse") { model.startCall() }
                    .buttonStyle(PulsePrimaryButtonStyle())
                    .disabled(!model.canStartCall)
                    .opacity(model.canStartCall ? 1 : 0.5)
            }
        }
    }
}

// MARK: - Ajustes

public struct PulseCallSettingsView: View {
    @ObservedObject var model: PulseCallAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showDisconnect = false

    public init(model: PulseCallAppModel) { self.model = model }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PulseSpacing.lg) {
                    PulseSectionHeader("Servidor")
                    VStack(spacing: 0) {
                        settingsRow(label: "Nombre", value: model.serverName, monospaced: true)
                        Divider().overlay(PulseColor.hairline)
                        HStack {
                            Text("Conexión")
                                .font(PulseFont.body)
                                .foregroundStyle(PulseColor.textPrimary)
                            Spacer()
                            PulseStatusPill(
                                model.state.spanishLabel,
                                tone: model.state.tone,
                                pulses: model.state.isTransient
                            )
                        }
                        .padding(.vertical, PulseSpacing.sm)
                    }
                    .pulseCard()

                    PulseSectionHeader("Peligro")
                    Button("Desconectar y borrar credencial") { showDisconnect = true }
                        .buttonStyle(PulseSecondaryButtonStyle(tone: .danger))
                        .frame(maxWidth: .infinity)
                }
                .padding(PulseSpacing.lg)
            }
            .pulseScreenBackground()
            .navigationTitle("Ajustes")
            .pulseInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                        .tint(PulseColor.ember)
                }
            }
            .alert("Desconectar Pulse", isPresented: $showDisconnect) {
                Button("Borrar credencial local", role: .destructive) {
                    model.disconnectAndClearLocalCredential()
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Para usar Pulse otra vez tendrás que emparejar este iPhone.")
            }
        }
    }

    private func settingsRow(label: String, value: String, monospaced: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(PulseFont.body)
                .foregroundStyle(PulseColor.textPrimary)
            Spacer()
            Text(value)
                .font(monospaced ? PulseFont.mono : PulseFont.callout)
                .foregroundStyle(PulseColor.textSecondary)
        }
        .padding(.vertical, PulseSpacing.sm)
    }
}

// MARK: - Escáner QR

#if os(iOS) && canImport(AVFoundation)
private struct PulseQRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController { let controller = ScannerController(); controller.onCode = onCode; return controller }
    func updateUIViewController(_: ScannerController, context _: Context) {}
    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var delivered = false
        override func viewDidLoad() {
            super.viewDidLoad()
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: configure()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    guard granted else { return }
                    DispatchQueue.main.async { self?.configure() }
                }
            default: break
            }
        }
        private func configure() {
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
            session.addInput(input); let output = AVCaptureMetadataOutput(); guard session.canAddOutput(output) else { return }; session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session); preview.frame = view.bounds; preview.videoGravity = .resizeAspectFill; view.layer.addSublayer(preview)
            session.startRunning()
        }
        func metadataOutput(_: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from _: AVCaptureConnection) {
            guard !delivered, let value = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first?.stringValue else { return }
            delivered = true; session.stopRunning(); onCode?(value)
        }
    }
}
#endif

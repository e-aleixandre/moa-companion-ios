import SwiftUI
import MoaOpsCore
#if os(iOS) && canImport(AVFoundation)
import AVFoundation
import UIKit
#endif

/// The app host selects only pairing or the Call Moa scene. Legacy dashboard
/// views remain internal implementation history and are not part of this root.
public struct PulseCallRootView: View {
    @ObservedObject private var model: PulseCallAppModel
    @Environment(\.scenePhase) private var scenePhase

    public init(model: PulseCallAppModel) { self.model = model }

    public var body: some View {
        Group {
            switch model.rootDestination {
            case .pairing:
                PulsePairingView(model: model)
            case .call:
                PulseCallSceneView(model: model)
            }
        }
        .task { await model.start() }
        .onChange(of: scenePhase) { phase in
            model.setForegroundActive(phase == .active)
        }
    }
}

public struct PulsePairingView: View {
    @ObservedObject var model: PulseCallAppModel
    @State private var baseURL = ""
    @State private var pairingPayload = ""
    @State private var deviceLabel = "iPhone Pulse"
    @State private var showingScanner = false

    public init(model: PulseCallAppModel) { self.model = model }

    public var body: some View {
        ZStack {
            LinearGradient(colors: [.indigo.opacity(0.92), .teal.opacity(0.68), .black.opacity(0.92)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Spacer(minLength: 36)
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 62))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white)
                    Text("Llamar a Moa")
                        .font(.system(.largeTitle, design: .rounded).bold())
                        .foregroundStyle(.white)
                    Text("Pulse es tu terminal de voz. Empareja este iPhone con un Serve de Moa que ya tenga una URL configurada.")
                        .foregroundStyle(.white.opacity(0.78))
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Emparejar este dispositivo")
                            .font(.headline)
                        TextField("https://moa.example", text: $baseURL)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
#if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
#endif
                        TextField("moa-pair-v1:…", text: $pairingPayload, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...3)
                            .autocorrectionDisabled()
#if os(iOS)
                            .textInputAutocapitalization(.never)
#endif
                        HStack {
                            Text("Pega el payload del QR de Moa. No incluye una dirección de servidor.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Spacer()
#if os(iOS) && canImport(AVFoundation)
                            Button("Escanear QR", systemImage: "qrcode.viewfinder") { showingScanner = true }
                                .font(.footnote)
#endif
                        }
                        TextField("Nombre de este iPhone", text: $deviceLabel)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                        Text("Pulse exige HTTPS salvo para localhost o 127.x directo. La credencial del dispositivo se guarda solo en el Llavero; no usamos tokens en URL ni cookies de Serve.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button(model.isPairing ? "Emparejando…" : "Emparejar Pulse") {
                            Task {
                                await model.claim(baseURLText: baseURL, pairingPayloadText: pairingPayload, deviceLabel: deviceLabel)
                                // The paste/scan value is one-use input, never a draft
                                // retained after a claim attempt.
                                pairingPayload = ""
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .disabled(model.isPairing || baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pairingPayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    if let message = model.userMessage { PulseCallNotice(message: message) }
                }
                .padding(24)
                .frame(maxWidth: 620, alignment: .leading)
            }
        }
#if os(iOS) && canImport(AVFoundation)
        .sheet(isPresented: $showingScanner) {
            PulseQRScannerView { value in
                pairingPayload = value
                showingScanner = false
            }
        }
#endif
    }
}

public struct PulseCallSceneView: View {
    @ObservedObject var model: PulseCallAppModel
    @State private var captionsExpanded = false
    @State private var showingTextEntry = false
    @State private var textEntry = ""
    @State private var showingProvider = false
    @State private var showingDisconnect = false

    public init(model: PulseCallAppModel) { self.model = model }

    public var body: some View {
        ZStack {
            LinearGradient(colors: backgroundColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                header
                Spacer(minLength: 4)
                PulsePresenceOrb(state: model.state)
                    .accessibilityLabel("Presencia de Pulse: \(model.state.spanishLabel)")
                Text(model.state.spanishLabel)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                if model.voiceUnavailable {
                    Label("La voz no está disponible aquí. Usa el campo de texto.", systemImage: "mic.slash")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.82))
                        .multilineTextAlignment(.center)
                }
                if let review = model.pendingReview { reviewCard(review) }
                if let message = model.userMessage { PulseCallNotice(message: message) }
                Spacer(minLength: 4)
                captions
                controls
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .frame(maxWidth: 680)
        }
        .sheet(isPresented: $showingProvider) { PulseProviderConfigurationView(model: model) }
        .alert("Desconectar Pulse", isPresented: $showingDisconnect) {
            Button("Borrar credencial local", role: .destructive) { model.disconnectAndClearLocalCredential() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Esto borra la credencial de este iPhone del Llavero. Para revocar el dispositivo en Serve, usa Moa como propietario.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Pulse")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("Moa · \(model.serverName) · \(model.freshnessLabel)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
            Spacer()
            Menu {
                Button("Actualizar", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                Button("OpenAI Realtime", systemImage: "key") { showingProvider = true }
                Menu("Modo \(model.privacyMode.spanishLabel)") {
                    ForEach(PulsePrivacyMode.allCases, id: \.self) { mode in
                        Button(mode.spanishLabel) { model.setPrivacyMode(mode) }
                    }
                }
                Button("Respuesta \(model.responseScope.spanishLabel)") {
                    model.setResponseScope(model.responseScope == .mini ? .full : .mini)
                }
                Button("Desconectar este iPhone", systemImage: "iphone.slash", role: .destructive) { showingDisconnect = true }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .padding(8)
            }
            .accessibilityLabel("Opciones de Pulse")
        }
    }

    private var captions: some View {
        DisclosureGroup(isExpanded: $captionsExpanded) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.captions) { caption in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(caption.isOwner ? "Tú" : caption.provenance.spanishLabel)
                                .font(.caption.bold())
                                .foregroundStyle(caption.isOwner ? .teal : .white.opacity(0.72))
                            Text(caption.text)
                                .font(.subheadline)
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.white.opacity(caption.isOwner ? 0.13 : 0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            .frame(maxHeight: 180)
            .padding(.top, 8)
        } label: {
            HStack {
                Label("Subtítulos", systemImage: "captions.bubble")
                Spacer()
                Text(model.captions.isEmpty ? "Sin turnos" : "\(model.captions.count) turnos")
                    .font(.caption)
            }
            .foregroundStyle(.white.opacity(0.9))
        }
        .padding(12)
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var controls: some View {
        VStack(spacing: 11) {
            if showingTextEntry {
                HStack(alignment: .bottom) {
                    TextField("Pregunta o instrucción para Pulse", text: $textEntry, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                    Button("Enviar") {
                        let submitted = textEntry
                        textEntry = ""
                        showingTextEntry = false
                        Task { await model.submitText(submitted) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(textEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            HStack(spacing: 14) {
                Button {
                    showingTextEntry.toggle()
                } label: {
                    Image(systemName: "keyboard")
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .foregroundStyle(.white)
                .accessibilityLabel("Escribir a Pulse")

                PulsePTTButton(isListening: model.isPTTListening, disabled: !model.canUsePushToTalk) {
                    model.beginPushToTalk()
                } onRelease: {
                    model.endPushToTalk()
                }

                Button {
                    model.isMuted.toggle()
                } label: {
                    Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .foregroundStyle(.white)
                .accessibilityLabel(model.isMuted ? "Activar voz" : "Silenciar voz")

                Button {
                    model.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .foregroundStyle(.white)
                .accessibilityLabel("Detener escucha y respuesta")
            }
        }
    }

    private func reviewCard(_ review: PulsePendingReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Revisión inmutable de Moa", systemImage: "checkmark.shield")
                .font(.headline)
            Text("Destino: \(review.review.target.title ?? review.review.target.id)")
            if let scope = review.review.scope { Text("Alcance: \(scope)") }
            if let text = review.review.text { Text("Texto: \(text)") }
            if let tool = review.review.tool { Text("Herramienta: \(tool)") }
            Text(review.review.consequence)
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancelar", role: .cancel) { model.cancelReview() }
                    .buttonStyle(.bordered)
                Button("Confirmar") { Task { await model.confirmCurrentReview() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canConfirmCurrentReview)
            }
            Text(model.canConfirmCurrentReview
                ? "La confirmación solo envía {} a Moa para esta revisión. Nunca confirma que el trabajo posterior haya terminado."
                : "Moa no está actualizado. Esta revisión permanece visible, pero Pulse no puede confirmarla hasta actualizar.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var backgroundColors: [Color] {
        switch model.state {
        case .listening: [.teal.opacity(0.9), .blue.opacity(0.85), .black]
        case .consulting, .thinking: [.indigo.opacity(0.95), .purple.opacity(0.8), .black]
        case .speaking: [.orange.opacity(0.78), .indigo.opacity(0.85), .black]
        case .review: [.orange.opacity(0.82), .indigo.opacity(0.88), .black]
        case .offline, .stale, .error: [.gray.opacity(0.9), .indigo.opacity(0.75), .black]
        default: [.indigo.opacity(0.92), .teal.opacity(0.72), .black]
        }
    }
}

private struct PulsePresenceOrb: View {
    let state: PulseCallState
    @State private var breathing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.10))
                .frame(width: 210, height: 210)
                .scaleEffect(breathing ? 1.14 : 0.9)
            Circle()
                .fill(LinearGradient(colors: [.white.opacity(0.94), .teal.opacity(0.78), .indigo.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 142, height: 142)
                .shadow(color: .teal.opacity(0.7), radius: 24)
                .overlay(Image(systemName: symbol).font(.system(size: 42, weight: .medium)).foregroundStyle(.white))
                .scaleEffect(breathing ? 1.04 : 0.96)
        }
        .onAppear { breathing = true }
        .animation(.easeInOut(duration: duration).repeatForever(autoreverses: true), value: breathing)
    }

    private var symbol: String {
        switch state {
        case .listening: "mic.fill"
        case .consulting: "magnifyingglass"
        case .thinking: "sparkles"
        case .speaking: "waveform"
        case .review: "checkmark.shield.fill"
        case .offline, .stale, .error: "cloud.slash.fill"
        case .disconnected: "link.badge.plus"
        case .ready: "circle.hexagongrid.fill"
        }
    }

    private var duration: Double { state == .listening ? 0.55 : state == .thinking ? 0.85 : 2.1 }
}

private struct PulsePTTButton: View {
    let isListening: Bool
    let disabled: Bool
    let onPress: () -> Void
    let onRelease: () -> Void

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: isListening ? "mic.fill" : "mic")
                .font(.title2)
            Text(isListening ? "Escuchando" : "Mantén para hablar")
                .font(.caption.bold())
        }
        .foregroundStyle(.indigo)
        .frame(width: 132, height: 68)
        .background(.white, in: Capsule())
        .contentShape(Capsule())
        .onLongPressGesture(minimumDuration: 0, maximumDistance: 80, pressing: { pressing in
            pressing ? onPress() : onRelease()
        }, perform: {})
        .opacity(disabled ? 0.45 : 1)
        .allowsHitTesting(!disabled)
        .accessibilityLabel(isListening ? "Escuchando; suelta para terminar" : "Mantén pulsado para hablar")
    }
}

public struct PulseProviderConfigurationView: View {
    @ObservedObject var model: PulseCallAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""

    public init(model: PulseCallAppModel) { self.model = model }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "key.horizontal.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
                Text("Proveedor directo")
                    .font(.title2.bold())
                Text("Pulse conecta directamente con OpenAI Realtime mediante WebSocket nativo y PCM16. La clave es independiente de Moa, se guarda solo en el Llavero de este dispositivo y nunca se envía a Serve. En macOS y simulador la voz no se finge: usa texto.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                SecureField("Clave API de OpenAI", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif
                Text(model.providerAvailabilityLabel)
                    .font(.footnote)
                    .foregroundStyle(model.providerConfigured ? .green : .secondary)
                HStack {
                    Button("Eliminar clave", role: .destructive) { model.clearOpenAIRealtimeAPIKey(); apiKey = "" }
                        .disabled(!model.providerConfigured)
                    Spacer()
                    Button("Guardar") { model.saveOpenAIRealtimeAPIKey(apiKey); apiKey = "" }
                        .buttonStyle(.borderedProminent)
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("OpenAI Realtime")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

private struct PulseCallNotice: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.orange)
            .padding(12)
            .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

#if os(iOS) && canImport(AVFoundation)
private struct PulseQRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_: ScannerController, context _: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var didDeliver = false

        override func viewDidLoad() {
            super.viewDidLoad()
            guard AVCaptureDevice.authorizationStatus(for: .video) != .denied,
                  let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    if granted { DispatchQueue.main.async { self?.configure(input) } }
                }
            } else {
                configure(input)
            }
        }

        private func configure(_ input: AVCaptureDeviceInput) {
            guard session.inputs.isEmpty, session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.frame = view.bounds
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)
            session.startRunning()
        }

        func metadataOutput(_: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from _: AVCaptureConnection) {
            guard !didDeliver,
                  let code = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first?.stringValue else { return }
            didDeliver = true
            session.stopRunning()
            onCode?(code)
        }
    }
}
#endif

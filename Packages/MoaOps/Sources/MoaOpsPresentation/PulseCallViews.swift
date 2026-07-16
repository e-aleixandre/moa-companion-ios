import SwiftUI
import MoaOpsCore
#if os(iOS) && canImport(AVFoundation)
import AVFoundation
import UIKit
#endif

public struct PulseCallRootView: View {
    @ObservedObject private var model: PulseCallAppModel
    public init(model: PulseCallAppModel) { self.model = model }
    public var body: some View {
        Group { model.rootDestination == .pairing ? AnyView(PulsePairingView(model: model)) : AnyView(PulseCallSceneView(model: model)) }
            .task { await model.start() }
    }
}

public struct PulsePairingView: View {
    @ObservedObject var model: PulseCallAppModel
    @State private var baseURL = ""
    @State private var payload = ""
    @State private var label = "iPhone Pulse"
    @State private var showingScanner = false
    @State private var scannerMessage: String?
    public init(model: PulseCallAppModel) { self.model = model }
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer(); Image(systemName: "waveform.circle.fill").font(.system(size: 64)).foregroundStyle(.tint)
            Text("Llamar a Moa").font(.largeTitle.bold())
            Text("Escanea el QR de Moa o introduce el código temporal manualmente.")
#if os(iOS) && canImport(AVFoundation)
            Button("Escanear QR de Moa", systemImage: "qrcode.viewfinder") { scannerMessage = nil; showingScanner = true }
                .buttonStyle(.borderedProminent).controlSize(.large)
#endif
            if let scannerMessage { Text(scannerMessage).foregroundStyle(.red).font(.footnote) }
            DisclosureGroup("Introducir datos manualmente") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("https://moa.example", text: $baseURL).textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    TextField("Código moa-pair-v1:…", text: $payload).textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    TextField("Nombre del dispositivo", text: $label).textFieldStyle(.roundedBorder)
                    Button(model.isPairing ? "Emparejando…" : "Emparejar") { Task { await model.claim(baseURLText: baseURL, pairingPayloadText: payload, deviceLabel: label); payload = "" } }
                        .buttonStyle(.bordered).disabled(model.isPairing || baseURL.isEmpty || payload.isEmpty || label.isEmpty)
                }.padding(.top, 8)
            }
            if let message = model.userMessage { Text(message).foregroundStyle(.red).font(.footnote) }
            Spacer()
        }
        .padding().frame(maxWidth: 560, alignment: .leading)
#if os(iOS) && canImport(AVFoundation)
        .sheet(isPresented: $showingScanner) {
            PulseQRScannerView { value in
                do { _ = try PulsePairingEnvelope(parsing: value); Task { await model.claimQRCode(value, deviceLabel: label) } }
                catch { scannerMessage = "El QR no es un emparejamiento de Pulse válido." }
                showingScanner = false
            }
        }
#endif
    }
}

public struct PulseCallSceneView: View {
    @ObservedObject var model: PulseCallAppModel
    @State private var showDisconnect = false
    public init(model: PulseCallAppModel) { self.model = model }
    public var body: some View {
        VStack(spacing: 20) {
            HStack { VStack(alignment: .leading) { Text("Pulse").font(.title.bold()); Text(model.serverName).foregroundStyle(.secondary) }; Spacer(); Button("Desconectar", role: .destructive) { showDisconnect = true } }
            Spacer()
            Image(systemName: symbol).font(.system(size: 80)).foregroundStyle(model.isCallActive ? Color.green : Color.accentColor)
            Text(model.state.spanishLabel).font(.title2.weight(.semibold))
            Text(model.isCallActive ? "Conversación continua · habla con normalidad" : "Inicia una llamada para hablar con tus sesiones.").foregroundStyle(.secondary)
            if let message = model.userMessage { Text(message).font(.footnote).foregroundStyle(.red) }
            ScrollView { LazyVStack(alignment: .leading, spacing: 8) { ForEach(model.captions) { caption in Text(caption.text).frame(maxWidth: .infinity, alignment: caption.isOwner ? .trailing : .leading).padding(10).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12)) } } }.frame(maxHeight: 220)
            HStack(spacing: 18) {
                Button { model.isMuted.toggle() } label: { Image(systemName: model.isMuted ? "mic.slash.fill" : "mic.fill").frame(width: 52, height: 52) }
                    .accessibilityLabel(model.isMuted ? "Activar micrófono" : "Silenciar micrófono")
                    .buttonStyle(.bordered)
                if model.isCallActive || model.isConnectingOrReconnecting {
                    Button("Colgar") { model.endCall() }.buttonStyle(.borderedProminent).controlSize(.large)
                } else {
                    Button("Llamar a Pulse") { model.startCall() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canStartCall)
                }
            }
            Spacer()
        }.padding().alert("Desconectar Pulse", isPresented: $showDisconnect) { Button("Borrar credencial local", role: .destructive) { model.disconnectAndClearLocalCredential() }; Button("Cancelar", role: .cancel) {} } message: { Text("Para usar Pulse otra vez tendrás que emparejar este iPhone.") }
    }
    private var symbol: String { model.isCallActive ? "waveform" : "phone.fill" }
}

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

import SwiftUI
import UIKit
import AVFoundation

/// Step 2: pair with the PC once. The PC shows a QR (Settings → Remote access → Connect my iPhone) holding its private
/// address and a one-time code that expires in 10 minutes - no lasting secret is ever in the QR.
struct PairView: View {
    @EnvironmentObject var model: AppModel
    @State private var host = "beter-pc"
    @State private var code = ""
    @State private var scanning = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { scanning = true } label: { Label("Scan the code on your PC", systemImage: "qrcode.viewfinder") }
                } footer: {
                    Text("On the PC: B.E.T.E.R. → Settings → Remote access → Connect my iPhone.")
                }
                Section("Or type it") {
                    TextField("PC address", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Pairing code", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .font(.title3.monospaced())
                    Button {
                        Task { await pair() }
                    } label: {
                        if busy { ProgressView() } else { Text("Pair") }
                    }.disabled(busy || code.count < 6 || host.isEmpty)
                }
                if let e = error ?? model.lastError {
                    Section { Text(e).foregroundStyle(.red) }
                }
                Section {
                    LabeledContent("Remote Access", value: "Connected")
                    LabeledContent("App version", value: BeterAPI.appVersion)
                }
            }
            .navigationTitle("Pair with your PC")
            .sheet(isPresented: $scanning) {
                QRScanner { text in
                    scanning = false
                    if apply(text) { Task { await pair() } }
                }
                .ignoresSafeArea()
            }
            .onChange(of: model.pendingPairURL) { _, url in
                if let url, apply(url.absoluteString) {
                    model.pendingPairURL = nil
                    Task { await pair() }
                }
            }
        }
    }

    /// beter://pair?<base64url JSON {"v":1,"host":...,"code":...}>
    private func apply(_ text: String) -> Bool {
        guard let q = text.split(separator: "?", maxSplits: 1).last else { return false }
        var b64 = String(q).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let d = Data(base64Encoded: b64) else { return false }
        let j = JSON.parse(d)
        guard let c = j["code"].string else { return false }
        code = c
        if let h = j["host"].string, !h.isEmpty { host = h }
        return true
    }

    private func pair() async {
        busy = true
        error = nil
        do {
            try await model.pair(host: host, code: code)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        busy = false
    }
}

struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC()
        vc.found = found
        return vc
    }

    func updateUIViewController(_ vc: ScannerVC, context: Context) {}

    final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var found: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var done = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let dev = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: dev),
                  session.canAddInput(input) else {
                let l = UILabel()
                l.text = "Camera not available - type the code instead."
                l.textColor = .white
                l.frame = view.bounds.insetBy(dx: 20, dy: 0)
                l.numberOfLines = 0
                view.addSubview(l)
                return
            }
            session.addInput(input)
            let out = AVCaptureMetadataOutput()
            if session.canAddOutput(out) {
                session.addOutput(out)
                out.setMetadataObjectsDelegate(self, queue: .main)
                out.metadataObjectTypes = [.qr]
            }
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.frame = view.layer.bounds
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning { session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !done, let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject, let s = obj.stringValue,
                  s.hasPrefix("beter://") else { return }
            done = true
            session.stopRunning()
            found?(s)
        }
    }
}

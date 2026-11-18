import AVFoundation
import SwiftUI
import UIKit

/// The camera on the pairing screen: a live preview that reports every QR code it reads. Nothing is recorded or
/// saved. (Adapted from the GupWorks app's scanner, for Swift 6 isolation.)
@MainActor
final class QRScanner: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    enum StartResult: Sendable { case running, denied, noCamera }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    let previewView = PreviewView()
    /// called with the text of each QR code in view (repeats while the code stays in view)
    var onCode: ((String) -> Void)?
    private let camera = CameraSession()

    override init() {
        super.init()
        previewView.previewLayer.session = camera.session
        previewView.previewLayer.videoGravity = .resizeAspectFill
        previewView.backgroundColor = .black
    }

    func start(_ done: @escaping @MainActor (StartResult) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run(done)
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                if granted { run(done) } else { done(.denied) }
            }
        default:
            done(.denied)
        }
    }

    func stop() { camera.stop() }

    private func run(_ done: @escaping @MainActor (StartResult) -> Void) {
        let camera = self.camera
        Task {
            let ok = await camera.start(delegate: self)
            done(ok ? .running : .noCamera)
        }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        let texts = metadataObjects.compactMap { object -> String? in
            guard let code = object as? AVMetadataMachineReadableCodeObject, code.type == .qr else { return nil }
            return code.stringValue
        }
        guard !texts.isEmpty else { return }
        MainActor.assumeIsolated {  // the delegate queue is the main queue
            for text in texts { onCode?(text) }
        }
    }
}

/// The capture session, configured and started on its own queue.
private final class CameraSession: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.gupfit.phone.camera")
    private var configured = false

    func start(delegate: QRScanner) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            queue.async {
                if !self.configured, !self.configure(delegate) {
                    cont.resume(returning: false)
                    return
                }
                if !self.session.isRunning { self.session.startRunning() }
                cont.resume(returning: true)
            }
        }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    /// on the camera queue
    private func configure(_ delegate: QRScanner) -> Bool {
        guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: cam) else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high
        let output = AVCaptureMetadataOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else { return false }
        session.addInput(input)
        session.addOutput(output)
        guard output.availableMetadataObjectTypes.contains(.qr) else { return false }
        output.metadataObjectTypes = [.qr]
        output.setMetadataObjectsDelegate(delegate, queue: .main)
        if cam.isFocusModeSupported(.continuousAutoFocus), (try? cam.lockForConfiguration()) != nil {
            cam.focusMode = .continuousAutoFocus
            if cam.isAutoFocusRangeRestrictionSupported { cam.autoFocusRangeRestriction = .near }
            cam.unlockForConfiguration()
        }
        configured = true
        return true
    }
}

/// The scanner as a SwiftUI view. `onState` says whether the camera runs (the simulator has none).
struct QRCameraView: UIViewRepresentable {
    var onCode: (String) -> Void
    var onState: (QRScanner.StartResult) -> Void

    func makeCoordinator() -> QRScanner { QRScanner() }

    func makeUIView(context: Context) -> QRScanner.PreviewView {
        let scanner = context.coordinator
        scanner.onCode = onCode
        let report = onState
        scanner.start { report($0) }
        return scanner.previewView
    }

    func updateUIView(_ view: QRScanner.PreviewView, context: Context) {
        context.coordinator.onCode = onCode
    }

    static func dismantleUIView(_ view: QRScanner.PreviewView, coordinator: QRScanner) {
        coordinator.stop()
    }
}

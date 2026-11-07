@preconcurrency import AVFoundation
import Observation
import Vision

/// Webcam head tracking for one-time calibration only. Vision face landmarks give a continuous
/// turn/nod proxy: the nose's offset from the eyes' midpoint, in inter-eye distances.
@MainActor @Observable
final class CameraHeadTracker {
    private(set) var isRunning = false
    private(set) var faceFound = false
    private(set) var latest: CameraPose?
    private(set) var error: String?
    @ObservationIgnored var onPose: ((CameraPose) -> Void)?
    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let queue = DispatchQueue(label: "dev.murmury.camera")
    @ObservationIgnored private var reader: FrameReader?

    func start() async {
        guard !isRunning else { return }
        error = nil
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            error = "Camera access denied. Allow it in System Settings › Privacy & Security › Camera."
            return
        }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            error = "No camera found."
            return
        }
        let reader = FrameReader { [weak self] pose in
            Task { @MainActor in self?.receive(pose) }
        }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(reader, queue: queue)
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        self.reader = reader
        let session = session
        queue.async { session.startRunning() }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        let session = session
        queue.async {
            session.stopRunning()
            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
        }
        reader = nil
        isRunning = false
        faceFound = false
    }

    private func receive(_ pose: CameraPose?) {
        faceFound = pose != nil
        guard let pose else { return }
        latest = pose
        onPose?(pose)
    }
}

/// Runs Vision on the camera queue.
private final class FrameReader: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let deliver: (CameraPose?) -> Void

    init(deliver: @escaping (CameraPose?) -> Void) { self.deliver = deliver }

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Capture timestamps are on the host clock, the same clock as `systemUptime`.
        let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer))
        let request = VNDetectFaceLandmarksRequest()
        // Vision's face pose model: continuous yaw, pitch and roll from revision 3 on.
        let pose = VNDetectFaceRectanglesRequest()
        pose.revision = VNDetectFaceRectanglesRequestRevision3
        try? VNImageRequestHandler(cmSampleBuffer: buffer, orientation: .up).perform([request, pose])
        let angles = pose.results?.first.flatMap { f -> SIMD3<Double>? in
            guard let y = f.yaw?.doubleValue, let p = f.pitch?.doubleValue, let r = f.roll?.doubleValue else { return nil }
            return SIMD3(y, p, r)
        }
        guard let face = request.results?.first, let lm = face.landmarks,
              let nose = lm.nose?.normalizedPoints, let left = lm.leftEye?.normalizedPoints,
              let right = lm.rightEye?.normalizedPoints, !nose.isEmpty, !left.isEmpty, !right.isEmpty else {
            deliver(nil)
            return
        }
        func mean(_ p: [CGPoint]) -> CGPoint {
            CGPoint(x: p.map(\.x).reduce(0, +) / CGFloat(p.count), y: p.map(\.y).reduce(0, +) / CGFloat(p.count))
        }
        let n = mean(nose), l = mean(left), r = mean(right)
        let mid = CGPoint(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2)
        let span = max(hypot(l.x - r.x, l.y - r.y), 1e-3)
        let mouth = CameraMouth.opening(innerLips: lm.innerLips?.normalizedPoints, outerLips: lm.outerLips?.normalizedPoints, eyeSpan: Double(span))
        deliver(CameraPose(t: t, yaw: Double((n.x - mid.x) / span), pitch: Double((n.y - mid.y) / span), angles: angles, mouth: mouth))
    }
}

import AVFoundation

final class CameraPipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    var onReady: (() -> Void)?
    var onError: ((String) -> Void)?
    var onFrame: ((EncodedFrame) -> Void)?
    private let queue = DispatchQueue(label: "camera.capture", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    private var encoder: H264Encoder?
    private var encoding = false
    private var forceKeyframe = false
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                            object: session, queue: nil) { [weak self] _ in
            self?.onError?("Camera interrupted. Streaming has stopped.")
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                            object: session, queue: nil) { [weak self] _ in self?.resume() })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                            object: session, queue: nil) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self?.onError?(error?.localizedDescription ?? "The camera is unavailable.")
        })
    }

    func prepare() {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                if self.input == nil {
                    self.session.beginConfiguration()
                    defer { self.session.commitConfiguration() }
                    self.session.sessionPreset = .hd1280x720
                    try self.installCamera(position: .back)
                    self.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                    self.output.alwaysDiscardsLateVideoFrames = true
                    self.output.setSampleBufferDelegate(self, queue: self.queue)
                    guard self.session.canAddOutput(self.output) else { throw CameraError.configuration }
                    self.session.addOutput(self.output)
                    self.configureConnection()
                }
                if !self.session.isRunning { self.session.startRunning() }
                self.onReady?()
            } catch { self.onError?(error.localizedDescription) }
        }
    }

    func switchCamera(front: Bool) {
        queue.async { [weak self] in
            guard let self, !self.encoding else { return }
            self.session.beginConfiguration()
            do {
                try self.installCamera(position: front ? .front : .back)
                self.configureConnection()
                self.session.commitConfiguration()
                self.onReady?()
            } catch {
                self.session.commitConfiguration()
                self.onError?(error.localizedDescription)
            }
        }
    }

    func resume() { prepare() }

    func pause() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopEncoder()
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func startEncoding() {
        queue.async { [weak self] in self?.encoding = true; self?.forceKeyframe = true }
    }

    func stopEncoding() {
        queue.async { [weak self] in self?.stopEncoder() }
    }

    func requestKeyframe() {
        queue.async { [weak self] in self?.forceKeyframe = true }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard encoding, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        do {
            if encoder == nil {
                encoder = try H264Encoder(width: Int32(CVPixelBufferGetWidth(buffer)),
                                          height: Int32(CVPixelBufferGetHeight(buffer)),
                                          onFrame: { [weak self] in self?.onFrame?($0) },
                                          onError: { [weak self] in self?.onError?($0) })
            }
            encoder?.encode(buffer, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), forceKeyframe: forceKeyframe)
            forceKeyframe = false
        } catch {
            stopEncoder()
            onError?(error.localizedDescription)
        }
    }

    private func stopEncoder() {
        encoding = false
        encoder?.stop()
        encoder = nil
    }

    private func installCamera(position: AVCaptureDevice.Position) throws {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw CameraError.unavailable
        }
        let next = try AVCaptureDeviceInput(device: camera)
        let previous = input
        if let previous { session.removeInput(previous) }
        guard session.canAddInput(next) else {
            if let previous, session.canAddInput(previous) { session.addInput(previous) }
            throw CameraError.configuration
        }
        session.addInput(next)
        input = next
        try camera.lockForConfiguration()
        defer { camera.unlockForConfiguration() }
        if camera.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
            camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        }
    }

    private func configureConnection() {
        guard let connection = output.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}

private enum CameraError: LocalizedError {
    case unavailable, configuration
    var errorDescription: String? {
        switch self {
        case .unavailable: "No camera is available. Use a physical iPhone."
        case .configuration: "Unable to configure the camera."
        }
    }
}
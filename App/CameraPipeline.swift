import AVFoundation

enum CameraResolution: String, CaseIterable, Identifiable {
    case vga
    case hd720
    case hd1080
    case uhd4K

    var id: String { rawValue }
    var label: String {
        switch self {
        case .vga: "480p"
        case .hd720: "720p"
        case .hd1080: "1080p"
        case .uhd4K: "4K"
        }
    }
    var dimensions: (width: Int32, height: Int32) {
        switch self {
        case .vga: (640, 480)
        case .hd720: (1280, 720)
        case .hd1080: (1920, 1080)
        case .uhd4K: (3840, 2160)
        }
    }
    var pixelCount: Int { Int(dimensions.width) * Int(dimensions.height) }
}

final class CameraPipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    var onReady: (() -> Void)?
    var onError: ((String) -> Void)?
    var onFrame: ((EncodedFrame) -> Void)?
    var onVideoOptions: ((CameraResolution, Int, [CameraResolution], [Int]) -> Void)?
    private let queue = DispatchQueue(label: "camera.capture", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    private var encoder: H264Encoder?
    private var encoding = false
    private var forceKeyframe = false
    private var resolution = CameraResolution.hd720
    private var frameRate = 30
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
            var configuring = false
            do {
                if self.input == nil {
                    self.session.beginConfiguration()
                    configuring = true
                    self.session.sessionPreset = .inputPriority
                    try self.installCamera(position: .back)
                    self.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                    self.output.alwaysDiscardsLateVideoFrames = true
                    self.output.setSampleBufferDelegate(self, queue: self.queue)
                    guard self.session.canAddOutput(self.output) else { throw CameraError.configuration }
                    self.session.addOutput(self.output)
                    self.configureConnection()
                    self.session.commitConfiguration()
                    configuring = false
                }
                try self.applyVideoConfiguration()
                if !self.session.isRunning { self.session.startRunning() }
                self.onReady?()
            } catch {
                if configuring { self.session.commitConfiguration() }
                self.onError?(error.localizedDescription)
            }
        }
    }

    func switchCamera(front: Bool) {
        queue.async { [weak self] in
            guard let self, !self.encoding else { return }
            var configuring = false
            self.session.beginConfiguration()
            configuring = true
            do {
                try self.installCamera(position: front ? .front : .back)
                self.configureConnection()
                self.session.commitConfiguration()
                configuring = false
                try self.applyVideoConfiguration()
                self.onReady?()
            } catch {
                if configuring { self.session.commitConfiguration() }
                self.onError?(error.localizedDescription)
            }
        }
    }

    func configureVideo(resolution: CameraResolution, frameRate: Int) {
        queue.async { [weak self] in
            guard let self, !self.encoding else { return }
            self.resolution = resolution
            self.frameRate = frameRate
            do { try self.applyVideoConfiguration() }
            catch { self.onError?(error.localizedDescription) }
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
                                          frameRate: frameRate,
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
    }

    private func applyVideoConfiguration() throws {
        guard let camera = input?.device else { throw CameraError.unavailable }
        let rates = [15, 24, 30, 60]
        func formats(for resolution: CameraResolution) -> [AVCaptureDevice.Format] {
            camera.formats.filter { format in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return dimensions.width == resolution.dimensions.width && dimensions.height == resolution.dimensions.height
            }
        }
        func supports(_ rate: Int, formats: [AVCaptureDevice.Format]) -> Bool {
            formats.contains { format in
                format.videoSupportedFrameRateRanges.contains {
                    $0.minFrameRate <= Double(rate) && $0.maxFrameRate >= Double(rate)
                }
            }
        }

        let availableResolutions = CameraResolution.allCases.filter { resolution in
            formats(for: resolution).contains { format in
                rates.contains { rate in
                    format.videoSupportedFrameRateRanges.contains {
                        $0.minFrameRate <= Double(rate) && $0.maxFrameRate >= Double(rate)
                    }
                }
            }
        }
        guard !availableResolutions.isEmpty else { throw CameraError.configuration }
        let selectedResolution = availableResolutions.contains(resolution)
            ? resolution
            : availableResolutions.last(where: { $0.pixelCount <= resolution.pixelCount }) ?? availableResolutions[0]
        let resolutionFormats = formats(for: selectedResolution)
        let availableRates = rates.filter { supports($0, formats: resolutionFormats) }
        guard !availableRates.isEmpty else { throw CameraError.configuration }
        let selectedRate = availableRates.contains(frameRate)
            ? frameRate
            : availableRates.last(where: { $0 <= frameRate }) ?? availableRates[0]
        guard let selectedFormat = resolutionFormats.first(where: { supports(selectedRate, formats: [$0]) }) else {
            throw CameraError.configuration
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canSetSessionPreset(.inputPriority) else { throw CameraError.configuration }
        session.sessionPreset = .inputPriority
        try camera.lockForConfiguration()
        camera.activeFormat = selectedFormat
        let duration = CMTime(value: 1, timescale: Int32(selectedRate))
        camera.activeVideoMinFrameDuration = duration
        camera.activeVideoMaxFrameDuration = duration
        camera.unlockForConfiguration()
        resolution = selectedResolution
        frameRate = selectedRate
        onVideoOptions?(selectedResolution, selectedRate, availableResolutions, availableRates)
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
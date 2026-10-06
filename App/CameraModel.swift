import AVFoundation
import Combine
import Darwin
import Network
import StreamingCore
import UIKit

@MainActor
final class CameraModel: ObservableObject {
    @Published private(set) var cameraReady = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var isStreaming = false
    @Published private(set) var isStarting = false
    @Published private(set) var viewerCount = 0
    @Published private(set) var address: String?
    @Published private(set) var startedAt: Date?
    @Published var frontCamera = false
    @Published var errorMessage: String?
    let pipeline = CameraPipeline()
    #if DEBUG
    private let server = RTSPServer(traceResponses: true)
    #else
    private let server = RTSPServer()
    #endif
    private let monitor = NWPathMonitor()
    private var authorized = false
    private var checkingPermission = false
    private var wantsStream = false

    var streamURL: String? { address.map { "rtsp://\($0):8554/live" } }

    init() {
        let server = self.server
        let pipeline = self.pipeline
        pipeline.onFrame = { frame in
            server.publish(nalUnits: frame.nalUnits, presentationTime: frame.presentationTime,
                           isKeyframe: frame.isKeyframe, sps: frame.sps, pps: frame.pps)
        }
        pipeline.onReady = { [weak self] in
            Task { @MainActor in self?.cameraReady = true }
        }
        pipeline.onError = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                self.stop()
                self.cameraReady = false
                self.errorMessage = message
            }
        }
        server.onKeyframeRequest = { [weak pipeline] in pipeline?.requestKeyframe() }
        server.onClientCountChange = { [weak self] count in
            Task { @MainActor in self?.viewerCount = count }
        }
        server.onStateChange = { [weak self] ready, message in
            Task { @MainActor in
                guard let self, self.wantsStream else { return }
                if ready {
                    self.isStarting = false
                    self.isStreaming = true
                    self.startedAt = Date()
                } else {
                    self.stop()
                    self.errorMessage = message
                }
            }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let address = path.status == .satisfied ? Self.localAddress() : nil
            Task { @MainActor in
                guard let self else { return }
                self.address = address
                if address == nil && self.wantsStream {
                    self.stop()
                    self.errorMessage = "Local network connection lost."
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "camera.network-path"))
    }

    func prepare() async {
        guard !checkingPermission else { return }
        checkingPermission = true
        defer { checkingPermission = false }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
        default: authorized = false
        }
        permissionDenied = !authorized
        if authorized { pipeline.prepare() }
    }

    func start() {
        guard cameraReady, address != nil, !wantsStream else { return }
        errorMessage = nil
        wantsStream = true
        isStarting = true
        UIApplication.shared.isIdleTimerDisabled = true
        pipeline.startEncoding()
        server.start()
    }

    func stop() {
        wantsStream = false
        isStarting = false
        isStreaming = false
        startedAt = nil
        viewerCount = 0
        server.stop()
        pipeline.stopEncoding()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func switchCamera() {
        guard !isStreaming, !isStarting else { return }
        cameraReady = false
        pipeline.switchCamera(front: frontCamera)
    }

    func background() {
        stop()
        cameraReady = false
        pipeline.pause()
    }

    func foreground() {
        Task { await prepare() }
    }

    nonisolated private static func localAddress() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var cursor = interfaces
        var candidates: [(String, String)] = []
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  current.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            candidates.append((name, String(cString: host)))
        }
        return candidates.first(where: { $0.0 == "en0" })?.1 ?? candidates.first?.1
    }

    deinit { monitor.cancel(); server.stop(); pipeline.pause() }
}
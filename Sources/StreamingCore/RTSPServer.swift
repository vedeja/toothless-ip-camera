import Foundation
import Network
import OSLog

public enum RTSPServerError: LocalizedError {
    case transportUnavailable
    public var errorDescription: String? { "Unable to open RTP/RTCP ports." }
}

public final class RTSPServer {
    public var onStateChange: ((Bool, String?) -> Void)?
    public var onClientCountChange: ((Int) -> Void)?
    public var onKeyframeRequest: (() -> Void)?
    public var onDiagnosticMessage: ((String) -> Void)?
    private let traceResponses: Bool
    private let logger = Logger(subsystem: "com.toothless.camera", category: "RTSP")
    private let queue = DispatchQueue(label: "camera.rtsp")
    private var listener: NWListener?
    private var clients: [UUID: Client] = [:]
    private var parameterSets: (Data, Data)?
    private var timer: DispatchSourceTimer?

    public init(traceResponses: Bool = false) {
        self.traceResponses = traceResponses
    }

    public func start(port: UInt16 = 8554) {
        queue.async { [weak self] in
            guard let self, self.listener == nil else { return }
            do {
                guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
                    throw RTSPServerError.transportUnavailable
                }
                let listener = try NWListener(using: .tcp, on: endpointPort)
                listener.service = NWListener.Service(name: "Toothless Camera", type: "_rtsp._tcp")
                self.listener = listener
                self.logger.notice("Starting RTSP listener on port \(port)")
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        self.logger.notice("RTSP listener ready")
                        self.onStateChange?(true, nil)
                    case .waiting(let error):
                        self.logger.error("RTSP listener waiting: \(error.localizedDescription, privacy: .public)")
                    case .failed(let error):
                        self.logger.error("RTSP listener failed: \(error.localizedDescription, privacy: .public)")
                        self.stopOnQueue()
                        self.onStateChange?(false, error.localizedDescription)
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { connection.cancel(); return }
                    guard self.clients.count < 4 else {
                        self.logger.notice("RTSP connection rejected: four-client limit reached")
                        connection.cancel()
                        return
                    }
                    let client = Client(connection: connection, queue: self.queue, traceResponses: self.traceResponses)
                    client.onDiagnosticMessage = { [weak self] message in self?.onDiagnosticMessage?(message) }
                    self.logger.notice("RTSP client \(client.logID, privacy: .public) connected")
                    self.clients[client.id] = client
                    client.onRequest = { [weak self, weak client] request in
                        guard let self, let client else { return }
                        self.handle(request, client: client)
                    }
                    client.onClose = { [weak self, weak client] in
                        guard let self, let client else { return }
                        self.clients.removeValue(forKey: client.id)
                        self.updateCount()
                    }
                    client.start()
                }
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + 10, repeating: 10)
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
                    for client in Array(self.clients.values) where Date().timeIntervalSince(client.lastActivity) > 75 {
                        self.logger.notice("RTSP client \(client.logID, privacy: .public) timed out: no keepalive")
                        client.close()
                    }
                }
                self.timer = timer
                timer.resume()
                listener.start(queue: self.queue)
            } catch {
                self.logger.error("RTSP listener could not start: \(error.localizedDescription, privacy: .public)")
                self.onStateChange?(false, error.localizedDescription)
            }
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    public func publish(nalUnits: [Data], presentationTime: Double, isKeyframe: Bool,
                        sps: Data, pps: Data) {
        queue.async { [weak self] in
            guard let self, self.listener != nil else { return }
            if self.parameterSets == nil {
                self.logger.notice("First encoded H.264 frame received; SDP is available")
            }
            self.parameterSets = (sps, pps)
            for client in Array(self.clients.values) where client.playing {
                if client.waitingForKeyframe && !isKeyframe { continue }
                client.waitingForKeyframe = false
                let units = isKeyframe ? [sps, pps] + nalUnits : nalUnits
                let clock = UInt32(truncatingIfNeeded: Int64(presentationTime * 90_000))
                let timestamp = clock &+ client.timestampOffset
                let packets = client.packetizer.packets(nalUnits: units, timestamp: timestamp)
                client.sendMedia(packets, isRTCP: false)
                if Date().timeIntervalSince(client.lastReport) >= 5 {
                    client.sendMedia([client.packetizer.senderReport(timestamp: timestamp)], isRTCP: true)
                    client.lastReport = Date()
                }
            }
        }
    }

    private func stopOnQueue() {
        if listener != nil { logger.notice("Stopping RTSP listener") }
        listener?.cancel()
        listener = nil
        timer?.cancel()
        timer = nil
        for client in Array(clients.values) { client.close() }
        clients.removeAll()
        parameterSets = nil
        updateCount()
    }

    private func updateCount() {
        onClientCountChange?(clients.values.filter(\.playing).count)
    }

    private func handle(_ request: RTSPRequest, client: Client) {
        let sequence = request.headers["cseq"] ?? "0"
        let methods = ["OPTIONS", "DESCRIBE", "SETUP", "PLAY", "PAUSE", "TEARDOWN", "GET_PARAMETER"]
        let method = methods.contains(request.method) ? request.method : "unsupported method"
        logger.notice("RTSP client \(client.logID, privacy: .public): received \(method, privacy: .public), CSeq \(sequence, privacy: .public)")
        client.trace("received \(method), CSeq=\(sequence), URL=\(RTSPDiagnosticRedaction.url(request.uri))")
        func respond(_ code: Int = 200, _ reason: String = "OK",
                     headers: [String: String] = [:], body: String = "", close: Bool = false) {
            var fields = headers
            if client.transport != nil { fields["Session"] = "\(client.session);timeout=60" }
            client.respond(method: method, sequence: sequence, code: code, reason: reason,
                           headers: fields, body: body, close: close)
        }
        if request.method == "OPTIONS" {
            respond(headers: ["Public": "OPTIONS, DESCRIBE, SETUP, PLAY, PAUSE, TEARDOWN, GET_PARAMETER"])
            return
        }
        guard let url = URL(string: request.uri), ["/live", "/live/", "/live/trackID=0"].contains(url.path) else {
            respond(404, "Not Found")
            return
        }
        if let session = request.headers["session"],
           session.components(separatedBy: ";")[0] != client.session {
            respond(454, "Session Not Found")
            return
        }
        switch request.method {
        case "DESCRIBE":
            guard let (sps, pps) = parameterSets, sps.count >= 4 else {
                logger.notice("RTSP DESCRIBE not ready: waiting for encoded H.264 parameter sets")
                respond(503, "Service Unavailable", headers: ["Retry-After": "1"])
                return
            }
            let profile = sps.dropFirst().prefix(3).map { String(format: "%02X", $0) }.joined()
            let body = ["v=0", "o=- 0 0 IN IP4 0.0.0.0", "s=Toothless Camera", "t=0 0",
                        "a=control:*", "m=video 0 RTP/AVP 96", "c=IN IP4 0.0.0.0",
                        "a=rtpmap:96 H264/90000",
                        "a=fmtp:96 packetization-mode=1;profile-level-id=\(profile);sprop-parameter-sets=\(sps.base64EncodedString()),\(pps.base64EncodedString())",
                        "a=control:trackID=0", ""].joined(separator: "\r\n")
            var base = URLComponents(url: url, resolvingAgainstBaseURL: false)
            base?.path = "/live/"
            base?.query = nil
            respond(headers: ["Content-Type": "application/sdp", "Content-Base": base?.string ?? request.uri + "/"], body: body)
        case "SETUP":
            guard !client.playing else { respond(455, "Method Not Valid in This State"); return }
            guard url.path == "/live/trackID=0",
                  let header = request.headers["transport"],
                  let transport = RTSPTransport(header: header) else {
                respond(461, "Unsupported Transport")
                return
            }
            var transportHeader: String
            switch transport {
            case .tcp(let rtp, let rtcp):
                logger.notice("RTSP client \(client.logID, privacy: .public): negotiated TCP channels \(rtp)-\(rtcp)")
                client.udp = nil
                transportHeader = "RTP/AVP/TCP;unicast;interleaved=\(rtp)-\(rtcp)"
            case .udp(let rtp, let rtcp):
                guard case .hostPort(let host, _) = client.connection.endpoint else {
                    respond(461, "Unsupported Transport"); return
                }
                do {
                    let udp = try UDPTransport(host: "\(host)", rtpPort: rtp, rtcpPort: rtcp)
                    client.udp = udp
                    logger.notice("RTSP client \(client.logID, privacy: .public): negotiated UDP; client ports \(rtp)-\(rtcp), server ports \(udp.serverPort)-\(udp.serverPort + 1)")
                    transportHeader = "RTP/AVP;unicast;client_port=\(rtp)-\(rtcp);server_port=\(udp.serverPort)-\(udp.serverPort + 1)"
                } catch { respond(500, "Transport Unavailable"); return }
            }
            client.transport = transport
            transportHeader += ";ssrc=\(String(format: "%08X", client.packetizer.ssrc))"
            respond(headers: ["Transport": transportHeader])
        case "PLAY":
            guard client.transport != nil, request.headers["session"] != nil else {
                respond(454, "Session Not Found"); return
            }
            respond(headers: ["Range": "npt=0.000-"])
            client.playing = true
            client.waitingForKeyframe = true
            client.sentFirstVideo = false
            logger.notice("RTSP client \(client.logID, privacy: .public): PLAY accepted; waiting for keyframe")
            onKeyframeRequest?()
            updateCount()
        case "PAUSE", "TEARDOWN":
            guard client.transport != nil, request.headers["session"] != nil else {
                respond(454, "Session Not Found"); return
            }
            client.playing = false
            respond(close: request.method == "TEARDOWN")
            updateCount()
        case "GET_PARAMETER": respond()
        default: respond(405, "Method Not Allowed")
        }
    }
}

private final class Client {
    let id = UUID()
    var logID: String { String(id.uuidString.prefix(8)) }
    let session = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let connection: NWConnection
    let queue: DispatchQueue
    var onRequest: ((RTSPRequest) -> Void)?
    var onClose: (() -> Void)?
    var onDiagnosticMessage: ((String) -> Void)?
    var transport: RTSPTransport?
    var udp: UDPTransport?
    var playing = false
    var waitingForKeyframe = true
    var sentFirstVideo = false
    var packetizer = RTPPacketizer()
    let timestampOffset = UInt32.random(in: .min ... .max)
    var lastActivity = Date()
    var lastReport = Date.distantPast
    private var parser = RTSPRequestParser()
    private var closed = false
    private var pendingBytes = 0
    private var nextWriteID: UInt64 = 0
    private let traceResponses: Bool
    private let connectedAt = ProcessInfo.processInfo.systemUptime
    private let timestampFormatter = ISO8601DateFormatter()
    private let logger = Logger(subsystem: "com.toothless.camera", category: "RTSP")

    init(connection: NWConnection, queue: DispatchQueue, traceResponses: Bool) {
        self.connection = connection
        self.queue = queue
        self.traceResponses = traceResponses
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func trace(_ message: String) {
        guard traceResponses else { return }
        let elapsed = String(format: "%.6f", ProcessInfo.processInfo.systemUptime - connectedAt)
        let text = "[RTSP \(logID) \(timestampFormatter.string(from: Date())) +\(elapsed)s] \(message)"
        logger.notice("\(text, privacy: .public)")
        onDiagnosticMessage?(text)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.trace("TCP connection ready; control and interleaved media share this NWConnection and serial write path")
                self?.receive()
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func close() {
        guard !closed else { return }
        closed = true
        trace("connection closing; pending TCP bytes=\(pendingBytes)")
        logger.notice("RTSP client \(self.logID, privacy: .public) closed")
        playing = false
        udp = nil
        connection.cancel()
        onClose?()
    }

    func respond(method: String, sequence: String, code: Int, reason: String,
                 headers: [String: String], body: String, close: Bool) {
        logger.notice("RTSP client \(self.logID, privacy: .public): queued response \(code), CSeq \(sequence, privacy: .public)")
        var lines = ["RTSP/1.0 \(code) \(reason)", "CSeq: \(sequence)", "Server: Toothless/1.0"]
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) { lines.append("\(key): \(value)") }
        lines.append("Content-Length: \(body.utf8.count)")
        let data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
        var diagnosticLines: [String] = []
        if traceResponses {
            diagnosticLines = ["RTSP/1.0 \(code) \(reason)", "CSeq: \(sequence)", "Server: Toothless/1.0"]
            for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
                let safeValue = key.lowercased() == "content-base" ? RTSPDiagnosticRedaction.url(value) : value
                diagnosticLines.append("\(key): \(safeValue)")
            }
            diagnosticLines.append("Content-Length: \(body.utf8.count)")
            diagnosticLines.append("")
            if !body.isEmpty { diagnosticLines += body.components(separatedBy: "\r\n") }
        }
        send(data, closeAfter: close, traceLabel: "response \(method) \(code) CSeq=\(sequence)",
             responseLines: diagnosticLines)
    }

    func sendMedia(_ packets: [Data], isRTCP: Bool) {
        guard let transport, !closed, !packets.isEmpty else { return }
        switch transport {
        case .udp:
            for packet in packets { udp?.send(packet, isRTCP: isRTCP) }
        case .tcp(let rtp, let rtcp):
            var framed = Data()
            for packet in packets {
                framed.append(contentsOf: [0x24, isRTCP ? rtcp : rtp])
                framed.appendBigEndian(UInt16(packet.count))
                framed.append(packet)
            }
            let label = !isRTCP && !sentFirstVideo
                ? "first RTP batch channel=\(rtp) packets=\(packets.count)"
                : nil
            send(framed, traceLabel: label)
        }
        if !isRTCP && !sentFirstVideo && !closed {
            sentFirstVideo = true
            logger.notice("RTSP client \(self.logID, privacy: .public): first H.264 frame queued (\(packets.count) RTP packets)")
        }
    }

    private func send(_ data: Data, closeAfter: Bool = false, traceLabel: String? = nil,
                      responseLines: [String] = []) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !closed else { return }
        guard pendingBytes + data.count <= 2_000_000 else {
            logger.notice("RTSP client \(self.logID, privacy: .public) disconnected: TCP send queue exceeded 2 MB")
            close()
            return
        }
        pendingBytes += data.count
        nextWriteID &+= 1
        let writeID = nextWriteID
        if let traceLabel {
            trace("write=\(writeID) submitted \(traceLabel) bytes=\(data.count)")
            for (index, line) in responseLines.enumerated() {
                trace("write=\(writeID) response line=\(index + 1): \(line)")
            }
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            dispatchPrecondition(condition: .onQueue(self.queue))
            self.pendingBytes -= data.count
            if let traceLabel {
                let result = error.map { "failed: \($0.localizedDescription)" } ?? "completed locally (contentProcessed; not a peer acknowledgement)"
                self.trace("write=\(writeID) \(result) \(traceLabel) bytes=\(data.count)")
            }
            if let error {
                self.logger.error("RTSP client \(self.logID, privacy: .public) send failed: \(error.localizedDescription, privacy: .public)")
            }
            if error != nil || closeAfter { self.close() }
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.lastActivity = Date()
                do {
                    for request in try self.parser.append(data) { self.onRequest?(request) }
                } catch {
                    self.logger.error("RTSP client \(self.logID, privacy: .public): malformed or oversized RTSP request")
                    self.close()
                    return
                }
            }
            if let error {
                self.logger.error("RTSP client \(self.logID, privacy: .public) receive failed: \(error.localizedDescription, privacy: .public)")
            }
            if complete || error != nil { self.close() } else { self.receive() }
        }
    }
}

enum RTSPDiagnosticRedaction {
    static func url(_ value: String) -> String {
        guard var components = URLComponents(string: value), components.scheme == "rtsp",
              components.host != nil else { return "<invalid or non-RTSP URL>" }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "<invalid RTSP URL>"
    }
}
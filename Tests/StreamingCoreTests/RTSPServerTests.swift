import Darwin
import Foundation
import XCTest
@testable import StreamingCore

final class RTSPServerTests: XCTestCase {
    func testDescribeBeforeEncoderReadyReturnsRetryable503() throws {
        let server = RTSPServer()
        let ready = expectation(description: "RTSP listener ready without video")
        server.onStateChange = { running, error in
            if running { ready.fulfill() }
            if let error { XCTFail(error) }
        }
        let port = UInt16.random(in: 30_000...39_999)
        server.start(port: port)
        defer { server.stop() }
        wait(for: [ready], timeout: 5)
        let control = try TestSocket(type: SOCK_STREAM)
        try control.connect(port: port)
        let response = try control.request("DESCRIBE rtsp://127.0.0.1:\(port)/live RTSP/1.0\r\nCSeq: 1\r\n\r\n")
        XCTAssertTrue(response.headers.hasPrefix("RTSP/1.0 503 Service Unavailable"))
        XCTAssertTrue(response.headers.contains("Retry-After: 1"))
        XCTAssertEqual(response.body, "")
    }

    func testTCPPlaybackAndTeardown() throws {
        try exerciseServer(tcp: true)
    }

    func testUDPPlaybackAndServerPorts() throws {
        try exerciseServer(tcp: false)
    }

    func testDiagnosticURLRemovesCredentials() {
        XCTAssertEqual(RTSPDiagnosticRedaction.url("rtsp://alice:secret@camera:8554/live/trackID=0?token=private#secret"),
                       "rtsp://camera:8554/live/trackID=0")
        XCTAssertEqual(RTSPDiagnosticRedaction.url("rtsp://camera:8554/live/"), "rtsp://camera:8554/live/")
        XCTAssertEqual(RTSPDiagnosticRedaction.url("not a URL secret"), "<invalid or non-RTSP URL>")
    }

    private func exerciseServer(tcp: Bool) throws {
        let server = RTSPServer(traceResponses: true)
        let diagnostics = DiagnosticCapture()
        let firstWrite = expectation(description: "First RTP write completes locally")
        server.onDiagnosticMessage = { message in
            diagnostics.append(message)
            if message.contains("completed locally") && message.contains("first RTP batch") { firstWrite.fulfill() }
        }
        let ready = expectation(description: "RTSP listener ready")
        server.onStateChange = { running, error in
            if running { ready.fulfill() }
            if let error { XCTFail(error) }
        }
        let port = UInt16.random(in: 30_000...39_999)
        server.start(port: port)
        defer { server.onKeyframeRequest = nil; server.stop() }
        wait(for: [ready], timeout: 5)
        let sps = Data([0x67, 0x42, 0x00, 0x1f])
        let pps = Data([0x68, 0xce, 0x38, 0x80])
        let nal = Data([0x65] + [UInt8](repeating: 0x55, count: 2_000))
        server.publish(nalUnits: [nal], presentationTime: 1, isKeyframe: true, sps: sps, pps: pps)
        server.onKeyframeRequest = {
            server.publish(nalUnits: [nal], presentationTime: 2, isKeyframe: true, sps: sps, pps: pps)
        }
        let control = try TestSocket(type: SOCK_STREAM)
        try control.connect(port: port)
        let url = "rtsp://127.0.0.1:\(port)/live"
        let options = try control.request("OPTIONS \(url) RTSP/1.0\r\nCSeq: 1\r\n\r\n")
        XCTAssertTrue(options.headers.contains("RTSP/1.0 200 OK"))
        XCTAssertTrue(options.headers.contains("Public: OPTIONS, DESCRIBE"))
        let description = try control.request("DESCRIBE \(url) RTSP/1.0\r\nCSeq: 2\r\n\r\n")
        XCTAssertTrue(description.body.contains("a=rtpmap:96 H264/90000"))
        XCTAssertTrue(description.body.contains("sprop-parameter-sets=\(sps.base64EncodedString()),\(pps.base64EncodedString())"))
        XCTAssertTrue(description.headers.contains("Content-Base: \(url)/"))
        let rtp = try TestSocket(type: SOCK_DGRAM)
        let rtcp = try TestSocket(type: SOCK_DGRAM)
        let transport: String
        if tcp {
            transport = "RTP/AVP/TCP;unicast;interleaved=2-3"
        } else {
            transport = "RTP/AVP;unicast;client_port=\(try rtp.bind())-\(try rtcp.bind())"
        }
        let setup = try control.request("SETUP \(url)/trackID=0 RTSP/1.0\r\nCSeq: 3\r\nTransport: \(transport)\r\n\r\n")
        XCTAssertTrue(setup.headers.hasPrefix("RTSP/1.0 200"), setup.headers)
        let sessionLine = try XCTUnwrap(setup.headers.components(separatedBy: "\r\n").first { $0.hasPrefix("Session:") })
        let session = sessionLine.dropFirst("Session: ".count).components(separatedBy: ";")[0]
        if !tcp { XCTAssertTrue(setup.headers.contains("server_port=")) }
        let play = try control.request("PLAY \(url) RTSP/1.0\r\nCSeq: 4\r\nSession: \(session)\r\n\r\n")
        XCTAssertTrue(play.headers.hasPrefix("RTSP/1.0 200"))
        var packets: [Data] = []
        if tcp {
            for _ in 0..<4 {
                let header = try control.readExact(4)
                XCTAssertEqual(Array(header.prefix(2)), [0x24, 2])
                let size = Int(header[2]) * 256 + Int(header[3])
                packets.append(try control.readExact(size))
            }
            let reportHeader = try control.readExact(4)
            XCTAssertEqual(Array(reportHeader.prefix(2)), [0x24, 3])
            let report = try control.readExact(Int(reportHeader[2]) * 256 + Int(reportHeader[3]))
            XCTAssertEqual(report[1], 200)
        } else {
            for _ in 0..<4 { packets.append(try rtp.datagram()) }
            let report = try rtcp.datagram()
            XCTAssertEqual(report[1], 200)
        }
        XCTAssertEqual(Data(packets[0].dropFirst(12)), sps)
        XCTAssertEqual(Data(packets[1].dropFirst(12)), pps)
        XCTAssertEqual(packets.map { $0[1] }, [0x60, 0x60, 0x60, 0xe0])
        XCTAssertEqual(packets[2][12] & 0x1f, 28)
        XCTAssertEqual(packets[2][13] & 0x80, 0x80)
        XCTAssertEqual(packets[3][13] & 0x40, 0x40)
        let teardown = try control.request("TEARDOWN \(url) RTSP/1.0\r\nCSeq: 5\r\nSession: \(session)\r\n\r\n")
        XCTAssertTrue(teardown.headers.hasPrefix("RTSP/1.0 200"))
        if tcp {
            wait(for: [firstWrite], timeout: 3)
            let messages = diagnostics.messages
            let submittedPlay = try XCTUnwrap(messages.firstIndex { $0.contains("submitted response PLAY 200") })
            let submittedVideo = try XCTUnwrap(messages.firstIndex { $0.contains("submitted first RTP batch") })
            let completedPlay = try XCTUnwrap(messages.firstIndex { $0.contains("completed locally") && $0.contains("response PLAY 200") })
            let completedVideo = try XCTUnwrap(messages.firstIndex { $0.contains("completed locally") && $0.contains("first RTP batch") })
            XCTAssertLessThan(submittedPlay, submittedVideo)
            XCTAssertLessThan(completedPlay, completedVideo)
            XCTAssertTrue(messages.contains { $0.contains("response line=") && $0.contains("Content-Base: \(url)/") })
            XCTAssertTrue(messages.contains { $0.contains("response line=") && $0.contains("c=IN IP4 0.0.0.0") })
            XCTAssertTrue(messages.contains { $0.contains("response line=") && $0.contains("a=control:trackID=0") })
            XCTAssertTrue(messages.contains { $0.contains("response line=") && $0.contains("Transport: RTP/AVP/TCP;unicast;interleaved=2-3") })
            XCTAssertTrue(messages.contains { $0.contains("received TEARDOWN, CSeq=5") })
        } else {
            firstWrite.isInverted = true
            wait(for: [firstWrite], timeout: 0.01)
        }
    }
}

private final class DiagnosticCapture {
    private let lock = NSLock()
    private var storage: [String] = []

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(message)
    }
}

private final class TestSocket {
    private let descriptor: Int32

    init(type: Int32) throws {
        descriptor = Darwin.socket(AF_INET, type, 0)
        guard descriptor >= 0 else { throw Self.error() }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { Darwin.close(descriptor) }

    func connect(port: UInt16) throws {
        var address = Self.address(port: port)
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard status == 0 else { throw Self.error() }
    }

    func bind() throws -> UInt16 {
        var address = Self.address(port: 0)
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard status == 0 else { throw Self.error() }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameStatus = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard nameStatus == 0 else { throw Self.error() }
        return UInt16(bigEndian: address.sin_port)
    }

    func request(_ text: String) throws -> (headers: String, body: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes {
                Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            }
            guard sent > 0 else { throw Self.error() }
            offset += sent
        }
        var response = Data()
        while !response.suffix(4).elementsEqual([13, 10, 13, 10]) {
            guard response.count < 65_536 else { throw RTSPParseError.requestTooLarge }
            response.append(try readExact(1))
        }
        let headers = String(decoding: response, as: UTF8.self)
        let line = headers.components(separatedBy: "\r\n").first { $0.hasPrefix("Content-Length:") }
        let length = Int(line?.dropFirst("Content-Length:".count).trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
        return (headers, String(decoding: try readExact(length), as: UTF8.self))
    }

    func readExact(_ size: Int) throws -> Data {
        var result = Data()
        while result.count < size {
            var bytes = [UInt8](repeating: 0, count: size - result.count)
            let received = Darwin.recv(descriptor, &bytes, bytes.count, 0)
            guard received > 0 else { throw Self.error() }
            result.append(contentsOf: bytes.prefix(received))
        }
        return result
    }

    func datagram() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 2_048)
        let received = Darwin.recv(descriptor, &bytes, bytes.count, 0)
        guard received > 0 else { throw Self.error() }
        return Data(bytes.prefix(received))
    }

    private static func address(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    private static func error() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
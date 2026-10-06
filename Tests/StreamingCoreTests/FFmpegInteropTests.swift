#if os(macOS)
import Foundation
import XCTest
@testable import StreamingCore

final class FFmpegInteropTests: XCTestCase {
    func testFFmpegDecodesTCPStream() throws { try decodeStream(transport: "tcp") }
    func testFFmpegDecodesUDPStream() throws { try decodeStream(transport: "udp") }

    private func decodeStream(transport: String) throws {
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":")
        let executable = (directories + ["/opt/homebrew/bin", "/usr/local/bin"]).map {
            URL(fileURLWithPath: $0).appendingPathComponent("ffmpeg")
        }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard let executable else { throw XCTSkip("Install FFmpeg to run decoder interoperability tests.") }
        let fixture = try run(executable, arguments: [
            "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30",
            "-frames:v", "1", "-c:v", "libx264", "-profile:v", "baseline", "-preset", "ultrafast",
            "-tune", "zerolatency", "-f", "h264", "pipe:1"
        ])
        let units = annexBUnits(fixture)
        let sps = try XCTUnwrap(units.first { $0.first.map { $0 & 0x1f == 7 } ?? false })
        let pps = try XCTUnwrap(units.first { $0.first.map { $0 & 0x1f == 8 } ?? false })
        let picture = units.filter { unit in unit.first.map { ![7, 8].contains($0 & 0x1f) } ?? false }
        let server = RTSPServer()
        let ready = expectation(description: "Listener ready for FFmpeg")
        server.onStateChange = { running, error in
            if running { ready.fulfill() }
            if let error { XCTFail(error) }
        }
        let port = UInt16.random(in: 40_000...49_999)
        server.start(port: port)
        defer { server.stop() }
        wait(for: [ready], timeout: 5)
        server.publish(nalUnits: picture, presentationTime: 0, isKeyframe: true, sps: sps, pps: pps)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "test.video-source"))
        var frameNumber = 0
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        timer.setEventHandler {
            frameNumber += 1
            server.publish(nalUnits: picture, presentationTime: Double(frameNumber) / 30,
                           isKeyframe: true, sps: sps, pps: pps)
        }
        timer.resume()
        defer { timer.cancel() }
        let decoded = try run(executable, arguments: [
            "-hide_banner", "-loglevel", "error", "-rtsp_transport", transport, "-timeout", "5000000",
            "-i", "rtsp://127.0.0.1:\(port)/live", "-frames:v", "3", "-f", "framemd5", "pipe:1"
        ])
        let text = String(decoding: decoded, as: UTF8.self)
        XCTAssertTrue(text.contains("#dimensions 0: 320x240"), text)
        let frames = text.components(separatedBy: "\n").filter { !$0.hasPrefix("#") && $0.contains(",") }
        XCTAssertEqual(frames.count, 3, text)
    }

    private func run(_ executable: URL, arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        watchdog.schedule(deadline: .now() + 15)
        watchdog.setEventHandler { if process.isRunning { process.terminate() } }
        watchdog.resume()
        defer { watchdog.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errorData, as: UTF8.self))
        return data
    }

    private func annexBUnits(_ data: Data) -> [Data] {
        let bytes = Array(data)
        var starts: [(prefix: Int, payload: Int)] = []
        var offset = 0
        while offset + 3 <= bytes.count {
            if offset + 4 <= bytes.count && bytes[offset..<offset + 4].elementsEqual([0, 0, 0, 1]) {
                starts.append((offset, offset + 4))
                offset += 4
            } else if bytes[offset..<offset + 3].elementsEqual([0, 0, 1]) {
                starts.append((offset, offset + 3))
                offset += 3
            } else { offset += 1 }
        }
        return starts.enumerated().map { index, start in
            let end = index + 1 < starts.count ? starts[index + 1].prefix : bytes.count
            return Data(bytes[start.payload..<end])
        }
    }
}
#endif
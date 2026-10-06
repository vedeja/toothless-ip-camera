import XCTest
@testable import StreamingCore

final class StreamingCoreTests: XCTestCase {
    func testTransportNegotiation() {
        XCTAssertEqual(RTSPTransport(header: "RTP/AVP/TCP;unicast;interleaved=0-1"), .tcp(rtp: 0, rtcp: 1))
        XCTAssertEqual(RTSPTransport(header: "RTP/AVP;unicast;client_port=5000-5001"), .udp(rtp: 5000, rtcp: 5001))
        for header in ["RTP/AVP;multicast;client_port=5000-5001", "RTP/AVP/TCP;unicast;interleaved=256-257",
                       "RTP/AVP;unicast;client_port=0-1", "RTP/AVP/TCP;unicast;interleaved=1-1"] {
            XCTAssertNil(RTSPTransport(header: header))
        }
    }

    func testFragmentationAndSequenceWrap() {
        var packetizer = RTPPacketizer(sequence: 65_535, ssrc: 0x12345678, maximumPayloadSize: 6)
        let original = Data([0x65, 1, 2, 3, 4, 5, 6, 7, 8, 9])
        let packets = packetizer.packets(nalUnits: [Data([0x67, 0x42]), original], timestamp: 90_000)
        XCTAssertEqual(packets.count, 4)
        XCTAssertEqual(Array(packets[0].prefix(12)), [0x80, 0x60, 0xff, 0xff, 0, 1, 0x5f, 0x90, 0x12, 0x34, 0x56, 0x78])
        XCTAssertEqual(packets[1][2], 0)
        XCTAssertEqual(packets[1][3], 0)
        XCTAssertEqual(Array(packets[1][12..<14]), [0x7c, 0x85])
        XCTAssertEqual(Array(packets[3][12..<14]), [0x7c, 0x45])
        XCTAssertEqual(packets.map { $0[1] }, [0x60, 0x60, 0x60, 0xe0])
        var reconstructed = Data([0x65])
        for packet in packets.dropFirst() { reconstructed.append(packet.dropFirst(14)) }
        XCTAssertEqual(reconstructed, original)
        XCTAssertEqual(packetizer.sequence, 3)
        XCTAssertTrue(packets.allSatisfy { $0.count <= 18 })
    }

    func testSplitAndPipelinedRequestsWithInterleavedRTCP() throws {
        var parser = RTSPRequestParser()
        XCTAssertEqual(try parser.append(Data("DESCRIBE rtsp://host/live RTSP/1.0\r\nCS".utf8)), [])
        let requests = try parser.append(Data("eq: 1\r\n\r\nSETUP rtsp://host/live/trackID=0 RTSP/1.0\r\nCSeq: 2\r\nTransport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n\r\n".utf8))
        XCTAssertEqual(requests.map(\.method), ["DESCRIBE", "SETUP"])
        XCTAssertEqual(requests[1].headers["transport"], "RTP/AVP/TCP;unicast;interleaved=0-1")
        XCTAssertEqual(try parser.append(Data([0x24, 1, 0, 2, 0x80, 201])), [])
        XCTAssertEqual(try parser.append(Data("OPTIONS * RTSP/1.0\r\nCSeq: 3\r\n\r\n".utf8)).count, 1)
    }

    func testInvalidBodyLengthAndMissingSequence() {
        for headers in ["CSeq: 1\r\nContent-Length: -1", "User-Agent: Test"] {
            var parser = RTSPRequestParser()
            XCTAssertThrowsError(try parser.append(Data("OPTIONS * RTSP/1.0\r\n\(headers)\r\n\r\n".utf8)))
        }
    }

    func testSenderReportCounters() {
        var packetizer = RTPPacketizer(sequence: 0, ssrc: 1)
        _ = packetizer.packets(nalUnits: [Data([0x65, 1, 2])], timestamp: 123)
        let report = packetizer.senderReport(timestamp: 123, date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(Array(report.prefix(8)), [0x80, 200, 0, 6, 0, 0, 0, 1])
        XCTAssertEqual(Array(report[16..<28]), [0, 0, 0, 123, 0, 0, 0, 1, 0, 0, 0, 3])
        XCTAssertEqual(report[29], 202)
        XCTAssertEqual(report.count % 4, 0)
    }
}
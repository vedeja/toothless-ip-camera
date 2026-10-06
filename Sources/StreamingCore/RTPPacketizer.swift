import Foundation

public struct RTPPacketizer {
    public private(set) var sequence: UInt16
    public let ssrc: UInt32
    public private(set) var packetCount: UInt32 = 0
    public private(set) var octetCount: UInt32 = 0
    private let maximumPayloadSize: Int

    public init(sequence: UInt16 = .random(in: .min ... .max),
                ssrc: UInt32 = .random(in: 1 ... .max), maximumPayloadSize: Int = 1_200) {
        precondition(maximumPayloadSize >= 3)
        self.sequence = sequence
        self.ssrc = ssrc
        self.maximumPayloadSize = maximumPayloadSize
    }

    public mutating func packets(nalUnits: [Data], timestamp: UInt32) -> [Data] {
        let units = nalUnits.filter { !$0.isEmpty }
        var result: [Data] = []
        for (index, unit) in units.enumerated() {
            let lastUnit = index == units.count - 1
            if unit.count <= maximumPayloadSize {
                result.append(packet(payload: unit, timestamp: timestamp, marker: lastUnit))
                continue
            }
            let bytes = Array(unit)
            let indicator = (bytes[0] & 0xe0) | 28
            let type = bytes[0] & 0x1f
            var offset = 1
            while offset < bytes.count {
                let end = min(offset + maximumPayloadSize - 2, bytes.count)
                let startFlag: UInt8 = offset == 1 ? 0x80 : 0
                let endFlag: UInt8 = end == bytes.count ? 0x40 : 0
                var payload = Data([indicator, type | startFlag | endFlag])
                payload.append(contentsOf: bytes[offset ..< end])
                result.append(packet(payload: payload, timestamp: timestamp,
                                     marker: lastUnit && end == bytes.count))
                offset = end
            }
        }
        return result
    }

    public func senderReport(timestamp: UInt32, date: Date = Date()) -> Data {
        let seconds = date.timeIntervalSince1970 + 2_208_988_800
        var report = Data([0x80, 200, 0, 6])
        report.appendBigEndian(ssrc)
        report.appendBigEndian(UInt32(seconds))
        report.appendBigEndian(UInt32((seconds - floor(seconds)) * 4_294_967_296))
        report.appendBigEndian(timestamp)
        report.appendBigEndian(packetCount)
        report.appendBigEndian(octetCount)
        let name = Array("toothless".utf8)
        var description = Data([0x81, 202, 0, 0])
        description.appendBigEndian(ssrc)
        description.append(contentsOf: [1, UInt8(name.count)])
        description.append(contentsOf: name)
        description.append(0)
        while description.count % 4 != 0 { description.append(0) }
        let length = UInt16(description.count / 4 - 1)
        description[2] = UInt8(length >> 8)
        description[3] = UInt8(length & 0xff)
        report.append(description)
        return report
    }

    private mutating func packet(payload: Data, timestamp: UInt32, marker: Bool) -> Data {
        var result = Data([0x80, marker ? 0xe0 : 0x60])
        result.appendBigEndian(sequence)
        result.appendBigEndian(timestamp)
        result.appendBigEndian(ssrc)
        result.append(payload)
        sequence &+= 1
        packetCount &+= 1
        octetCount &+= UInt32(payload.count)
        return result
    }
}

extension Data {
    mutating func appendBigEndian<Value: FixedWidthInteger>(_ value: Value) {
        var networkValue = value.bigEndian
        Swift.withUnsafeBytes(of: &networkValue) { append(contentsOf: $0) }
    }
}
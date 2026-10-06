import Foundation

public struct RTSPRequest: Equatable {
    public let method: String
    public let uri: String
    public let headers: [String: String]
}

public enum RTSPParseError: Error {
    case malformedRequest
    case requestTooLarge
}

public struct RTSPRequestParser {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [RTSPRequest] {
        buffer.append(data)
        guard buffer.count <= 65_536 else { throw RTSPParseError.requestTooLarge }
        var requests: [RTSPRequest] = []
        while !buffer.isEmpty {
            if buffer.first == 0x24 {
                guard buffer.count >= 4 else { break }
                let bytes = Array(buffer.prefix(4))
                let size = Int(bytes[2]) * 256 + Int(bytes[3])
                guard buffer.count >= size + 4 else { break }
                buffer = Data(buffer.dropFirst(size + 4))
                continue
            }
            guard let delimiter = buffer.range(of: Data("\r\n\r\n".utf8)) else { break }
            guard let text = String(data: buffer[..<delimiter.lowerBound], encoding: .utf8) else {
                throw RTSPParseError.malformedRequest
            }
            let lines = text.components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ")
            guard first.count == 3, first[2] == "RTSP/1.0" else {
                throw RTSPParseError.malformedRequest
            }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { throw RTSPParseError.malformedRequest }
                let key = line[..<colon].lowercased()
                guard headers[key] == nil else { throw RTSPParseError.malformedRequest }
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard let sequence = headers["cseq"], UInt32(sequence) != nil else {
                throw RTSPParseError.malformedRequest
            }
            let bodySize: Int
            if let length = headers["content-length"] {
                guard let parsed = Int(length), parsed >= 0, parsed <= 32_768 else {
                    throw RTSPParseError.malformedRequest
                }
                bodySize = parsed
            } else { bodySize = 0 }
            let consumed = buffer.distance(from: buffer.startIndex, to: delimiter.upperBound) + bodySize
            guard buffer.count >= consumed else { break }
            requests.append(RTSPRequest(method: String(first[0]), uri: String(first[1]), headers: headers))
            buffer = Data(buffer.dropFirst(consumed))
        }
        return requests
    }
}
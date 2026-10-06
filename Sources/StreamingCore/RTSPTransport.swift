import Foundation

enum RTSPTransport: Equatable {
    case tcp(rtp: UInt8, rtcp: UInt8)
    case udp(rtp: UInt16, rtcp: UInt16)

    init?(header: String) {
        let fields = header.lowercased().split(separator: ";").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard fields.contains("unicast"), !fields.contains("multicast") else { return nil }
        func pair(_ name: String) -> [Int]? {
            guard let field = fields.first(where: { $0.hasPrefix(name + "=") }) else { return nil }
            let parts = field.dropFirst(name.count + 1).split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2, parts[0] != parts[1] else { return nil }
            return parts
        }
        if fields.first == "rtp/avp/tcp", let ports = pair("interleaved"),
           ports.allSatisfy({ (0...255).contains($0) }) {
            self = .tcp(rtp: UInt8(ports[0]), rtcp: UInt8(ports[1]))
        } else if ["rtp/avp", "rtp/avp/udp"].contains(fields.first ?? ""),
                  let ports = pair("client_port"), ports.allSatisfy({ (1...65_535).contains($0) }) {
            self = .udp(rtp: UInt16(ports[0]), rtcp: UInt16(ports[1]))
        } else { return nil }
    }
}
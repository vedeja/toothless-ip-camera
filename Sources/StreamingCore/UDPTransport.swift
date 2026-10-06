import Foundation
import Darwin

final class UDPTransport {
    let serverPort: UInt16
    private let rtpSocket: Int32
    private let rtcpSocket: Int32
    private var rtpAddress: Data
    private var rtcpAddress: Data

    init(host: String, rtpPort: UInt16, rtcpPort: UInt16) throws {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var addresses: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(rtpPort), &hints, &addresses) == 0,
              let address = addresses else { throw RTSPServerError.transportUnavailable }
        defer { freeaddrinfo(addresses) }
        let family = address.pointee.ai_family
        rtpAddress = Data(bytes: address.pointee.ai_addr, count: Int(address.pointee.ai_addrlen))
        rtcpAddress = rtpAddress
        rtcpAddress.withUnsafeMutableBytes { bytes in
            if family == AF_INET {
                bytes.bindMemory(to: sockaddr_in.self)[0].sin_port = rtcpPort.bigEndian
            } else {
                bytes.bindMemory(to: sockaddr_in6.self)[0].sin6_port = rtcpPort.bigEndian
            }
        }
        var selected: (Int32, Int32, UInt16)?
        for _ in 0..<20 {
            let port = UInt16.random(in: 10_000...30_000) * 2
            let first = Self.boundSocket(family: family, port: port)
            guard first >= 0 else { continue }
            let second = Self.boundSocket(family: family, port: port + 1)
            guard second >= 0 else { Darwin.close(first); continue }
            selected = (first, second, port)
            break
        }
        guard let selected else { throw RTSPServerError.transportUnavailable }
        rtpSocket = selected.0
        rtcpSocket = selected.1
        serverPort = selected.2
    }

    deinit {
        Darwin.close(rtpSocket)
        Darwin.close(rtcpSocket)
    }

    func send(_ data: Data, isRTCP: Bool = false) {
        let address = isRTCP ? rtcpAddress : rtpAddress
        address.withUnsafeBytes { addressBytes in
            data.withUnsafeBytes { payload in
                _ = Darwin.sendto(isRTCP ? rtcpSocket : rtpSocket, payload.baseAddress, payload.count,
                                  0, addressBytes.baseAddress?.assumingMemoryBound(to: sockaddr.self),
                                  socklen_t(address.count))
            }
        }
    }

    private static func boundSocket(family: Int32, port: UInt16) -> Int32 {
        let descriptor = socket(family, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return -1 }
        var result: Int32
        if family == AF_INET {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        } else {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
        guard result == 0 else { Darwin.close(descriptor); return -1 }
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        return descriptor
    }
}
import Darwin
import Foundation

/// Minimal blocking UDP for LAN protocols (WiZ, SSDP, Wake-on-LAN), run off the main thread.
enum UDP {
    struct Reply: Sendable {
        let address: String
        let data: Data
    }

    /// Sends `payload` to `host:port` (broadcast and multicast allowed) and collects replies for `timeout`.
    /// With `firstReplyOnly`, returns as soon as one reply arrives.
    static func query(
        _ payload: Data,
        host: String,
        port: UInt16,
        timeout: TimeInterval,
        firstReplyOnly: Bool = false
    ) async -> [Reply] {
        await Task.detached(priority: .utility) {
            blockingQuery(payload, host: host, port: port, timeout: timeout, firstReplyOnly: firstReplyOnly)
        }.value
    }

    /// Fire-and-forget send (Wake-on-LAN).
    static func send(_ payload: Data, host: String, port: UInt16) async {
        _ = await query(payload, host: host, port: port, timeout: 0)
    }

    private static func blockingQuery(
        _ payload: Data,
        host: String,
        port: UInt16,
        timeout: TimeInterval,
        firstReplyOnly: Bool
    ) -> [Reply] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var enable: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enable, socklen_t(MemoryLayout<Int32>.size))
        var receiveTimeout = timeval(tv_sec: 0, tv_usec: 150_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return [] }

        let sent = payload.withUnsafeBytes { buffer in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent >= 0, timeout > 0 else { return [] }

        var replies: [Reply] = []
        var buffer = [UInt8](repeating: 0, count: 8192)
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLength)
                }
            }
            guard count > 0 else { continue }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
            let address = String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            replies.append(Reply(address: address, data: Data(buffer[0..<count])))
            if firstReplyOnly { break }
        }
        return replies
    }
}

/// Small persisted settings for devices found on the local network.
enum LocalStore {
    static func load<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    static func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

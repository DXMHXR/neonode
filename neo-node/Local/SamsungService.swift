import Foundation

/// Samsung Tizen TVs and Smart Monitors over the local network: status from the REST API on port 8001,
/// remote keys over the WebSocket API on port 8002 (approved once on the screen), power-on by Wake-on-LAN.
actor SamsungService: TuyaService {
    static let prefix = "samsung:"
    private static let screensKey = "samsungScreens"

    struct Screen: Codable, Sendable {
        var id: String
        var ip: String
        var mac: String?
        var name: String
        var model: String?
        var token: String?

        var isMonitor: Bool {
            (model ?? "").uppercased().hasPrefix("LS") || name.localizedCaseInsensitiveContains("monitor")
        }
    }

    /// Keyed by the screen's own id.
    private var screens: [String: Screen] = LocalStore.load(SamsungService.screensKey, as: [String: Screen].self) ?? [:]
    private var lastDiscovery: Date = .distantPast

    static let remoteKeys = ["KEY_VOLDOWN", "KEY_VOLUP", "KEY_MUTE", "KEY_SOURCE", "KEY_HOME"]

    // MARK: - TuyaService

    func devices() async throws -> [TuyaDevice] {
        if screens.isEmpty || Date.now.timeIntervalSince(lastDiscovery) > 600 {
            await discover()
        }
        var result: [TuyaDevice] = []
        for screen in screens.values {
            let info = await Self.info(at: screen.ip)
            if let info { merge(info, ip: screen.ip) }
            let current = screens[screen.id] ?? screen
            // A screen in deep standby doesn't answer; it stays listed so Wake-on-LAN can turn it on.
            let isOn = info?.powerState.map { $0 == "on" } ?? (info != nil)
            result.append(TuyaDevice(
                id: Self.prefix + current.id,
                name: current.name,
                category: current.isMonitor ? "monitor" : "tv",
                online: true,
                productName: current.model ?? "Samsung",
                status: [.init(code: "switch", value: .bool(isOn))]
            ))
        }
        save()
        return result
    }

    func specification(of deviceID: String) async throws -> TuyaSpecification {
        let keys = (try? JSONSerialization.data(withJSONObject: ["range": Self.remoteKeys])) ?? Data()
        return TuyaSpecification(functions: [
            TuyaFunction(code: "switch", type: "Boolean", values: "{}"),
            TuyaFunction(code: "remote_key", type: "Keys", values: String(decoding: keys, as: UTF8.self)),
        ])
    }

    func send(_ commands: [TuyaCommand], to deviceID: String) async throws {
        let id = String(deviceID.dropFirst(Self.prefix.count))
        guard let screen = screens[id] else { throw TuyaError.api(code: -1, message: "Screen not found on this network") }
        for command in commands {
            switch command.code {
            case "switch":
                let wantOn = command.value.boolValue ?? false
                let info = await Self.info(at: screen.ip)
                let isOn = info?.powerState.map { $0 == "on" } ?? (info != nil)
                if wantOn {
                    if let mac = screen.mac { await Self.wake(mac: mac) }
                    if info != nil, !isOn { try await sendKey("KEY_POWER", to: screen) } // network standby
                } else if isOn {
                    try await sendKey("KEY_POWER", to: screen)
                }
            case "remote_key":
                if let key = command.value.stringValue { try await sendKey(key, to: screen) }
            default:
                continue
            }
        }
    }

    // MARK: - Discovery

    /// Finds Samsung screens with SSDP, then reads each one's details from its REST API.
    func discover() async {
        lastDiscovery = .now
        let search = """
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: "ssdp:discover"\r
        MX: 2\r
        ST: urn:samsung.com:device:RemoteControlReceiver:1\r
        \r

        """
        let replies = await UDP.query(Data(search.utf8), host: "239.255.255.250", port: 1900, timeout: 2.5)
        for ip in Set(replies.map(\.address)) {
            if let info = await Self.info(at: ip) { merge(info, ip: ip) }
        }
        save()
    }

    /// Adds a screen by IP address when discovery can't see it.
    func add(ip: String) async throws {
        switch await Self.probe(ip) {
        case .found(let info):
            merge(info, ip: ip)
            save()
        case .blocked:
            throw TuyaError.api(code: -1, message: Self.blockedMessage)
        case .noAnswer(let reason):
            throw TuyaError.api(code: -1, message: "\(ip) didn't answer on Samsung's remote-control port (8001): \(reason). Some Smart Monitors only offer it on the Smart Hub screen, not while showing a computer.")
        }
    }

    static let blockedMessage = "macOS is blocking neo-node from your Wi‑Fi devices. Turn on neo-node in System Settings › Privacy & Security › Local Network, then try again."

    private func merge(_ info: Info, ip: String) {
        var screen = screens[info.id] ?? Screen(id: info.id, ip: ip, name: info.name)
        screen.ip = ip
        screen.name = info.name
        screen.model = info.model ?? screen.model
        screen.mac = info.mac ?? screen.mac
        screens[info.id] = screen
    }

    private func save() {
        LocalStore.save(screens, key: Self.screensKey)
    }

    // MARK: - REST status

    struct Info: Sendable {
        let id: String
        let name: String
        let model: String?
        let mac: String?
        let powerState: String?
    }

    enum Probe: Sendable {
        case found(Info)
        case blocked
        case noAnswer(String)
    }

    static func info(at ip: String) async -> Info? {
        if case .found(let info) = await probe(ip) { return info }
        return nil
    }

    /// Reads the screen's REST info, telling "macOS blocked us" apart from "nothing answered".
    static func probe(_ ip: String) async -> Probe {
        guard let url = URL(string: "http://\(ip):8001/api/v2/") else { return .noAnswer("bad address") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            return isLocalNetworkDenied(error) ? .blocked : .noAnswer(error.localizedDescription)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = json["device"] as? [String: Any] else { return .noAnswer("not a Samsung screen") }
        let rawName = (device["name"] as? String) ?? (json["name"] as? String) ?? "Samsung TV"
        return .found(Info(
            id: (device["id"] as? String) ?? (device["wifiMac"] as? String) ?? ip,
            name: rawName.replacingOccurrences(of: "[TV] ", with: ""),
            model: device["modelName"] as? String,
            mac: device["wifiMac"] as? String,
            powerState: device["PowerState"] as? String
        ))
    }

    /// Local Network privacy denials surface as "No route to host" or an unsatisfied path naming it.
    static func isLocalNetworkDenied(_ error: Error) -> Bool {
        let text = String(describing: error)
        if text.contains("Local network prohibited") { return true }
        var current: NSError? = error as NSError
        while let ns = current {
            if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EHOSTUNREACH) { return true }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    // MARK: - Wake-on-LAN

    static func wake(mac: String) async {
        let bytes = mac.split(whereSeparator: { $0 == ":" || $0 == "-" }).compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: bytes) }
        for _ in 0..<3 {
            await UDP.send(packet, host: "255.255.255.255", port: 9)
            await UDP.send(packet, host: "255.255.255.255", port: 7)
        }
    }

    // MARK: - Remote keys (WebSocket)

    private func sendKey(_ key: String, to screen: Screen) async throws {
        let token = try await SamsungRemote.send(key: key, ip: screen.ip, token: screen.token)
        if let token, token != screen.token {
            screens[screen.id]?.token = token
            save()
        }
    }
}

/// One-shot connection to a screen's remote-control WebSocket. The first connection makes the screen
/// ask "Allow neo-node?"; accepting returns a token that skips the prompt afterwards.
final class SamsungRemote: NSObject, URLSessionDelegate, @unchecked Sendable {
    private static let appName = Data("neo-node".utf8).base64EncodedString()

    static func send(key: String, ip: String, token: String?) async throws -> String? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = ip
        components.port = 8002
        components.path = "/api/v2/channels/samsung.remote.control"
        components.queryItems = [URLQueryItem(name: "name", value: appName)]
            + (token.map { [URLQueryItem(name: "token", value: $0)] } ?? [])
        guard let url = components.url else { throw TuyaError.badURL }

        let delegate = SamsungRemote()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let socket = session.webSocketTask(with: url)
        socket.resume()

        // Waits up to ~30 s for the user to accept the prompt on the screen.
        var newToken: String?
        let deadline = Date.now.addingTimeInterval(30)
        connecting: while Date.now < deadline {
            let message = try await socket.receive()
            guard case .string(let text) = message,
                  let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
            switch json["event"] as? String {
            case "ms.channel.connect":
                newToken = (json["data"] as? [String: Any])?["token"] as? String
                break connecting
            case "ms.channel.unauthorized":
                throw TuyaError.api(code: -1, message: "The screen declined neo-node. Allow it under Settings › Connection › Device Connection Manager.")
            case "ms.channel.timeOut":
                throw TuyaError.api(code: -1, message: "No answer on the screen. Try again and choose Allow.")
            default:
                continue
            }
        }

        let command: [String: Any] = [
            "method": "ms.remote.control",
            "params": ["Cmd": "Click", "DataOfCmd": key, "Option": "false", "TypeOfRemote": "SendRemoteKey"],
        ]
        let data = try JSONSerialization.data(withJSONObject: command)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        try await Task.sleep(for: .milliseconds(250))
        socket.cancel(with: .normalClosure, reason: nil)
        return newToken
    }

    /// The screen uses a self-signed certificate; trust it only for local addresses.
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let host = challenge.protectionSpace.host
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              Self.isPrivateAddress(host) else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }

    static func isPrivateAddress(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10
            || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 172 && (16...31).contains(parts[1]))
    }
}

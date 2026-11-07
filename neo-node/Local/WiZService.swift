import Foundation

/// Philips WiZ lights over the local network: JSON over UDP port 38899, no account.
/// Devices are presented as Tuya-style lights (`switch_led`, `bright_value`, `temp_value`, `scene`)
/// so the grid and detail views work unchanged.
actor WiZService: TuyaService {
    static let prefix = "wiz:"
    private static let port: UInt16 = 38899
    private static let hostsKey = "wizHosts"

    /// MAC → last known IP address.
    private var hosts: [String: String] = LocalStore.load(WiZService.hostsKey, as: [String: String].self) ?? [:]

    func devices() async throws -> [TuyaDevice] {
        let request = Data(#"{"method":"getPilot","params":{}}"#.utf8)
        async let broadcast = UDP.query(request, host: "255.255.255.255", port: Self.port, timeout: 1.2)
        var replies = await broadcast
        // Lights that missed the broadcast: ask the addresses we know directly.
        let answered = Set(replies.map(\.address))
        for ip in Set(hosts.values) where !answered.contains(ip) {
            replies += await UDP.query(request, host: ip, port: Self.port, timeout: 0.6, firstReplyOnly: true)
        }

        var devices: [String: TuyaDevice] = [:]
        for reply in replies {
            guard let pilot = Pilot(reply.data), let mac = pilot.mac else { continue }
            hosts[mac] = reply.address
            devices[mac] = pilot.device(mac: mac)
        }
        // Known lights that didn't answer stay listed as offline.
        for mac in hosts.keys where devices[mac] == nil {
            devices[mac] = TuyaDevice(
                id: Self.prefix + mac, name: Self.defaultName(mac), category: "dj", online: false,
                productName: "WiZ", status: [.init(code: "switch_led", value: .bool(false))]
            )
        }
        LocalStore.save(hosts, key: Self.hostsKey)
        return Array(devices.values)
    }

    func specification(of deviceID: String) async throws -> TuyaSpecification {
        TuyaSpecification(functions: [
            TuyaFunction(code: "switch_led", type: "Boolean", values: "{}"),
            TuyaFunction(code: "bright_value", type: "Integer", values: #"{"min":10,"max":100,"scale":0,"step":1}"#),
            TuyaFunction(code: "temp_value", type: "Integer", values: #"{"min":2200,"max":6500,"scale":0,"step":100}"#),
            TuyaFunction(code: "scene", type: "Enum", values: Self.sceneRangeJSON),
        ])
    }

    func send(_ commands: [TuyaCommand], to deviceID: String) async throws {
        let mac = String(deviceID.dropFirst(Self.prefix.count))
        guard let ip = hosts[mac] else { throw TuyaError.api(code: -1, message: "WiZ light not found on this network") }

        var params: [String: Any] = [:]
        for command in commands {
            switch command.code {
            case "switch_led": params["state"] = command.value.boolValue ?? false
            case "bright_value": params["dimming"] = Int(command.value.doubleValue ?? 100)
            case "temp_value": params["temp"] = Int(command.value.doubleValue ?? 2700)
            case "scene":
                let name = command.value.stringValue ?? ""
                if let id = Self.scenes.first(where: { $0.name == name })?.id {
                    params["sceneId"] = id
                } else {
                    params["temp"] = 2700 // "None": back to plain white
                }
            default: continue
            }
        }
        guard !params.isEmpty else { return }
        if params["state"] == nil, params["dimming"] != nil || params["temp"] != nil || params["sceneId"] != nil {
            params["state"] = true
        }
        let body = try JSONSerialization.data(withJSONObject: ["id": 1, "method": "setPilot", "params": params])

        for _ in 0..<2 {
            let replies = await UDP.query(body, host: ip, port: Self.port, timeout: 1, firstReplyOnly: true)
            if let reply = replies.first,
               let json = try? JSONSerialization.jsonObject(with: reply.data) as? [String: Any],
               json["error"] == nil {
                return
            }
        }
        throw TuyaError.api(code: -1, message: "The WiZ light didn't respond")
    }

    /// Raw replies from every known light (diagnostics: what a light reports about itself and its mode).
    func diagnostics() async -> String {
        var lines: [String] = []
        for (mac, ip) in hosts.sorted(by: { $0.key < $1.key }) {
            lines.append("\(mac) @ \(ip)")
            for method in ["getPilot", "getSystemConfig", "getModelConfig", "getUserConfig"] {
                let request = Data(#"{"method":"\#(method)","params":{}}"#.utf8)
                let reply = await UDP.query(request, host: ip, port: Self.port, timeout: 1, firstReplyOnly: true).first
                lines.append("\(method): " + (reply.map { String(decoding: $0.data, as: UTF8.self) } ?? "no reply"))
            }
        }
        return lines.isEmpty ? "No WiZ lights known yet" : lines.joined(separator: "\n")
    }

    // MARK: - Pilot (light state)

    private struct Pilot {
        let mac: String?
        let state: Bool
        let dimming: Int?
        let temp: Int?
        let sceneID: Int?
        let hasColor: Bool

        init?(_ data: Data) {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any] else { return nil }
            mac = result["mac"] as? String
            state = result["state"] as? Bool ?? false
            dimming = result["dimming"] as? Int
            temp = result["temp"] as? Int
            sceneID = result["sceneId"] as? Int
            hasColor = result["r"] != nil
        }

        func device(mac: String) -> TuyaDevice {
            var status: [TuyaStatus] = [.init(code: "switch_led", value: .bool(state))]
            if let dimming { status.append(.init(code: "bright_value", value: .int(dimming))) }
            if let temp { status.append(.init(code: "temp_value", value: .int(temp))) }
            let scene = WiZService.scenes.first { $0.id == sceneID }?.name ?? "None"
            status.append(.init(code: "scene", value: .string(scene)))
            return TuyaDevice(
                id: WiZService.prefix + mac, name: WiZService.defaultName(mac), category: "dj", online: true,
                productName: "WiZ", status: status
            )
        }
    }

    static func defaultName(_ mac: String) -> String {
        "WiZ Light \(mac.suffix(4).uppercased())"
    }

    static let scenes: [(id: Int, name: String)] = [
        (1, "Ocean"), (2, "Romance"), (3, "Sunset"), (4, "Party"), (5, "Fireplace"), (6, "Cozy"),
        (7, "Forest"), (8, "Pastel colors"), (9, "Wake up"), (10, "Bedtime"), (11, "Warm white"),
        (12, "Daylight"), (13, "Cool white"), (14, "Night light"), (15, "Focus"), (16, "Relax"),
        (17, "True colors"), (18, "TV time"), (19, "Plant growth"), (20, "Spring"), (21, "Summer"),
        (22, "Fall"), (23, "Deep dive"), (24, "Jungle"), (25, "Mojito"), (26, "Club"), (27, "Christmas"),
        (28, "Halloween"), (29, "Candlelight"), (30, "Golden white"), (31, "Pulse"), (32, "Steampunk"),
    ]

    private static var sceneRangeJSON: String {
        let names = ["None"] + scenes.map(\.name)
        let data = (try? JSONSerialization.data(withJSONObject: ["range": names])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

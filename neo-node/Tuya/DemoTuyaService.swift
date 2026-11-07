import Foundation

/// In-memory devices for `-demo` launches (UI work without a Tuya account).
actor DemoTuyaService: TuyaService {
    private var store: [TuyaDevice] = [
        TuyaDevice(id: "d1", name: "Ceiling Light", category: "dj", online: true, status: [
            .init(code: "switch_led", value: .bool(true)),
            .init(code: "work_mode", value: .string("white")),
            .init(code: "bright_value_v2", value: .int(720)),
            .init(code: "temp_value_v2", value: .int(400)),
            .init(code: "colour_data_v2", value: .string(#"{"h":275,"s":800,"v":1000}"#)),
        ]),
        TuyaDevice(id: "d2", name: "Desk Lamp", category: "dj", online: true, status: [
            .init(code: "switch_led", value: .bool(false)),
            .init(code: "bright_value_v2", value: .int(300)),
        ]),
        TuyaDevice(id: "d3", name: "Coffee Maker", category: "cz", online: true, status: [
            .init(code: "switch_1", value: .bool(true)),
        ]),
        TuyaDevice(id: "d4", name: "Ceiling Fan", category: "fs", online: true, status: [
            .init(code: "switch", value: .bool(false)),
        ]),
        TuyaDevice(id: "d5", name: "Air Conditioner", category: "kt", online: true, status: [
            .init(code: "switch", value: .bool(true)),
        ]),
        TuyaDevice(id: "c1", name: "Front Door Cam", category: "sp", online: true, status: [
            .init(code: "basic_private", value: .bool(false)),
            .init(code: "ptz_control", value: .string("0")),
            .init(code: "basic_nightvision", value: .string("0")),
            .init(code: "motion_switch", value: .bool(true)),
        ]),
        TuyaDevice(id: "c2", name: "Garage Cam", category: "sp", online: true, status: [
            .init(code: "basic_private", value: .bool(false)),
            .init(code: "record_switch", value: .bool(true)),
        ]),
        // Stand-ins for Wi‑Fi devices (IDs carry the WiZ / Samsung prefixes, so they show "Local only").
        TuyaDevice(id: "wiz:demo-ambient", name: "Ambient TV Light", category: "dj", online: true, productName: "WiZ", status: [
            .init(code: "switch_led", value: .bool(true)),
            .init(code: "bright_value", value: .int(60)),
            .init(code: "temp_value", value: .int(2700)),
            .init(code: "scene", value: .string("TV time")),
        ]),
        TuyaDevice(id: "samsung:demo-tv", name: "Living Room TV", category: "tv", online: true, productName: "Samsung", status: [
            .init(code: "switch", value: .bool(true)),
        ]),
        TuyaDevice(id: "samsung:demo-monitor", name: "Office Monitor", category: "monitor", online: true, productName: "Samsung", status: [
            .init(code: "switch", value: .bool(false)),
        ]),
        TuyaDevice(id: "d7", name: "Desk Light Strip", category: "dd", online: true, status: [
            .init(code: "switch_led", value: .bool(true)),
            .init(code: "work_mode", value: .string("colour")),
            .init(code: "bright_value_v2", value: .int(500)),
            .init(code: "colour_data_v2", value: .string(#"{"h":200,"s":850,"v":900}"#)),
        ]),
        TuyaDevice(id: "d6", name: "Garden Lights", category: "dd", online: false, status: [
            .init(code: "switch_led", value: .bool(false)),
        ]),
    ]

    private let roomByDevice: [String: TuyaRoom] = {
        let living = TuyaRoom(id: "r1", name: "Living Room", displayOrder: 0)
        let bedroom = TuyaRoom(id: "r2", name: "Bedroom", displayOrder: 1)
        let kitchen = TuyaRoom(id: "r3", name: "Kitchen", displayOrder: 2)
        let office = TuyaRoom(id: "r4", name: "Office Room", displayOrder: 3)
        return [
            "d1": living, "d5": living, "c1": living, "wiz:demo-ambient": living, "samsung:demo-tv": living,
            "d2": bedroom, "d4": bedroom, "d3": kitchen, "c2": kitchen,
            "samsung:demo-monitor": office, "d7": office,
        ]
    }()

    func rooms(of deviceIDs: [String]) async -> [String: TuyaRoom] {
        roomByDevice.filter { deviceIDs.contains($0.key) }
    }

    func streamURL(of deviceID: String) async throws -> URL {
        // Apple's public HLS sample stands in for a camera feed.
        URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8")!
    }

    func devices() async throws -> [TuyaDevice] {
        try await Task.sleep(for: .milliseconds(250))
        return store
    }

    func specification(of deviceID: String) async throws -> TuyaSpecification {
        if deviceID.hasPrefix(WiZService.prefix) { return try await WiZService().specification(of: deviceID) }
        if deviceID.hasPrefix(SamsungService.prefix) { return try await SamsungService().specification(of: deviceID) }
        guard let device = store.first(where: { $0.id == deviceID }) else { return TuyaSpecification(functions: []) }
        var functions: [TuyaFunction] = device.status.compactMap { status in
            switch status.code {
            case "bright_value_v2", "temp_value_v2":
                TuyaFunction(code: status.code, type: "Integer", values: #"{"min":10,"max":1000,"scale":0,"step":1}"#)
            case "colour_data_v2":
                TuyaFunction(code: status.code, type: "Json", values: #"{"h":{"min":0,"max":360},"s":{"min":0,"max":1000},"v":{"min":0,"max":1000}}"#)
            case "work_mode":
                TuyaFunction(code: status.code, type: "Enum", values: #"{"range":["white","colour","scene","music"]}"#)
            default:
                status.value.boolValue != nil ? TuyaFunction(code: status.code, type: "Boolean", values: "{}") : nil
            }
        }
        if device.category == "cz" {
            functions.append(TuyaFunction(code: "child_lock", type: "Boolean", values: "{}"))
        }
        return TuyaSpecification(functions: functions)
    }

    func send(_ commands: [TuyaCommand], to deviceID: String) async throws {
        try await Task.sleep(for: .milliseconds(200))
        guard let index = store.firstIndex(where: { $0.id == deviceID }) else { return }
        for command in commands { store[index].setValue(command.value, for: command.code) }
    }
}

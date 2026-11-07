import SwiftUI

/// Symbols, tints and labels derived from Tuya category codes and data-point codes.
extension TuyaDevice {
    var symbol: String {
        switch category {
        case "dj", "xdd", "fwd", "tgq", "tyndj": "lightbulb"
        case "dd", "dc": "light.strip.2"
        case "cz", "pc": "powerplug"
        case "kg", "tdq", "cjkg", "kgq": "lightswitch.on"
        case "fs", "fsd": "fan"
        case "kt", "ktkzq": "air.conditioner.horizontal"
        case "cl", "clkg": "blinds.horizontal.closed"
        case "qn": "heater.vertical"
        case "jsq": "humidifier"
        case "cs": "dehumidifier"
        case "kj": "air.purifier"
        case "sd": "vacuum"
        case "sp", "sxj", "dghsxj": "web.camera"
        case "tv": "tv"
        case "monitor": "display"
        case "wk", "wsdcg": "thermometer.medium"
        default: "switch.2"
        }
    }

    var tint: Color {
        switch category {
        case "dj", "xdd", "fwd", "tgq", "tyndj", "dd", "dc": .orange
        case "cz", "pc", "kg", "tdq", "cjkg", "kgq": .green
        case "fs", "fsd", "kj": .teal
        case "kt", "ktkzq", "jsq", "cs": .blue
        case "tv", "monitor": .indigo
        case "qn": .red
        default: .accentColor
        }
    }

    var kind: String {
        switch category {
        case "dj", "xdd", "fwd", "tgq", "tyndj": "Light"
        case "dd", "dc": "Light strip"
        case "cz", "pc": "Plug"
        case "kg", "tdq", "cjkg", "kgq": "Switch"
        case "fs", "fsd": "Fan"
        case "kt", "ktkzq": "Air conditioner"
        case "cl", "clkg": "Curtain"
        case "qn": "Heater"
        case "sp", "sxj", "dghsxj": "Camera"
        case "tv": "TV"
        case "monitor": "Monitor"
        case "kj": "Air purifier"
        default: productName ?? "Device"
        }
    }

    var stateText: String {
        guard online else { return "Offline" }
        if isCamera { return isPrivacyModeOn ? "Privacy mode" : "Live view" }
        guard powerCode != nil else { return kind }
        return isOn ? "On" : "Off"
    }
}

enum DataPointLabel {
    static func title(for code: String) -> String {
        switch code {
        case "switch_led": return "Light"
        case "switch", "power": return "Power"
        case "bright_value", "bright_value_v2": return "Brightness"
        case "temp_value", "temp_value_v2": return "Warmth"
        case "work_mode": return "Mode"
        case "child_lock": return "Child lock"
        case "light_mode": return "Indicator"
        case "relay_status": return "After power loss"
        case "scene": return "Scene"
        case "tv_sync": return "TV sync"
        case "remote_key": return "Remote"
        case "switch_backlight": return "Backlight"
        default:
            if code.hasPrefix("switch_"), let n = Int(code.dropFirst("switch_".count)) { return "Switch \(n)" }
            return humanize(code.replacingOccurrences(of: "_v2", with: ""))
        }
    }

    static func humanize(_ raw: String) -> String {
        let words = raw.split(separator: "_").joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// A control the detail view can render for one data point.
enum DeviceControl: Identifiable {
    case toggle(code: String)
    case slider(code: String, range: TuyaFunction.IntegerRange)
    case picker(code: String, options: [String])
    case buttons(code: String, keys: [String])
    /// One-of-several modes shown as icon buttons (WiZ TV sync); the first option means "off".
    case modes(code: String, options: [String])

    var id: String {
        switch self {
        case .toggle(let code), .slider(let code, _), .picker(let code, _), .buttons(let code, _), .modes(let code, _): code
        }
    }

    static func controls(for device: TuyaDevice, specification: TuyaSpecification?) -> [DeviceControl] {
        // While a WiZ light follows the TV, warmth doesn't apply.
        let syncing = (device.value(for: "tv_sync")?.stringValue).map { $0 != "Off" } ?? false
        let skipped: (String) -> Bool = { code in
            code == device.powerCode || code.contains("countdown") || code.contains("timer")
                || (syncing && code.hasPrefix("temp_value"))
        }
        guard let functions = specification?.functions, !functions.isEmpty else {
            return device.status
                .filter { $0.value.boolValue != nil && !skipped($0.code) }
                .map { .toggle(code: $0.code) }
        }
        let controls: [DeviceControl] = functions.compactMap { function in
            guard !skipped(function.code) else { return nil }
            switch function.type.lowercased() {
            case "boolean":
                return .toggle(code: function.code)
            case "integer":
                guard let range = function.integerRange, range.max > range.min else { return nil }
                return .slider(code: function.code, range: range)
            case "enum":
                guard let options = function.enumRange?.range, options.count > 1 else { return nil }
                return .picker(code: function.code, options: options)
            case "modes":
                guard let options = function.enumRange?.range, options.count > 1 else { return nil }
                return .modes(code: function.code, options: options)
            case "keys":
                guard let keys = function.enumRange?.range, !keys.isEmpty else { return nil }
                return .buttons(code: function.code, keys: keys)
            default:
                return nil
            }
        }
        // Mode first, then sliders, then the remaining switches.
        return controls.sorted { $0.order < $1.order }
    }

    private var order: Int {
        switch self {
        case .modes: -2
        case .buttons: -1
        case .picker: 0
        case .slider: 1
        case .toggle: 2
        }
    }
}

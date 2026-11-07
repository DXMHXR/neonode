import Foundation

/// A Tuya data-point value: status values and command values are loosely typed JSON scalars.
enum JSONValue: Codable, Sendable, Hashable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else { self = .null } // objects/arrays are not controllable here
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

struct TuyaStatus: Codable, Sendable, Hashable {
    let code: String
    var value: JSONValue
}

struct TuyaCommand: Encodable, Sendable {
    let code: String
    let value: JSONValue
}

struct TuyaDevice: Identifiable, Sendable, Hashable, Decodable {
    let id: String
    var name: String
    var category: String
    var online: Bool
    var productName: String?
    var status: [TuyaStatus]

    enum CodingKeys: String, CodingKey {
        case id, name, category, online, status
        case productName = "product_name"
    }

    init(id: String, name: String, category: String, online: Bool, productName: String? = nil, status: [TuyaStatus]) {
        self.id = id
        self.name = name
        self.category = category
        self.online = online
        self.productName = productName
        self.status = status
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Device"
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        online = try c.decodeIfPresent(Bool.self, forKey: .online) ?? false
        productName = try c.decodeIfPresent(String.self, forKey: .productName)
        status = try c.decodeIfPresent([TuyaStatus].self, forKey: .status) ?? []
    }

    func value(for code: String) -> JSONValue? {
        status.first { $0.code == code }?.value
    }

    mutating func setValue(_ value: JSONValue, for code: String) {
        if let index = status.firstIndex(where: { $0.code == code }) {
            status[index].value = value
        } else {
            status.append(TuyaStatus(code: code, value: value))
        }
    }

    /// The data point that turns the whole device on or off.
    var powerCode: String? {
        let preferred = ["switch_led", "switch", "switch_1", "power", "switch_on"]
        if let code = preferred.first(where: { value(for: $0)?.boolValue != nil }) { return code }
        return status.first { $0.code.hasPrefix("switch") && $0.value.boolValue != nil }?.code
    }

    var isOn: Bool {
        guard let powerCode else { return false }
        return value(for: powerCode)?.boolValue ?? false
    }
}

struct TuyaRoom: Decodable, Sendable, Hashable {
    let id: String
    let name: String
    let displayOrder: Int

    enum CodingKeys: String, CodingKey { case id, name, displayOrder }

    init(id: String, name: String, displayOrder: Int = 0) {
        self.id = id
        self.name = name
        self.displayOrder = displayOrder
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let number = try? c.decode(Int64.self, forKey: .id) {
            id = String(number)
        } else {
            id = try c.decode(String.self, forKey: .id)
        }
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Room"
        displayOrder = (try? c.decodeIfPresent(Int.self, forKey: .displayOrder)) ?? 0
    }
}

struct DevicePage: Decodable, Sendable {
    let devices: [TuyaDevice]
    let hasMore: Bool?
    let lastRowKey: String?

    enum CodingKeys: String, CodingKey {
        case devices
        case hasMore = "has_more"
        case lastRowKey = "last_row_key"
    }
}

struct TuyaToken: Decodable, Sendable {
    let accessToken: String
    let expireTime: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expireTime = "expire_time"
    }
}

struct TuyaSpecification: Decodable, Sendable, Hashable {
    let functions: [TuyaFunction]

    init(functions: [TuyaFunction]) { self.functions = functions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        functions = try c.decodeIfPresent([TuyaFunction].self, forKey: .functions) ?? []
    }

    enum CodingKeys: String, CodingKey { case functions }
}

struct TuyaFunction: Decodable, Sendable, Hashable {
    let code: String
    let type: String
    let values: String

    struct IntegerRange: Decodable, Sendable, Hashable {
        let min: Int
        let max: Int
        let scale: Int?
        let step: Int?
    }

    struct EnumRange: Decodable, Sendable, Hashable {
        let range: [String]
    }

    var integerRange: IntegerRange? {
        try? JSONDecoder().decode(IntegerRange.self, from: Data(values.utf8))
    }

    var enumRange: EnumRange? {
        try? JSONDecoder().decode(EnumRange.self, from: Data(values.utf8))
    }
}

struct TuyaEnvelope<Result: Decodable>: Decodable {
    let success: Bool
    let result: Result?
    let code: Int?
    let msg: String?
}

enum TuyaError: LocalizedError {
    case api(code: Int, message: String)
    case http(Int)
    case badURL

    var errorDescription: String? {
        switch self {
        case .api(let code, let message): code == -1 ? message : "\(message) (\(code))"
        case .http(let status): "Tuya returned HTTP \(status)"
        case .badURL: "Invalid Tuya endpoint"
        }
    }
}

import CryptoKit
import Foundation

enum TuyaRegion: String, Codable, CaseIterable, Sendable, Identifiable {
    case china, westernAmerica, easternAmerica, centralEurope, westernEurope, india, singapore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .china: "China"
        case .westernAmerica: "Western America"
        case .easternAmerica: "Eastern America"
        case .centralEurope: "Central Europe"
        case .westernEurope: "Western Europe"
        case .india: "India"
        case .singapore: "Singapore"
        }
    }

    var host: String {
        switch self {
        case .china: "openapi.tuyacn.com"
        case .westernAmerica: "openapi.tuyaus.com"
        case .easternAmerica: "openapi-ueaz.tuyaus.com"
        case .centralEurope: "openapi.tuyaeu.com"
        case .westernEurope: "openapi-weaz.tuyaeu.com"
        case .india: "openapi.tuyain.com"
        case .singapore: "openapi-sg.iotbing.com"
        }
    }
}

struct TuyaCredentials: Codable, Sendable, Equatable {
    var accessID: String
    var accessSecret: String
    var region: TuyaRegion
}

/// How neo-node is signed in.
enum TuyaAccount: Codable, Sendable, Equatable {
    case smartLife(SmartLifeSession)
    case cloudProject(TuyaCredentials)
}

protocol TuyaService: Sendable {
    func devices() async throws -> [TuyaDevice]
    func specification(of deviceID: String) async throws -> TuyaSpecification
    func send(_ commands: [TuyaCommand], to deviceID: String) async throws
    /// Room of each device, keyed by device ID; devices without a room are left out.
    func rooms(of deviceIDs: [String]) async -> [String: TuyaRoom]
    /// A fresh HLS live-stream URL for a camera (they expire, so allocate one per playback).
    func streamURL(of deviceID: String) async throws -> URL
}

extension TuyaService {
    func rooms(of deviceIDs: [String]) async -> [String: TuyaRoom] { [:] }

    func streamURL(of deviceID: String) async throws -> URL {
        throw TuyaError.api(code: -1, message: "This device has no live stream")
    }
}

struct StreamAllocation: Decodable, Sendable {
    let url: String
}

struct StreamRequest: Encodable, Sendable {
    let type: String
}

/// Tuya Cloud OpenAPI client (simple-mode token, HMAC-SHA256 request signing).
actor TuyaClient: TuyaService {
    private let credentials: TuyaCredentials
    private var token: (value: String, expiry: Date)?
    private let decoder = JSONDecoder()

    init(credentials: TuyaCredentials) {
        self.credentials = credentials
    }

    func devices() async throws -> [TuyaDevice] {
        var all: [TuyaDevice] = []
        var lastRowKey: String?
        repeat {
            var query = ["size": "100"]
            if let lastRowKey { query["last_row_key"] = lastRowKey }
            let page: DevicePage = try await perform("GET", "/v1.0/iot-01/associated-users/devices", query: query)
            all += page.devices
            lastRowKey = page.hasMore == true ? page.lastRowKey : nil
        } while lastRowKey != nil && all.count < 1_000
        return all
    }

    func specification(of deviceID: String) async throws -> TuyaSpecification {
        try await perform("GET", "/v1.0/iot-03/devices/\(deviceID)/specification")
    }

    func streamURL(of deviceID: String) async throws -> URL {
        let body = try JSONEncoder().encode(StreamRequest(type: "hls"))
        let allocation: StreamAllocation = try await perform("POST", "/v1.0/devices/\(deviceID)/stream/actions/allocate", body: body)
        guard let url = URL(string: allocation.url) else { throw TuyaError.api(code: -1, message: "This camera has no live stream") }
        return url
    }

    func send(_ commands: [TuyaCommand], to deviceID: String) async throws {
        struct Body: Encodable { let commands: [TuyaCommand] }
        let body = try JSONEncoder().encode(Body(commands: commands))
        let _: Bool = try await perform("POST", "/v1.0/iot-03/devices/\(deviceID)/commands", body: body)
    }

    // MARK: - Transport

    private func accessToken() async throws -> String {
        if let token, token.expiry > .now.addingTimeInterval(60) { return token.value }
        let fresh: TuyaToken = try await perform("GET", "/v1.0/token", query: ["grant_type": "1"], authenticated: false)
        token = (fresh.accessToken, .now.addingTimeInterval(TimeInterval(fresh.expireTime)))
        return fresh.accessToken
    }

    private func perform<Result: Decodable & Sendable>(
        _ method: String,
        _ path: String,
        query: [String: String] = [:],
        body: Data? = nil,
        authenticated: Bool = true,
        retryOnExpiredToken: Bool = true
    ) async throws -> Result {
        let accessToken = authenticated ? try await accessToken() : nil
        let sortedQuery = query.sorted { $0.key < $1.key }

        var components = URLComponents()
        components.scheme = "https"
        components.host = credentials.region.host
        components.path = path
        if !sortedQuery.isEmpty {
            components.queryItems = sortedQuery.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw TuyaError.badURL }

        let signedURL = sortedQuery.isEmpty
            ? path
            : path + "?" + sortedQuery.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        let timestamp = String(Int64(Date.now.timeIntervalSince1970 * 1000))
        let nonce = UUID().uuidString.lowercased()

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(credentials.accessID, forHTTPHeaderField: "client_id")
        request.setValue(timestamp, forHTTPHeaderField: "t")
        request.setValue(nonce, forHTTPHeaderField: "nonce")
        request.setValue("HMAC-SHA256", forHTTPHeaderField: "sign_method")
        request.setValue(
            sign(method: method, signedURL: signedURL, body: body, accessToken: accessToken, timestamp: timestamp, nonce: nonce),
            forHTTPHeaderField: "sign"
        )
        if let accessToken { request.setValue(accessToken, forHTTPHeaderField: "access_token") }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TuyaError.http(http.statusCode)
        }

        let envelope = try decoder.decode(TuyaEnvelope<Result>.self, from: data)
        if envelope.success, let result = envelope.result { return result }

        // 1010 token invalid, 1011 token expired
        if authenticated, retryOnExpiredToken, [1010, 1011].contains(envelope.code) {
            token = nil
            return try await perform(method, path, query: query, body: body, retryOnExpiredToken: false)
        }
        throw TuyaError.api(code: envelope.code ?? -1, message: envelope.msg ?? "Unknown error")
    }

    private func sign(method: String, signedURL: String, body: Data?, accessToken: String?, timestamp: String, nonce: String) -> String {
        let bodyHash = SHA256.hash(data: body ?? Data()).hex
        let stringToSign = [method, bodyHash, "", signedURL].joined(separator: "\n")
        let message = credentials.accessID + (accessToken ?? "") + timestamp + nonce + stringToSign
        let key = SymmetricKey(data: Data(credentials.accessSecret.utf8))
        return HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key).hex.uppercased()
    }
}

import CryptoKit
import Foundation

/// Smart Life / Tuya Smart account login without a Tuya Cloud project.
///
/// Ported from Tuya's `tuya-device-sharing-sdk` (the Home Assistant Tuya integration). Tuya only issues
/// this login to partners, so NeoNode uses Home Assistant's client ID: the Smart Life app lists the
/// authorization as Home Assistant, and Tuya can revoke that ID at any time.
struct SmartLifeSession: Codable, Sendable, Equatable {
    var userCode: String
    var terminalID: String
    var endpoint: String
    var uid: String
    var username: String?
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

enum SmartLifeLogin {
    static let clientID = "HA_3y9q4ak7g4ephrvke"
    static let schema = "haauthorize"
    private static let host = "https://apigw.iotbing.com"

    /// What the Smart Life app's scanner expects.
    static func qrPayload(for token: String) -> String { "tuyaSmart--qrLogin?token=\(token)" }

    /// Starts a login for the account behind `userCode`; returns the QR token to show.
    static func requestQRCode(userCode: String) async throws -> String {
        let json = try await call("POST", "/v1.0/m/life/home-assistant/qrcode/tokens", query: [
            "clientid": clientID, "usercode": userCode, "schema": schema,
        ])
        guard let result = json["result"] as? [String: Any], let token = result["qrcode"] as? String else {
            throw SmartLifeLogin.error(from: json)
        }
        return token
    }

    /// Returns the session once the user confirmed the scan in Smart Life, `nil` while still waiting.
    static func result(qrToken: String, userCode: String) async throws -> SmartLifeSession? {
        let json = try await call("GET", "/v1.0/m/life/home-assistant/qrcode/tokens/\(qrToken)", query: [
            "clientid": clientID, "usercode": userCode,
        ])
        guard json["success"] as? Bool == true, let result = json["result"] as? [String: Any] else { return nil }
        guard
            let accessToken = result["access_token"] as? String,
            let refreshToken = result["refresh_token"] as? String,
            let endpoint = result["endpoint"] as? String,
            let terminalID = result["terminal_id"] as? String
        else { throw TuyaError.api(code: -1, message: "Unexpected login response") }

        let issuedAt = (json["t"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .now
        let expireTime = (result["expire_time"] as? Double) ?? 7_200
        return SmartLifeSession(
            userCode: userCode,
            terminalID: terminalID,
            endpoint: endpoint,
            uid: (result["uid"] as? String) ?? "",
            username: result["username"] as? String,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: issuedAt.addingTimeInterval(expireTime)
        )
    }

    private static func call(_ method: String, _ path: String, query: [String: String]) async throws -> [String: Any] {
        var components = URLComponents(string: host + path)
        components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw TuyaError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TuyaError.api(code: -1, message: "Unexpected login response")
        }
        return json
    }

    static func error(from json: [String: Any]) -> TuyaError {
        let code = (json["code"] as? Int) ?? Int(json["code"] as? String ?? "") ?? -1
        return .api(code: code, message: (json["msg"] as? String) ?? "Login failed")
    }
}

/// Device API for a Smart Life session. Every query and body is AES-GCM encrypted and HMAC signed
/// with a per-request key derived from the request ID and the refresh token.
actor SmartLifeClient: TuyaService {
    private var session: SmartLifeSession
    private let onSessionChange: @Sendable (SmartLifeSession) -> Void
    private var refreshTask: Task<Void, Error>?

    init(session: SmartLifeSession, onSessionChange: @escaping @Sendable (SmartLifeSession) -> Void) {
        self.session = session
        self.onSessionChange = onSessionChange
    }

    func devices() async throws -> [TuyaDevice] {
        let homes: [Home] = try await request("GET", "/v1.0/m/life/users/homes") ?? []
        var devices: [TuyaDevice] = []
        for home in homes {
            let list: [TuyaDevice] = try await request("GET", "/v1.0/m/life/ha/home/devices", query: ["homeId": home.id]) ?? []
            devices += list.filter { device in !devices.contains { $0.id == device.id } }
        }
        return devices
    }

    func specification(of deviceID: String) async throws -> TuyaSpecification {
        try await request("GET", "/v1.1/m/life/\(deviceID)/specifications") ?? TuyaSpecification(functions: [])
    }

    func send(_ commands: [TuyaCommand], to deviceID: String) async throws {
        struct Body: Encodable { let commands: [TuyaCommand] }
        let _: JSONValue? = try await request("POST", "/v1.1/m/thing/\(deviceID)/commands", body: Body(commands: commands))
    }

    func rooms(of deviceIDs: [String]) async -> [String: TuyaRoom] {
        await withTaskGroup(of: (String, TuyaRoom?).self) { group in
            for id in deviceIDs {
                group.addTask { (id, try? await self.room(of: id)) }
            }
            var rooms: [String: TuyaRoom] = [:]
            for await (id, room) in group {
                if let room { rooms[id] = room }
            }
            return rooms
        }
    }

    func streamURL(of deviceID: String) async throws -> URL {
        let allocation: StreamAllocation? = try await request(
            "POST", "/v1.0/m/ipc/\(deviceID)/stream/actions/allocate", body: StreamRequest(type: "hls")
        )
        guard let url = allocation.flatMap({ URL(string: $0.url) }) else {
            throw TuyaError.api(code: -1, message: "This camera has no live stream")
        }
        return url
    }

    private func room(of deviceID: String) async throws -> TuyaRoom? {
        try await request("GET", "/v1.0/m/thing/ha/\(deviceID)/room")
    }

    /// Ends this terminal's authorization on Tuya's side.
    func signOut() async {
        struct Body: Encodable { let accessToken: String; let terminalId: String }
        let _: JSONValue? = try? await request(
            "POST", "/v1.0/m/token/terminal/expire",
            body: Body(accessToken: session.accessToken, terminalId: session.terminalID)
        )
    }

    // MARK: - Token

    private func refreshTokenIfNeeded() async throws {
        guard session.expiresAt.timeIntervalSinceNow < 60 else { return }
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await self.refreshToken() }
        refreshTask = task
        defer { refreshTask = nil }
        try await task.value
    }

    private func refreshToken() async throws {
        struct Refreshed: Decodable, Sendable {
            let expireTime: Double
            let uid: String?
            let accessToken: String
            let refreshToken: String
        }
        guard let fresh: Refreshed = try await request("GET", "/v1.0/m/token/\(session.refreshToken)", refreshIfNeeded: false) else {
            throw TuyaError.api(code: -1, message: "Smart Life session expired, sign in again")
        }
        session.accessToken = fresh.accessToken
        session.refreshToken = fresh.refreshToken
        session.uid = fresh.uid ?? session.uid
        session.expiresAt = .now.addingTimeInterval(fresh.expireTime)
        onSessionChange(session)
    }

    // MARK: - Transport

    private func request<Result: Decodable & Sendable>(
        _ method: String,
        _ path: String,
        query: [String: String]? = nil,
        body: (any Encodable & Sendable)? = nil,
        refreshIfNeeded: Bool = true
    ) async throws -> Result? {
        if refreshIfNeeded { try await refreshTokenIfNeeded() }

        let requestID = UUID().uuidString.lowercased()
        let hashKey = Insecure.MD5.hash(data: Data((requestID + session.refreshToken).utf8)).hex
        let secret = String(
            HMAC<SHA256>.authenticationCode(for: Data(hashKey.utf8), using: SymmetricKey(data: Data(requestID.utf8))).hex.prefix(16)
        )
        let key = SymmetricKey(data: Data(secret.utf8))

        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let queryEnc = try query.flatMap { $0.isEmpty ? nil : try Self.encrypt(encoder.encode($0), key: key) } ?? ""
        let bodyEnc = try body.map { try Self.encrypt(encoder.encode($0), key: key) } ?? ""

        let headers: KeyValuePairs<String, String> = [
            "X-appKey": SmartLifeLogin.clientID,
            "X-requestId": requestID,
            "X-sid": "",
            "X-time": String(Int64(Date.now.timeIntervalSince1970 * 1000)),
            "X-token": session.accessToken,
        ]
        let signString = headers.filter { !$0.value.isEmpty }.map { "\($0.key)=\($0.value)" }.joined(separator: "||")
            + queryEnc + bodyEnc
        let sign = HMAC<SHA256>.authenticationCode(for: Data(signString.utf8), using: SymmetricKey(data: Data(hashKey.utf8))).hex

        var urlString = session.endpoint + path
        if !queryEnc.isEmpty {
            urlString += "?encdata=" + (queryEnc.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? queryEnc)
        }
        guard let url = URL(string: urlString) else { throw TuyaError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(sign, forHTTPHeaderField: "X-sign")
        if !bodyEnc.isEmpty {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["encdata": bodyEnc])
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TuyaError.http(http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TuyaError.api(code: -1, message: "Unexpected response")
        }
        guard json["success"] as? Bool == true else { throw SmartLifeLogin.error(from: json) }

        let payload: Data
        switch json["result"] {
        case let encrypted as String where !encrypted.isEmpty:
            payload = try Self.decrypt(encrypted, key: key)
        case nil, is NSNull:
            return nil
        case let plain?:
            payload = try JSONSerialization.data(withJSONObject: plain, options: .fragmentsAllowed)
        }
        return try JSONDecoder().decode(Result.self, from: payload)
    }

    /// base64(nonce) + base64(ciphertext + tag), nonce being 12 random ASCII characters.
    private static func encrypt(_ plain: Data, key: SymmetricKey) throws -> String {
        let alphabet = Array("ABCDEFGHJKMNPQRSTWXYZabcdefhijkmnprstwxyz2345678".utf8)
        let nonceBytes = Data((0..<12).map { _ in alphabet.randomElement() ?? 65 })
        let sealed = try AES.GCM.seal(plain, using: key, nonce: AES.GCM.Nonce(data: nonceBytes))
        return nonceBytes.base64EncodedString() + (sealed.ciphertext + sealed.tag).base64EncodedString()
    }

    /// base64(nonce(12) + ciphertext + tag(16)).
    private static func decrypt(_ encoded: String, key: SymmetricKey) throws -> Data {
        guard let data = Data(base64Encoded: encoded), data.count > 28 else {
            throw TuyaError.api(code: -1, message: "Unreadable response")
        }
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: data.prefix(12)),
            ciphertext: data.dropFirst(12).dropLast(16),
            tag: data.suffix(16)
        )
        return try AES.GCM.open(box, using: key)
    }

    private struct Home: Decodable, Sendable {
        let id: String
        let name: String?

        enum CodingKeys: String, CodingKey { case ownerId, name }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let number = try? c.decode(Int64.self, forKey: .ownerId) {
                id = String(number)
            } else {
                id = try c.decode(String.self, forKey: .ownerId)
            }
            name = try c.decodeIfPresent(String.self, forKey: .name)
        }
    }
}

extension Sequence where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

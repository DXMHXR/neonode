import Foundation
import Observation

@MainActor
@Observable
final class DeviceStore {
    enum Route: Hashable {
        case devices
        case detail(String)
        case settings
    }

    private(set) var account: TuyaAccount?
    private(set) var devices: [TuyaDevice] = []
    private(set) var specifications: [String: TuyaSpecification] = [:]
    /// Room per device ID (Smart Life accounts only).
    private(set) var rooms: [String: TuyaRoom] = [:]
    private(set) var isRefreshing = false
    private(set) var pending: Set<String> = []
    var errorMessage: String?
    var route: Route = .devices

    let isDemo: Bool
    let showsPreviewWindow: Bool
    private(set) var camerasRequestedAtLaunch: String?
    /// Fixed for the app's lifetime: the scene's launch behavior must not change once evaluated.
    let opensCamerasAtLaunch: Bool

    /// Resolves `-openCameras` once devices are loaded (called by the camera window).
    func openLaunchCameras() async {
        guard let requested = camerasRequestedAtLaunch else { return }
        camerasRequestedAtLaunch = nil
        await refresh(force: true)
        let ids = requested == "all"
            ? devices.filter(\.isCamera).map(\.id)
            : requested.split(separator: ",").map(String.init)
        ids.forEach(openCamera)
    }

    /// `-addSamsung <ip>`: adds a screen at launch and shows the outcome (diagnostics).
    private var launchSamsungIP: String?

    /// `-wizDiagnostics`: shows every WiZ light's raw replies in the error banner.
    private var showsWiZDiagnostics = false

    func runLaunchDiagnostics() async {
        if showsWiZDiagnostics, let wiz {
            showsWiZDiagnostics = false
            errorMessage = await wiz.diagnostics()
        }
        if ProcessInfo.processInfo.arguments.contains("-keychainDiagnostics") {
            errorMessage = CredentialStore.diagnostics()
        }
        guard let ip = launchSamsungIP else { return }
        launchSamsungIP = nil
        do {
            try await addSamsungScreen(ip: ip)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var service: (any TuyaService)?
    /// Devices on the local network (not in demo mode).
    let wiz: WiZService?
    let samsung: SamsungService?
    private var lastRefresh: Date = .distantPast

    // MARK: Local devices (names and rooms are set in neo-node, since they don't come from the device)

    static func isLocal(_ deviceID: String) -> Bool {
        deviceID.hasPrefix(WiZService.prefix) || deviceID.hasPrefix(SamsungService.prefix)
    }

    /// Device ID → custom name.
    var localNames: [String: String] = LocalStore.load("localDeviceNames", as: [String: String].self) ?? [:] {
        didSet { LocalStore.save(localNames, key: "localDeviceNames") }
    }

    /// Device ID → room ID (one of the account's rooms).
    var localRooms: [String: String] = LocalStore.load("localDeviceRooms", as: [String: String].self) ?? [:] {
        didSet { LocalStore.save(localRooms, key: "localDeviceRooms") }
    }

    /// Every room the account knows, in display order.
    var knownRooms: [TuyaRoom] {
        Array(Set(rooms.values)).sorted {
            $0.displayOrder != $1.displayOrder
                ? $0.displayOrder < $1.displayOrder
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func room(for deviceID: String) -> TuyaRoom? {
        if let room = rooms[deviceID] { return room }
        guard let roomID = localRooms[deviceID] else { return nil }
        return knownRooms.first { $0.id == roomID }
    }

    func rename(_ deviceID: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        localNames[deviceID] = trimmed.isEmpty ? nil : trimmed
        if let index = devices.firstIndex(where: { $0.id == deviceID }), !trimmed.isEmpty {
            devices[index].name = trimmed
        }
    }

    func assignRoom(_ roomID: String?, to deviceID: String) {
        localRooms[deviceID] = roomID
    }

    /// Finds WiZ lights and Samsung screens again, now (Settings › Scan).
    func scanLocalNetwork() async -> Int {
        await samsung?.discover()
        await refresh(force: true)
        return devices.filter { Self.isLocal($0.id) }.count
    }

    func addSamsungScreen(ip: String) async throws {
        try await samsung?.add(ip: ip.trimmingCharacters(in: .whitespaces))
        await refresh(force: true)
    }

    private func service(for deviceID: String) -> (any TuyaService)? {
        if deviceID.hasPrefix(WiZService.prefix), let wiz { return wiz }
        if deviceID.hasPrefix(SamsungService.prefix), let samsung { return samsung }
        return service // the demo service plays every device
    }
    private var revision: [String: Int] = [:]

    // MARK: Camera window state (methods in DeviceStore+Cameras.swift)

    /// Cameras shown in the camera window, in display order.
    var openCameraIDs: [String] = []
    var cameraWindowSize: CameraWindowSize = CameraWindowSize(rawValue: UserDefaults.standard.string(forKey: "cameraWindowSize") ?? "") ?? .medium {
        didSet { UserDefaults.standard.set(cameraWindowSize.rawValue, forKey: "cameraWindowSize") }
    }
    var camerasStayOnTop: Bool = UserDefaults.standard.bool(forKey: "camerasStayOnTop") {
        didSet { UserDefaults.standard.set(camerasStayOnTop, forKey: "camerasStayOnTop") }
    }

    func streamURL(for cameraID: String) async throws -> URL {
        guard let service else { throw TuyaError.api(code: -1, message: "Not signed in") }
        return try await service.streamURL(of: cameraID)
    }

    init(arguments: [String]) {
        // `-openCameras all` (or `-openCameras id1,id2`) opens the camera window at launch.
        let openCamerasIndex = arguments.firstIndex(of: "-openCameras")
        let requestedCameras = openCamerasIndex.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        opensCamerasAtLaunch = requestedCameras != nil
        camerasRequestedAtLaunch = requestedCameras
        isDemo = arguments.contains("-demo")
        showsWiZDiagnostics = arguments.contains("-wizDiagnostics")
        // `-route settings` or `-route detail:<deviceID>` opens that screen (screenshots).
        if let index = arguments.firstIndex(of: "-route"), arguments.indices.contains(index + 1) {
            let value = arguments[index + 1]
            if value == "settings" { route = .settings }
            if value.hasPrefix("detail:") { route = .detail(String(value.dropFirst("detail:".count))) }
        }
        if let index = arguments.firstIndex(of: "-addSamsung"), arguments.indices.contains(index + 1) {
            launchSamsungIP = arguments[index + 1]
        }
        wiz = isDemo ? nil : WiZService()
        samsung = isDemo ? nil : SamsungService()
        showsPreviewWindow = arguments.contains("-window")
        if isDemo {
            service = DemoTuyaService()
        } else if let saved = CredentialStore.load() {
            account = saved
            service = Self.makeService(for: saved)
        }


    }

    var isConfigured: Bool { service != nil }
    var poweredOnCount: Int { devices.filter { $0.online && $0.isOn }.count }

    func device(_ id: String) -> TuyaDevice? {
        devices.first { $0.id == id }
    }

    // MARK: - Connection

    /// Signs in once the account can list devices; keeps the previous account otherwise.
    func signIn(_ newAccount: TuyaAccount) async {
        let candidate = Self.makeService(for: newAccount)
        do {
            let list = try await candidate.devices()
            try CredentialStore.save(newAccount)
            account = newAccount
            service = candidate
            specifications = [:]
            rooms = [:]
            devices = Self.sorted(list)
            lastRefresh = .now
            errorMessage = nil
            route = .devices
            await loadRooms(reload: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() {
        if let client = service as? SmartLifeClient {
            Task { await client.signOut() }
        }
        CredentialStore.delete()
        account = nil
        service = isDemo ? DemoTuyaService() : nil
        devices = []
        specifications = [:]
        rooms = [:]
        errorMessage = nil
        route = .devices
    }

    private static func makeService(for account: TuyaAccount) -> any TuyaService {
        switch account {
        case .cloudProject(let credentials):
            TuyaClient(credentials: credentials)
        case .smartLife(let session):
            SmartLifeClient(session: session) { refreshed in
                // A renewed session replaces the old one on Tuya's side, so failing to save it would
                // strand the next launch on a dead session: log it loudly.
                do { try CredentialStore.save(.smartLife(refreshed)) } catch {
                    NSLog("neo-node: couldn't save the renewed Smart Life session: %@", error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Reading

    /// `reloadRooms` re-reads every device's room (manual refresh); otherwise only new devices are looked up.
    func refresh(force: Bool = false, reloadRooms: Bool = false) async {
        guard let service, !isRefreshing else { return }
        guard force || Date.now.timeIntervalSince(lastRefresh) > 10 else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // Local devices are read at the same time; their failures never hide the Tuya devices.
        async let wizDevices = (try? await wiz?.devices()) ?? []
        async let samsungDevices = (try? await samsung?.devices()) ?? []
        do {
            let names = localNames
            let local = (await wizDevices + samsungDevices).map { device in
                var device = device
                if let name = names[device.id] { device.name = name }
                return device
            }
            let fresh = try await service.devices() + local
            // Keep optimistic values for devices with a command still in flight.
            devices = Self.sorted(fresh.map { device in pending.contains(device.id) ? (self.device(device.id) ?? device) : device })
            lastRefresh = .now
            errorMessage = nil
        } catch TuyaError.sessionExpired {
            // Back to the sign-in screen (the user code is remembered), saying why.
            signOut()
            errorMessage = TuyaError.sessionExpired.localizedDescription
            return
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        await loadRooms(reload: reloadRooms)
    }

    private func loadRooms(reload: Bool) async {
        guard let service else { return }
        let ids = devices.map(\.id).filter { (isDemo || !Self.isLocal($0)) && (reload || rooms[$0] == nil) }
        guard !ids.isEmpty else { return }
        let found = await service.rooms(of: ids)
        if reload {
            rooms = found
        } else {
            rooms.merge(found) { _, new in new }
        }
    }

    struct Section: Identifiable {
        let id: String
        let title: String?
        let devices: [TuyaDevice]
    }

    /// Devices grouped by room in the app's room order; no headers when no device has a room.
    var hidesOfflineDevices: Bool = UserDefaults.standard.bool(forKey: "hidesOfflineDevices") {
        didSet { UserDefaults.standard.set(hidesOfflineDevices, forKey: "hidesOfflineDevices") }
    }

    /// Devices the grid shows: all of them, or only online ones when offline devices are hidden.
    var listedDevices: [TuyaDevice] {
        hidesOfflineDevices ? devices.filter(\.online) : devices
    }

    var offlineCount: Int { devices.filter { !$0.online }.count }

    var sections: [Section] {
        let devices = listedDevices
        guard !devices.isEmpty else { return [] }
        guard devices.contains(where: { room(for: $0.id) != nil }) else {
            return [Section(id: "all", title: nil, devices: ordered(devices, in: "all"))]
        }
        let grouped = Dictionary(grouping: devices) { room(for: $0.id) }
        var result = grouped.compactMap { room, devices in
            room.map { Section(id: $0.id, title: $0.name, devices: devices) }
        }
        let order = Dictionary(grouped.keys.compactMap { $0 }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        result.sort { lhs, rhs in
            let l = order[lhs.id], r = order[rhs.id]
            if l?.displayOrder != r?.displayOrder { return (l?.displayOrder ?? 0) < (r?.displayOrder ?? 0) }
            return (lhs.title ?? "").localizedStandardCompare(rhs.title ?? "") == .orderedAscending
        }
        // The user's own order wins; rooms never arranged keep the app's order after them.
        let custom = Dictionary(sectionOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        result = result.enumerated()
            .sorted { (custom[$0.element.id] ?? sectionOrder.count + $0.offset, $0.offset) < (custom[$1.element.id] ?? sectionOrder.count + $1.offset, $1.offset) }
            .map(\.element)
        // Devices without a room always come last.
        if let unassigned = grouped[nil] {
            result.append(Section(id: Self.otherSectionID, title: "Other", devices: unassigned))
        }
        return result.map { Section(id: $0.id, title: $0.title, devices: ordered($0.devices, in: $0.id)) }
    }

    // MARK: - Device order within a room

    /// Section ID → device IDs in the order the user arranged; unlisted devices follow in the default order.
    var deviceOrder: [String: [String]] = LocalStore.load("deviceOrder", as: [String: [String]].self) ?? [:] {
        didSet { LocalStore.save(deviceOrder, key: "deviceOrder") }
    }

    private func ordered(_ devices: [TuyaDevice], in sectionID: String) -> [TuyaDevice] {
        guard let order = deviceOrder[sectionID], !order.isEmpty else { return devices }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return devices.enumerated().sorted {
            (rank[$0.element.id] ?? order.count + $0.offset, $0.offset) < (rank[$1.element.id] ?? order.count + $1.offset, $1.offset)
        }.map(\.element)
    }

    /// Puts `deviceID` where `targetID` is now, within one room. Hidden (offline) devices keep their place after.
    func moveDevice(_ deviceID: String, to targetID: String, in sectionID: String) {
        guard deviceID != targetID, let section = sections.first(where: { $0.id == sectionID }) else { return }
        var ids = section.devices.map(\.id)
        guard let from = ids.firstIndex(of: deviceID), let to = ids.firstIndex(of: targetID) else { return }
        ids.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        deviceOrder[sectionID] = ids + (deviceOrder[sectionID] ?? []).filter { !ids.contains($0) }
    }

    func moveDevice(_ deviceID: String, by offset: Int, in sectionID: String) {
        guard let ids = sections.first(where: { $0.id == sectionID })?.devices.map(\.id),
              let from = ids.firstIndex(of: deviceID), ids.indices.contains(from + offset) else { return }
        moveDevice(deviceID, to: ids[from + offset], in: sectionID)
    }

    func resetDeviceOrder(in sectionID: String) {
        deviceOrder[sectionID] = nil
    }

    // MARK: - Section order

    private static let sectionOrderKey = "sectionOrder"
    private(set) var sectionOrder: [String] = UserDefaults.standard.stringArray(forKey: sectionOrderKey) ?? [] {
        didSet { UserDefaults.standard.set(sectionOrder, forKey: Self.sectionOrderKey) }
    }

    var hasCustomSectionOrder: Bool { !sectionOrder.isEmpty }

    /// Puts `sectionID` where `targetID` is now (dropping a header onto another).
    static let otherSectionID = "other"

    func moveSection(_ sectionID: String, to targetID: String) {
        guard sectionID != Self.otherSectionID, targetID != Self.otherSectionID else { return }
        var ids = sections.map(\.id).filter { $0 != Self.otherSectionID }
        guard sectionID != targetID, let from = ids.firstIndex(of: sectionID), let to = ids.firstIndex(of: targetID) else { return }
        ids.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        sectionOrder = ids
    }

    func moveSection(_ sectionID: String, by offset: Int) {
        let ids = sections.map(\.id)
        guard let from = ids.firstIndex(of: sectionID), ids.indices.contains(from + offset) else { return }
        moveSection(sectionID, to: ids[from + offset])
    }

    func resetSectionOrder() {
        sectionOrder = []
    }

    func loadSpecification(for deviceID: String) async {
        guard let service = service(for: deviceID), specifications[deviceID] == nil else { return }
        do {
            specifications[deviceID] = try await service.specification(of: deviceID)
        } catch {
            // Projects without the "Device Control" API scope still get toggles from the status list.
            specifications[deviceID] = TuyaSpecification(functions: [])
        }
    }

    // MARK: - Control

    func toggle(_ device: TuyaDevice) {
        guard let code = device.powerCode else { return }
        set(device.id, code: code, value: .bool(!device.isOn))
    }

    func turnEverythingOff() {
        for device in devices where device.online && device.isOn {
            toggle(device)
        }
    }

    func set(_ deviceID: String, code: String, value: JSONValue) {
        guard let service = service(for: deviceID), let index = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        let previous = devices[index].value(for: code)
        devices[index].setValue(value, for: code)
        pending.insert(deviceID)
        let ticket = (revision[deviceID] ?? 0) + 1
        revision[deviceID] = ticket

        Task {
            do {
                try await service.send([TuyaCommand(code: code, value: value)], to: deviceID)
            } catch {
                if revision[deviceID] == ticket, let previous, let index = devices.firstIndex(where: { $0.id == deviceID }) {
                    devices[index].setValue(previous, for: code)
                }
                errorMessage = error.localizedDescription
            }
            if revision[deviceID] == ticket { pending.remove(deviceID) }
        }
    }

    private static func sorted(_ devices: [TuyaDevice]) -> [TuyaDevice] {
        devices.sorted {
            if $0.online != $1.online { return $0.online }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

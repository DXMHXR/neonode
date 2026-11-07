import Foundation

/// Moves local data from the old `com.rahmad.TuyaBar` app to `com.kylswich.neonode`.
///
/// Sandboxed apps can't read each other's containers, so the old app (built once more with this code)
/// exports into an App Group both apps share, and the new app imports from it on first launch.
/// The exported login is deleted from the group as soon as the new app has it in its own keychain.
enum Migration {
    static let legacyBundleID = "com.rahmad.TuyaBar"
    static let groupID = "VNB5T45XDL.com.kylswich.neonode"

    /// Every UserDefaults key neo-node stores.
    private static let keys = [
        "sectionOrder", "selectedRoom", "smartLifeUserCode", "cameraOrder", "cameraWindowSize",
        "camerasStayOnTop", "hidesOfflineDevices", "localDeviceNames", "localDeviceRooms",
        "wizHosts", "samsungScreens", "deviceOrder",
    ]
    private static let accountKey = "migration.account"
    private static let exportedKey = "migration.exportedAt"
    private static let importedKey = "migration.importedFromTuyaBar"

    static func run() {
        guard let shared = UserDefaults(suiteName: groupID) else { return }
        if Bundle.main.bundleIdentifier == legacyBundleID {
            export(to: shared)
        } else {
            importIfNeeded(from: shared)
        }
    }

    private static func export(to shared: UserDefaults) {
        let local = UserDefaults.standard
        for key in keys {
            if let value = local.object(forKey: key) { shared.set(value, forKey: key) }
        }
        if let account = CredentialStore.load(service: legacyBundleID),
           let data = try? JSONEncoder().encode(account) {
            shared.set(data, forKey: accountKey)
        }
        shared.set(Date.now, forKey: exportedKey)
    }

    private static func importIfNeeded(from shared: UserDefaults) {
        let local = UserDefaults.standard
        guard !local.bool(forKey: importedKey), shared.object(forKey: exportedKey) != nil else { return }
        for key in keys where local.object(forKey: key) == nil {
            if let value = shared.object(forKey: key) { local.set(value, forKey: key) }
        }
        if CredentialStore.load() == nil,
           let data = shared.data(forKey: accountKey),
           let account = try? JSONDecoder().decode(TuyaAccount.self, from: data) {
            try? CredentialStore.save(account)
        }
        shared.removeObject(forKey: accountKey) // don't leave the login outside the keychain
        local.set(true, forKey: importedKey)
    }
}

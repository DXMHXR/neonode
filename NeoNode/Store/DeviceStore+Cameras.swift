import Foundation

enum CameraWindowSize: String, CaseIterable, Identifiable {
    case extraSmall, small, medium, large, extraLarge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .extraSmall: "Extra Small"
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }

    /// Preferred width of one camera tile (16:9); shrunk to fit the screen.
    var tileWidth: CGFloat {
        switch self {
        case .extraSmall: 220
        case .small: 320
        case .medium: 440
        case .large: 600
        case .extraLarge: 800
        }
    }
}

extension TuyaDevice {
    var isCamera: Bool { ["sp", "sxj", "dghsxj"].contains(category) }

    var isPrivacyModeOn: Bool { value(for: "basic_private")?.boolValue ?? false }
}

extension DeviceStore {
    var openCameras: [TuyaDevice] { openCameraIDs.compactMap(device) }

    /// Adds a camera to the camera window (no-op when already shown), placed by the saved order.
    func openCamera(_ id: String) {
        guard !openCameraIDs.contains(id) else { return }
        openCameraIDs.append(id)
        let order = Self.savedCameraOrder
        openCameraIDs = openCameraIDs.enumerated().sorted { lhs, rhs in
            let l = order.firstIndex(of: lhs.element) ?? order.count + lhs.offset
            let r = order.firstIndex(of: rhs.element) ?? order.count + rhs.offset
            return (l, lhs.offset) < (r, rhs.offset)
        }.map(\.element)
    }

    /// Camera order the user arranged, kept across launches; cameras not shown keep their place after.
    private static var savedCameraOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: "cameraOrder") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "cameraOrder") }
    }

    func closeCamera(_ id: String) {
        openCameraIDs.removeAll { $0 == id }
    }

    /// Puts `id` where `targetID` is now (dropping one monitor onto another).
    func moveCamera(_ id: String, to targetID: String) {
        guard id != targetID,
              let from = openCameraIDs.firstIndex(of: id),
              let to = openCameraIDs.firstIndex(of: targetID) else { return }
        openCameraIDs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        Self.savedCameraOrder = openCameraIDs + Self.savedCameraOrder.filter { !openCameraIDs.contains($0) }
    }

    /// Tuya PTZ directions: 0 up, 2 right, 4 down, 6 left (odd values are diagonals).
    func startPan(_ cameraID: String, direction: String) {
        set(cameraID, code: "ptz_control", value: .string(direction))
    }

    func stopPan(_ cameraID: String) {
        set(cameraID, code: "ptz_stop", value: .bool(true))
    }
}

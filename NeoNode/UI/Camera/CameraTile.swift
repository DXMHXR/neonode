import SwiftUI

/// One camera monitor: live video with glass controls that appear on hover.
struct CameraTile: View {
    @Environment(DeviceStore.self) private var store
    let device: TuyaDevice
    let size: CGSize
    let isDropTarget: Bool

    @State private var camera: CameraPlayer
    @State private var isHovering = false

    init(device: TuyaDevice, size: CGSize, isDropTarget: Bool) {
        self.device = device
        self.size = size
        self.isDropTarget = isDropTarget
        _camera = State(initialValue: CameraPlayer(cameraID: device.id))
    }

    private var specification: TuyaSpecification? { store.specifications[device.id] }

    private func supports(_ code: String) -> Bool {
        device.value(for: code) != nil || specification?.functions.contains { $0.code == code } == true
    }

    var body: some View {
        ZStack {
            Color.black
            PlayerSurface(player: camera.player)
                .opacity(camera.state == .playing && !device.isPrivacyModeOn ? 1 : 0)
            statusOverlay
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .top) { topBar }
        .overlay(alignment: .bottomTrailing) {
            if supports("ptz_control"), device.online, !device.isPrivacyModeOn {
                PTZPad(cameraID: device.id)
                    .padding(12)
                    .opacity(isHovering ? 1 : 0)
            }
        }
        .clipShape(.rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.tint, lineWidth: isDropTarget ? 3 : 0)
        }
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.2)) { isHovering = hovering }
        }
        .task(id: device.id) {
            await store.loadSpecification(for: device.id)
        }
        .onAppear { if device.online { camera.start(using: store) } }
        .onDisappear { camera.stop() }
        .onChange(of: device.isPrivacyModeOn) { _, privacy in
            if !privacy { camera.start(using: store) }
        }
    }

    // MARK: - Overlays

    @ViewBuilder
    private var statusOverlay: some View {
        if !device.online {
            message("Camera offline", symbol: "wifi.slash")
        } else if device.isPrivacyModeOn {
            message("Privacy mode is on", symbol: "eye.slash")
        } else {
            switch camera.state {
            case .connecting:
                VStack(spacing: 10) {
                    ProgressView().controlSize(.regular).tint(.white)
                    Text("Connecting…").font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            case .failed(let reason):
                VStack(spacing: 10) {
                    message(reason, symbol: "exclamationmark.triangle")
                    Button("Retry") { camera.start(using: store) }
                        .buttonStyle(.glass)
                }
            case .playing:
                EmptyView()
            }
        }
    }

    private func message(_ text: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title2)
            Text(text).font(.callout).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 20)
    }

    private var isCompact: Bool { size.width < 300 }

    /// Name label on the left; the hover buttons float over the right side instead of taking
    /// layout space, so the name keeps its full width when they're hidden.
    private var topBar: some View {
        HStack(spacing: 6) {
            // Drag handle: drop onto another monitor to swap places.
            HStack(spacing: isCompact ? 5 : 6) {
                Circle()
                    .fill(camera.state == .playing && device.online ? .red : .gray)
                    .frame(width: isCompact ? 6 : 7, height: isCompact ? 6 : 7)
                Text(device.name)
                    .font((isCompact ? Font.caption : .callout).weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, isCompact ? 9 : 12)
            .padding(.vertical, isCompact ? 5 : 7)
            .glassEffect(.regular, in: .capsule)
            .draggable(CameraDragID(id: device.id)) {
                Label(device.name, systemImage: "web.camera")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .glassEffect(.regular, in: .capsule)
            }
            .help("Drag onto another camera to rearrange")
            .opacity(isHovering && isCompact ? 0 : 1)

            Spacer(minLength: 0)
        }
        .overlay(alignment: .trailing) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    TileButton(systemImage: camera.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                               help: camera.isMuted ? "Unmute" : "Mute") {
                        camera.isMuted.toggle()
                    }
                    settingsMenu
                    TileButton(systemImage: "xmark", help: "Close") {
                        withAnimation(.smooth) { store.closeCamera(device.id) }
                    }
                }
            }
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
        }
        .foregroundStyle(.white)
        .padding(isCompact ? 8 : 10)
    }

    private var settingsMenu: some View {
        Menu {
            Button("Reconnect", systemImage: "arrow.clockwise") { camera.start(using: store) }
            Divider()
            toggle("Privacy Mode", code: "basic_private")
            toggle("Motion Detection", code: "motion_switch")
            toggle("Recording", code: "record_switch")
            toggle("Flip Image", code: "basic_flip")
            toggle("Status Light", code: "basic_indicator")
            if supports("basic_nightvision") {
                Picker("Night Vision", selection: Binding(
                    get: { device.value(for: "basic_nightvision")?.stringValue ?? "0" },
                    set: { store.set(device.id, code: "basic_nightvision", value: .string($0)) }
                )) {
                    Text("Auto").tag("0")
                    Text("Off").tag("1")
                    Text("On").tag("2")
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(.circle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glassEffect(.regular.interactive(), in: .circle)
        .help("Camera settings")
    }

    @ViewBuilder
    private func toggle(_ title: String, code: String) -> some View {
        if supports(code) {
            Toggle(title, isOn: Binding(
                get: { device.value(for: code)?.boolValue ?? false },
                set: { store.set(device.id, code: code, value: .bool($0)) }
            ))
        }
    }
}

struct TileButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(help)
    }
}

/// Pan/tilt pad: holding an arrow moves the camera, releasing stops it.
struct PTZPad: View {
    @Environment(DeviceStore.self) private var store
    let cameraID: String

    var body: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow {
                Color.clear.frame(width: 30, height: 30)
                arrow("chevron.up", direction: "0")
                Color.clear.frame(width: 30, height: 30)
            }
            GridRow {
                arrow("chevron.left", direction: "6")
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 30, height: 30)
                arrow("chevron.right", direction: "2")
            }
            GridRow {
                Color.clear.frame(width: 30, height: 30)
                arrow("chevron.down", direction: "4")
                Color.clear.frame(width: 30, height: 30)
            }
        }
        .padding(6)
        .glassEffect(.regular, in: .circle)
        .foregroundStyle(.white)
    }

    private func arrow(_ symbol: String, direction: String) -> some View {
        HoldButton(systemImage: symbol) {
            store.startPan(cameraID, direction: direction)
        } onRelease: {
            store.stopPan(cameraID)
        }
    }
}

private struct HoldButton: View {
    let systemImage: String
    let onPress: () -> Void
    let onRelease: () -> Void

    @State private var isPressed = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .bold))
            .frame(width: 30, height: 30)
            .background(.white.opacity(isPressed ? 0.25 : 0), in: .circle)
            .contentShape(.circle)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        onPress()
                    }
                    .onEnded { _ in
                        isPressed = false
                        onRelease()
                    }
            )
    }
}

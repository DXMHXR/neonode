import SwiftUI

struct DeviceDetailView: View {
    @Environment(DeviceStore.self) private var store
    let device: TuyaDevice

    private var controls: [DeviceControl] {
        DeviceControl.controls(for: device, specification: store.specifications[device.id])
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                GlassIconButton(systemImage: "chevron.left", help: "Back") {
                    store.route = .devices
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text((device.online ? device.kind : "\(device.kind) · Offline")
                        + (DeviceStore.isLocal(device.id) ? " · Local only" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.pending.contains(device.id) {
                    ProgressView().controlSize(.small)
                }
            }

            if device.powerCode != nil {
                powerButton
            }

            if store.specifications[device.id] == nil {
                ProgressView()
                    .controlSize(.small)
                    .frame(height: 40)
            } else if !controls.isEmpty {
                GlassEffectContainer {
                    VStack(spacing: 0) {
                        ForEach(Array(controls.enumerated()), id: \.element.id) { index, control in
                            if index > 0 { Divider().padding(.horizontal, 14) }
                            DeviceControlRow(device: device, control: control)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                        }
                    }
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
                }
                .disabled(!device.online)
            }

            DeviceNameAndRoom(device: device)

            if let message = store.errorMessage {
                ErrorBanner(message: message) { store.errorMessage = nil }
            }
        }
        .padding(16)
        .task(id: device.id) { await store.loadSpecification(for: device.id) }
    }

    private var powerButton: some View {
        let on = device.online && device.isOn
        return VStack(spacing: 8) {
            Button {
                withAnimation(.smooth(duration: 0.3)) { store.toggle(device) }
            } label: {
                Image(systemName: device.symbol)
                    .symbolVariant(on ? .fill : .none)
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(on ? device.tint : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 104, height: 104)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(on ? .regular.tint(device.tint.opacity(0.45)).interactive() : .regular.interactive(), in: .circle)
            .disabled(!device.online)

            Text(device.stateText)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
        .padding(.top, 4)
    }
}

struct DeviceControlRow: View {
    @Environment(DeviceStore.self) private var store
    let device: TuyaDevice
    let control: DeviceControl

    @State private var draft: Double?

    var body: some View {
        switch control {
        case .toggle(let code):
            Toggle(DataPointLabel.title(for: code), isOn: Binding(
                get: { device.value(for: code)?.boolValue ?? false },
                set: { store.set(device.id, code: code, value: .bool($0)) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

        case .slider(let code, let range):
            let current = draft ?? device.value(for: code)?.doubleValue ?? Double(range.min)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(DataPointLabel.title(for: code))
                    Spacer()
                    Text(display(current, range: range, code: code))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Slider(
                    value: Binding(get: { current }, set: { draft = $0 }),
                    in: Double(range.min)...Double(range.max),
                    step: Double(max(range.step ?? 1, 1))
                ) { editing in
                    guard !editing, let value = draft else { return }
                    store.set(device.id, code: code, value: .int(Int(value.rounded())))
                    draft = nil
                }
                .tint(device.tint)
            }

        case .modes(let code, let options):
            let current = device.value(for: code)?.stringValue ?? options[0]
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(DataPointLabel.title(for: code))
                    Spacer()
                    if current != options[0] {
                        Button("Stop") { store.set(device.id, code: code, value: .string(options[0])) }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
                HStack(spacing: 6) {
                    ForEach(options.dropFirst(), id: \.self) { option in
                        let selected = option == current
                        Button {
                            store.set(device.id, code: code, value: .string(option))
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: SyncModeSymbol.symbol(for: option))
                                    .font(.system(size: 16, weight: .semibold))
                                    .frame(height: 20)
                                Text(option)
                                    .font(.caption2.weight(.medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .overlay {
                                RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(.white.opacity(selected ? 0.9 : 0), lineWidth: 2)
                            }
                            .contentShape(.rect(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .glassEffect(
                            selected ? .regular.tint(device.tint.opacity(0.55)).interactive() : .regular.interactive(),
                            in: .rect(cornerRadius: 14)
                        )
                    }
                }
            }

        case .buttons(let code, let keys):
            HStack(spacing: 8) {
                ForEach(keys, id: \.self) { key in
                    let remote = RemoteKey(key)
                    Button {
                        store.set(device.id, code: code, value: .string(key))
                    } label: {
                        Image(systemName: remote.symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .help(remote.title)
                }
            }

        case .picker(let code, let options):
            let selection = Binding(
                get: { device.value(for: code)?.stringValue ?? options[0] },
                set: { store.set(device.id, code: code, value: .string($0)) }
            )
            if options.count <= 4 {
                VStack(alignment: .leading, spacing: 6) {
                    Text(DataPointLabel.title(for: code))
                    Picker(DataPointLabel.title(for: code), selection: selection) {
                        ForEach(options, id: \.self) { Text(DataPointLabel.humanize($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            } else {
                Picker(DataPointLabel.title(for: code), selection: selection) {
                    ForEach(options, id: \.self) { Text(DataPointLabel.humanize($0)).tag($0) }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private func display(_ value: Double, range: TuyaFunction.IntegerRange, code: String) -> String {
        // A 0/10…100 range is already a percentage (WiZ dimming): show the value itself.
        if range.max == 100, code.contains("bright") || code.contains("percent") {
            return "\(Int(value.rounded()))%"
        }
        if code.contains("bright") || code.contains("temp_value") || code.contains("percent") {
            let percent = (value - Double(range.min)) / Double(range.max - range.min) * 100
            return "\(Int(percent.rounded()))%"
        }
        let scale = range.scale ?? 0
        guard scale > 0 else { return "\(Int(value))" }
        return (value / pow(10, Double(scale))).formatted(.number.precision(.fractionLength(scale)))
    }
}

/// Remote-control keys shown as buttons for Samsung screens.
struct RemoteKey {
    let symbol: String
    let title: String

    init(_ key: String) {
        switch key {
        case "KEY_VOLDOWN": (symbol, title) = ("speaker.minus.fill", "Volume down")
        case "KEY_VOLUP": (symbol, title) = ("speaker.plus.fill", "Volume up")
        case "KEY_MUTE": (symbol, title) = ("speaker.slash.fill", "Mute")
        case "KEY_SOURCE": (symbol, title) = ("rectangle.on.rectangle", "Input source")
        case "KEY_HOME": (symbol, title) = ("house.fill", "Home")
        default: (symbol, title) = ("circle", key)
        }
    }
}

/// A custom name for any device, kept in neo-node only (the name on Tuya or the device is untouched),
/// plus a room for WiZ and Samsung devices, which don't report one over the local network.
struct DeviceNameAndRoom: View {
    @Environment(DeviceStore.self) private var store
    let device: TuyaDevice
    @State private var name = ""
    @State private var renameOnServer = false
    @State private var isSaving = false

    private var original: String? { store.originalName(of: device.id) }
    private var serverRenameAvailable: Bool { store.canRenameOnServer(device.id) }

    private func save() {
        guard name != device.name else { return }
        if renameOnServer, serverRenameAvailable {
            isSaving = true
            Task {
                await store.renameOnServer(device.id, to: name)
                isSaving = false
            }
        } else {
            store.rename(device.id, to: name)
        }
    }
    private var isCustom: Bool { store.localNames[device.id] != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Name")
                Spacer()
                TextField(original ?? "Name", text: $name)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .onSubmit(save)
                if isSaving { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            VStack(alignment: .leading, spacing: 4) {
                if !DeviceStore.isLocal(device.id) { // WiZ / Samsung: neo-node is the only place to rename
                    Picker("Rename", selection: $renameOnServer) {
                        Text("neo-node only").tag(false)
                        Text("Also on Tuya").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(!serverRenameAvailable)
                }
                Text(renameHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            if isCustom, let original {
                HStack {
                    Text("Original: \(original)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Reset") {
                        store.rename(device.id, to: "")
                        name = original
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }

            if DeviceStore.isLocal(device.id) {
                Divider().padding(.horizontal, 14)

                Picker("Room", selection: Binding(
                    get: { store.room(for: device.id)?.id ?? "" },
                    set: { store.assignRoom($0.isEmpty ? nil : $0, to: device.id) }
                )) {
                    Text("None").tag("")
                    ForEach(store.knownRooms, id: \.id) { room in
                        Text(room.name).tag(room.id)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .onAppear { name = device.name }
        .onDisappear(perform: save)
    }

    private var renameHint: String {
        if serverRenameAvailable {
            return renameOnServer
                ? "Renames it in the Smart Life / Tuya app too."
                : "Only neo-node shows the new name."
        }
        if DeviceStore.isLocal(device.id) {
            return "WiZ and Samsung names can only be changed in neo-node."
        }
        return "Renaming on Tuya needs the Cloud project sign-in; the Smart Life sign-in can't change server names. Rename it in the Smart Life app instead."
    }
}

enum SyncModeSymbol {
    /// The WiZ app's icons for its TV-sync modes.
    static func symbol(for mode: String) -> String {
        switch mode {
        case "Cinematic": "film"
        case "Vibrant": "gamecontroller"
        case "Relaxation": "sofa"
        case "Rhythmic": "headphones"
        default: "tv"
        }
    }
}

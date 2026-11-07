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

            if DeviceStore.isLocal(device.id) {
                LocalDeviceSettings(device: device)
            }

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

/// Name and room for WiZ and Samsung devices, which don't report either over the local network.
struct LocalDeviceSettings: View {
    @Environment(DeviceStore.self) private var store
    let device: TuyaDevice
    @State private var name = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Name")
                Spacer()
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .onSubmit { store.rename(device.id, to: name) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

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
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .onAppear { name = device.name }
        .onDisappear { if name != device.name { store.rename(device.id, to: name) } }
    }
}

import ServiceManagement
import SwiftUI

struct SettingsPane: View {
    @Environment(DeviceStore.self) private var store
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                GlassIconButton(systemImage: "chevron.left", help: "Back") { store.route = .devices }
                Text("Settings")
                    .font(.title2.weight(.bold))
                Spacer()
            }

            HStack(spacing: 12) {
                Image(systemName: accountSymbol)
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(accountTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text(accountDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))

            if let message = store.errorMessage {
                ErrorBanner(message: message) { store.errorMessage = nil }
            }

            LocalNetworkSettings()

            Toggle("Hide offline devices", isOn: Binding(
                get: { store.hidesOfflineDevices },
                set: { newValue in withAnimation(.smooth) { store.hidesOfflineDevices = newValue } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        store.errorMessage = error.localizedDescription
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }

            HStack {
                if store.account != nil {
                    Button("Sign Out", role: .destructive) { store.signOut() }
                        .buttonStyle(.glass)
                }
                Spacer()
                Button("Quit NeoNode") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.glass)
                    .keyboardShortcut("q")
            }
            .controlSize(.large)
        }
        .padding(16)
    }

    private var accountSymbol: String {
        switch store.account {
        case .cloudProject: "cloud.fill"
        default: "person.crop.circle.fill"
        }
    }

    private var accountTitle: String {
        switch store.account {
        case .smartLife(let session): session.username ?? "Smart Life account"
        case .cloudProject: "Tuya Cloud project"
        case nil: store.isDemo ? "Demo devices" : "Not signed in"
        }
    }

    private var accountDetail: String {
        switch store.account {
        case .smartLife(let session): "Smart Life · \(URL(string: session.endpoint)?.host() ?? session.endpoint)"
        case .cloudProject(let credentials): "\(credentials.region.title) · \(credentials.accessID.prefix(8))…"
        case nil: "\(store.devices.count) devices"
        }
    }
}

/// Scans for WiZ lights and Samsung screens, or adds a screen by IP when discovery can't see it.
struct LocalNetworkSettings: View {
    @Environment(DeviceStore.self) private var store
    @State private var isScanning = false
    @State private var result: String?
    @State private var screenIP = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wi‑Fi devices")
                        .font(.headline)
                    Text(result ?? "Philips WiZ lights and Samsung TVs or monitors")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    isScanning = true
                    Task {
                        let count = await store.scanLocalNetwork()
                        result = count == 1 ? "Found 1 device" : "Found \(count) devices"
                        isScanning = false
                    }
                } label: {
                    if isScanning { ProgressView().controlSize(.small) } else { Text("Scan") }
                }
                .buttonStyle(.glass)
                .disabled(isScanning)
            }
            HStack {
                TextField("Samsung screen IP, e.g. 192.168.1.20", text: $screenIP)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular.interactive(), in: .capsule)
                Button("Add") {
                    Task {
                        do {
                            try await store.addSamsungScreen(ip: screenIP)
                            result = "Added \(screenIP)"
                            screenIP = ""
                        } catch {
                            store.errorMessage = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.glass)
                .disabled(screenIP.isEmpty)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

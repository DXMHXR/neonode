import AppKit
import SwiftUI

struct MenuContentView: View {
    @Environment(DeviceStore.self) private var store

    var body: some View {
        Group {
            if !store.isConfigured {
                LoginView()
            } else {
                switch store.route {
                case .devices:
                    DeviceGridView()
                case .detail(let id):
                    if let device = store.device(id) {
                        DeviceDetailView(device: device)
                    } else {
                        DeviceGridView()
                    }
                case .settings:
                    SettingsPane()
                }
            }
        }
        .frame(width: 340)
        .animation(.smooth(duration: 0.28), value: store.route)
        .task {
            await store.refresh(force: true)
            await store.runLaunchDiagnostics()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await store.refresh() }
        }
    }
}

/// Round glass icon button used in headers.
struct GlassIconButton: View {
    let systemImage: String
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(help)
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .glassEffect(.regular.tint(.yellow.opacity(0.15)), in: .rect(cornerRadius: 14))
    }
}

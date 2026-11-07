import SwiftUI

@main
struct NeoNodeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Migration runs first: the store reads saved settings while it's created.
    @State private var store: DeviceStore = {
        Migration.run()
        return DeviceStore(arguments: ProcessInfo.processInfo.arguments)
    }()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Window("Cameras", id: CameraWindow.id) {
            CameraWindowView()
                .environment(store)
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unifiedCompact)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        // `-window` shows the same content in a regular window (screenshots, UI work).
        Window("neo-node", id: "preview") {
            MenuContentView()
                .environment(store)
                .padding(24)
                .background {
                    LinearGradient(colors: [.indigo, .purple, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .ignoresSafeArea()
                }
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed) // opened by MenuBarLabel for `-window`
    }
}

/// The menu bar icon. It lives for the whole session, so it also opens the camera window
/// for `-openCameras` the same way clicking a camera tile does.
private struct MenuBarLabel: View {
    let store: DeviceStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: store.poweredOnCount > 0 ? "lightbulb.2.fill" : "lightbulb.2")
            .task {
                if store.showsPreviewWindow { openWindow(id: "preview") }
                guard store.opensCamerasAtLaunch else { return }
                openWindow(id: CameraWindow.id)
                NSApplication.shared.activate()
            }
    }
}

import AppKit
import CoreTransferable
import SwiftUI

/// The camera monitor window: opens at the top-right of the screen, shows every opened camera
/// side by side, and resizes from the toolbar's size menu (fullscreen is disabled).
enum CameraWindow {
    static let id = "cameras"
    static let spacing: CGFloat = 8
    static let padding: CGFloat = 10
    static let screenMargin: CGFloat = 12
    static let cornerRadius: CGFloat = 22

    static func columns(for count: Int) -> Int {
        switch count {
        case ...1: 1
        case 2: 2
        case 3: 3
        case 4: 2
        default: 3
        }
    }

    /// Tile size for `count` cameras at `preset`, shrunk so the window fits the visible screen.
    static func tileSize(count: Int, preset: CameraWindowSize, screen: NSRect) -> CGSize {
        let columns = CGFloat(columns(for: count))
        let rows = CGFloat((max(count, 1) + Int(columns) - 1) / Int(columns))
        let chrome = 2 * padding + 2 * screenMargin
        let maxWidth = (screen.width - chrome - (columns - 1) * spacing) / columns
        let maxHeight = (screen.height - chrome - 60 - (rows - 1) * spacing) / rows // 60: toolbar
        let width = min(preset.tileWidth, maxWidth, maxHeight * 16 / 9)
        return CGSize(width: width.rounded(), height: (width * 9 / 16).rounded())
    }
}

/// Drag payload for rearranging monitors (prefixed so room headers ignore it).
struct CameraDragID: Transferable {
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: { "camera:" + $0.id }, importing: { (value: String) in
            CameraDragID(id: value.hasPrefix("camera:") ? String(value.dropFirst("camera:".count)) : "")
        })
    }
}

struct CameraWindowView: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var dropTarget: String?

    private var screen: NSRect { NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900) }

    var body: some View {
        let cameras = store.openCameras
        let columns = CameraWindow.columns(for: cameras.count)
        let tile = CameraWindow.tileSize(count: cameras.count, preset: store.cameraWindowSize, screen: screen)

        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(tile.width), spacing: CameraWindow.spacing), count: columns),
            spacing: CameraWindow.spacing
        ) {
            ForEach(cameras) { camera in
                CameraTile(device: camera, size: tile, isDropTarget: dropTarget == camera.id)
                    .dropDestination(for: CameraDragID.self) { items, _ in
                        guard let dragged = items.first?.id, !dragged.isEmpty else { return false }
                        withAnimation(.smooth) { store.moveCamera(dragged, to: camera.id) }
                        return true
                    } isTargeted: { targeted in
                        dropTarget = targeted ? camera.id : (dropTarget == camera.id ? nil : dropTarget)
                    }
            }
        }
        .padding(CameraWindow.padding)
        .fixedSize()
        // Liquid Glass behind the whole window, toolbar included; the window itself is see-through.
        .background {
            Rectangle()
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: CameraWindow.cornerRadius))
                .ignoresSafeArea()
        }
        // Title drawn over the title bar, centered on the whole window. A toolbar `.principal`
        // item centers between the traffic lights and the size button, which drifts right in narrow windows.
        .overlay(alignment: .top) {
            GeometryReader { proxy in
                // Room left between the traffic lights and the size button; narrow single-camera
                // windows may have none, and an empty capsule would show as a bare circle.
                let textWidth = proxy.size.width - 2 * 110 - 28
                Group {
                    if textWidth >= 60 {
                        Text(cameras.count == 1 ? cameras[0].name : "\(cameras.count) Cameras")
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: textWidth)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .glassEffect(.regular, in: .capsule)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.safeAreaInsets.top)
                .offset(y: -proxy.safeAreaInsets.top)
                .allowsHitTesting(false)
            }
        }
        .containerBackground(.clear, for: .window)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .animation(.smooth(duration: 0.3), value: store.openCameraIDs)
        .toolbar {
            ToolbarSpacer(.flexible) // keeps the size button at the trailing edge without a toolbar title
            ToolbarItem(placement: .primaryAction) { sizeMenu }
        }
        // The window title is drawn by hand (centered); drop the toolbar's own title so narrow
        // windows don't push the size button into an overflow menu.
        .toolbar(removing: .title)
        .background(WindowConfigurator(
            layoutKey: "\(cameras.count)-\(store.cameraWindowSize.rawValue)",
            stayOnTop: store.camerasStayOnTop
        ))
        .onChange(of: store.openCameraIDs.isEmpty) { _, isEmpty in
            if isEmpty { dismissWindow(id: CameraWindow.id) }
        }
        .onDisappear { store.openCameraIDs = [] }
        .task { await store.openLaunchCameras() }
    }

    private var sizeMenu: some View {
        @Bindable var store = store
        return Menu {
            Picker("Window Size", selection: $store.cameraWindowSize) {
                ForEach(CameraWindowSize.allCases) { size in
                    Text(size.title).tag(size)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Keep on Top", isOn: $store.camerasStayOnTop)
            Divider()
            Button("Close All Cameras") { store.openCameraIDs = [] }
        } label: {
            Label("Window Size", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .help("Window size")
    }
}

/// Reaches the hosting NSWindow: disables fullscreen, applies "Keep on Top", opens the window at the
/// top-right corner, and keeps its right edge in place when it grows or shrinks (AppKit keeps the left).
private struct WindowConfigurator: NSViewRepresentable {
    let layoutKey: String
    let stayOnTop: Bool

    @MainActor
    final class Coordinator {
        weak var window: NSWindow?
        var lastFrame: NSRect?
        var observers: [NSObjectProtocol] = []

        func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            self.window = window
            pinToTopRight(window)
            observers = [
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.keepRightEdge() }
                },
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didMoveNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.trackMove() }
                },
            ]
        }

        private func pinToTopRight(_ window: NSWindow) {
            guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
            window.setFrameOrigin(NSPoint(
                x: visible.maxX - window.frame.width - CameraWindow.screenMargin,
                y: visible.maxY - window.frame.height - CameraWindow.screenMargin
            ))
            lastFrame = window.frame
        }

        private func keepRightEdge() {
            guard let window, let last = lastFrame else { return }
            var frame = window.frame
            if frame.width != last.width || frame.height != last.height {
                frame.origin.x = last.maxX - frame.width
                frame.origin.y = last.maxY - frame.height
                if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
                    frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
                    frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
                }
                lastFrame = frame
                window.setFrame(frame, display: true)
            }
        }

        func trackMove() {
            if let window { lastFrame = window.frame }
        }

        isolated deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let onTop = stayOnTop
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.collectionBehavior.remove(.fullScreenPrimary)
            window.collectionBehavior.insert(.fullScreenNone)
            window.level = onTop ? .floating : .normal
            window.isMovableByWindowBackground = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            coordinator.attach(to: window)
        }
    }
}

import AppKit
import SwiftUI

struct DeviceGridView: View {
    @Environment(DeviceStore.self) private var store
    @State private var dropTarget: String?
    /// Room picked in the shortcut grid; `nil` shows every room.
    @AppStorage("selectedRoom") private var selectedRoom: String?
    @State private var scrollPosition = ScrollPosition(edge: .top)
    /// How much content is hidden below the visible part of the device list.
    @State private var hiddenBelow: CGFloat = 0
    @State private var scrollMetrics = ScrollMetrics()
    @State private var isScrolling = false

    private var visibleSections: [DeviceStore.Section] {
        let sections = store.sections
        guard let selectedRoom, let match = sections.first(where: { $0.id == selectedRoom }) else { return sections }
        return [match]
    }

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    private let tileHeight: CGFloat = 104

    var body: some View {
        VStack(spacing: 14) {
            header

            if let message = store.errorMessage {
                ErrorBanner(message: message) { store.errorMessage = nil }
            }

            if store.devices.isEmpty || store.sections.isEmpty {
                emptyState
            } else {
                if store.sections.count > 1 {
                    RoomShortcuts(sections: store.sections, selection: $selectedRoom)
                }
                ScrollView {
                    GlassEffectContainer(spacing: 10) {
                        LazyVStack(alignment: .leading, spacing: sectionSpacing) {
                            ForEach(visibleSections) { section in
                                VStack(alignment: .leading, spacing: 8) {
                                    if let title = section.title {
                                        SectionHeader(section: section, title: title, isDropTarget: dropTarget == section.id)
                                            .dropDestination(for: String.self) { ids, _ in
                                                guard let id = ids.first else { return false }
                                                withAnimation(.smooth) { store.moveSection(id, to: section.id) }
                                                return true
                                            } isTargeted: { targeted in
                                                dropTarget = targeted ? section.id : (dropTarget == section.id ? nil : dropTarget)
                                            }
                                    }
                                    LazyVGrid(columns: columns, spacing: 10) {
                                        ForEach(section.devices) { device in
                                            DeviceTile(device: device, height: tileHeight)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(2)
                        // Inset the tiles so the scroller sits in the menu's side margin, clear of the grid.
                        .padding(.horizontal, 16)
                    }
                }
                .scrollIndicators(.never)
                .padding(.horizontal, -16)
                .scrollEdgeEffectStyle(.soft, for: .vertical)
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                    ScrollMetrics(
                        offset: geometry.contentOffset.y,
                        content: geometry.contentSize.height,
                        visible: geometry.containerSize.height
                    )
                } action: { _, metrics in
                    scrollMetrics = metrics
                    hiddenBelow = max(0, metrics.content - metrics.offset - metrics.visible)
                }
                .onScrollPhaseChange { _, phase in
                    isScrolling = phase != .idle
                }
                .overlay(alignment: .topTrailing) {
                    ScrollIndicator(metrics: scrollMetrics, isVisible: isScrolling)
                        .padding(.trailing, -11) // in the menu's side margin, clear of the tiles
                }
                .overlay(alignment: .bottom) {
                    if hiddenBelow > 8 {
                        MoreBelowButton {
                            withAnimation(.smooth(duration: 0.4)) { scrollPosition.scrollTo(edge: .bottom) }
                        }
                        .padding(.bottom, 6)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .animation(.smooth(duration: 0.2), value: hiddenBelow > 8)
                .onChange(of: selectedRoom) { scrollPosition.scrollTo(edge: .top) }
                .frame(height: gridHeight)
                .animation(.smooth(duration: 0.3), value: selectedRoom)
            }

            footer
        }
        .padding(16)
    }

    private let sectionSpacing: CGFloat = 16
    private let headerHeight: CGFloat = 26

    /// Content height of all sections, capped so the menu never outgrows the screen.
    private var gridHeight: CGFloat {
        let sections = visibleSections
        let content = sections.reduce(CGFloat(0)) { total, section in
            let rows = CGFloat((section.devices.count + 1) / 2)
            let header = section.title == nil ? 0 : headerHeight
            return total + header + rows * tileHeight + max(rows - 1, 0) * 10
        } + CGFloat(max(sections.count - 1, 0)) * sectionSpacing + 4
        let rooms = store.sections.count
        return min(content, maxGridHeight(shortcutRooms: rooms > 1 ? rooms + 1 : 0))
    }

    /// The whole menu stays within 40% of the screen's height while showing all rooms,
    /// and within 80% when one room is picked, so a busy room gets the space it needs.
    private func maxGridHeight(shortcutRooms: Int) -> CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 900
        let isRoomPicked = store.sections.count > 1 && visibleSections.count == 1
        let menuLimit = visible * (isRoomPicked ? 0.8 : 0.4)
        let shortcutRows = CGFloat((shortcutRooms + 2) / 3)
        let shortcuts = shortcutRows > 0 ? shortcutRows * 66 + (shortcutRows - 1) * 8 + 14 : 0
        let chrome: CGFloat = 32 + 50 + 14 + 44 + 14 // padding, header, spacing, footer, spacing
        return max(tileHeight * 2 + 10, menuLimit - chrome - shortcuts)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Home")
                    .font(.title2.weight(.bold))
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    GlassIconButton(systemImage: "arrow.clockwise", help: "Refresh") {
                        Task { await store.refresh(force: true, reloadRooms: true) }
                    }
                    .symbolEffect(.rotate, isActive: store.isRefreshing)
                    GlassIconButton(systemImage: "gearshape", help: "Settings") {
                        store.route = .settings
                    }
                }
            }
        }
    }

    private var summary: String {
        let on = store.poweredOnCount
        let online = store.devices.filter(\.online).count
        if store.devices.isEmpty { return store.isRefreshing ? "Loading devices…" : "No devices" }
        let base = on == 0 ? "Everything is off · \(online) online" : "\(on) on · \(online) online"
        let hidden = store.hidesOfflineDevices ? store.offlineCount : 0
        return hidden > 0 ? base + " · \(hidden) hidden" : base
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if store.isRefreshing {
                ProgressView().controlSize(.small)
            } else if !store.devices.isEmpty {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("All devices are offline")
                    .font(.headline)
                Button("Show Offline Devices") {
                    withAnimation(.smooth) { store.hidesOfflineDevices = false }
                }
                .buttonStyle(.glass)
            } else {
                Image(systemName: "house")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("No devices found")
                    .font(.headline)
                Text("Link your Smart Life or Tuya app account to the Cloud project, then refresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private var footer: some View {
        HStack {
            Button {
                withAnimation(.smooth) { store.turnEverythingOff() }
            } label: {
                Label("All Off", systemImage: "power")
            }
            .buttonStyle(.glass)
            .disabled(store.poweredOnCount == 0)

            Spacer()

            if store.isDemo {
                Text("Demo")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .glassEffect(.regular.tint(.purple.opacity(0.3)), in: .capsule)
            }
        }
        .controlSize(.large)
    }
}

/// Room title; drag it onto another room's title to reorder, or use its context menu.
/// A compact grid of rooms above the devices: click to show only that room, right-click to switch it all on or off.
struct RoomShortcuts: View {
    @Environment(DeviceStore.self) private var store
    let sections: [DeviceStore.Section]
    @Binding var selection: String?
    @State private var dropTarget: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    /// The picked room, or `nil` (All Rooms) when it no longer exists.
    private var current: String? {
        sections.contains { $0.id == selection } ? selection : nil
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            LazyVGrid(columns: columns, spacing: 8) {
                RoomShortcut(
                    title: "All Rooms",
                    symbol: "house",
                    devices: sections.flatMap(\.devices),
                    isSelected: current == nil,
                    isDropTarget: false,
                    move: nil
                ) { selection = nil }
                ForEach(sections) { section in
                    let movable = section.id != DeviceStore.otherSectionID
                    RoomShortcut(
                        title: section.title ?? "",
                        symbol: RoomSymbol.symbol(for: section.title ?? ""),
                        devices: section.devices,
                        isSelected: current == section.id,
                        isDropTarget: dropTarget == section.id,
                        move: movable ? { offset in
                            withAnimation(.smooth) { store.moveSection(section.id, by: offset) }
                        } : nil
                    ) {
                        // Clicking the selected room again goes back to all rooms.
                        selection = current == section.id ? nil : section.id
                    }
                    // "All Rooms" stays first and "Other" stays last: only the rooms in between move.
                    .draggable(section.id) {
                        Label(section.title ?? "", systemImage: RoomSymbol.symbol(for: section.title ?? ""))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .glassEffect(.regular, in: .capsule)
                    }
                    .dropDestination(for: String.self) { ids, _ in
                        guard movable, let id = ids.first else { return false }
                        withAnimation(.smooth) { store.moveSection(id, to: section.id) }
                        return true
                    } isTargeted: { targeted in
                        guard movable else { return }
                        dropTarget = targeted ? section.id : (dropTarget == section.id ? nil : dropTarget)
                    }
                }
            }
        }
    }
}

private struct RoomShortcut: View {
    @Environment(DeviceStore.self) private var store
    let title: String
    let symbol: String
    let devices: [TuyaDevice]
    let isSelected: Bool
    let isDropTarget: Bool
    /// Moves the room by an offset in the order; `nil` for "All Rooms" and "Other", which are fixed.
    let move: ((Int) -> Void)?
    let action: () -> Void

    private var switchable: [TuyaDevice] {
        devices.filter { $0.online && $0.powerCode != nil && !$0.isCamera }
    }

    private var onCount: Int { switchable.filter(\.isOn).count }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .symbolVariant(onCount > 0 ? .fill : .none)
                    .foregroundStyle(onCount > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .frame(height: 18, alignment: .leading)
                Spacer(minLength: 0)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(onCount > 0 ? "\(onCount) on" : "All off")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 66, maxHeight: 66, alignment: .leading)
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        isDropTarget ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(isSelected ? 0.9 : 0)),
                        style: StrokeStyle(lineWidth: 2, dash: isDropTarget ? [5, 3] : [])
                    )
            }
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .glassEffect(
            isSelected
                ? .regular.tint(.accentColor.opacity(0.55)).interactive()
                : onCount > 0 ? .regular.tint(.orange.opacity(0.25)).interactive() : .regular.interactive(),
            in: .rect(cornerRadius: 16)
        )
        .help(isSelected ? "Showing \(title)" : "Show \(title)")
        .contextMenu {
            Button("Turn On All") { setAll(on: true) }
                .disabled(switchable.allSatisfy(\.isOn))
            Button("Turn Off All") { setAll(on: false) }
                .disabled(onCount == 0)
            if let move {
                Divider()
                Button("Move Left") { move(-1) }
                Button("Move Right") { move(1) }
            }
        }
    }

    private func setAll(on: Bool) {
        withAnimation(.smooth) {
            for device in switchable where device.isOn != on {
                store.toggle(device)
            }
        }
    }
}

enum RoomSymbol {
    /// A symbol guessed from the room name (English and Indonesian).
    static func symbol(for name: String) -> String {
        let n = name.lowercased()
        let table: [([String], String)] = [
            (["kid", "anak", "child", "nursery"], "teddybear"),
            (["bed", "kamar", "tidur", "master"], "bed.double"),
            (["living", "tamu", "tengah", "family", "keluarga"], "sofa"),
            (["kitchen", "dapur"], "fork.knife"),
            (["dining", "makan"], "takeoutbag.and.cup.and.straw"),
            (["bath", "mandi", "toilet", "wc"], "shower"),
            (["office", "study", "kerja", "work"], "desktopcomputer"),
            (["terrace", "teras", "garden", "taman", "yard", "halaman", "balcon"], "tree"),
            (["garage", "garasi", "carport"], "car"),
            (["laundry", "cuci"], "washer"),
            (["stair", "tangga", "hall", "lorong"], "stairs"),
        ]
        return table.first { keys, _ in keys.contains { n.contains($0) } }?.1 ?? "square.split.2x2"
    }
}

struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var content: CGFloat = 0
    var visible: CGFloat = 0
}

/// A thin scroll position bar that shows only while scrolling, then fades out.
/// Drawn by hand because AppKit's scroller ignores the overlay style when "Show scroll bars" is Always.
struct ScrollIndicator: View {
    let metrics: ScrollMetrics
    let isVisible: Bool

    @State private var shown = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            let track = proxy.size.height
            if metrics.content > metrics.visible + 1, track > 0 {
                let ratio = metrics.visible / metrics.content
                let knob = max(28, track * ratio)
                let progress = min(max(metrics.offset / (metrics.content - metrics.visible), 0), 1)
                Capsule()
                    .fill(.primary.opacity(0.45))
                    .frame(width: 5, height: knob)
                    .offset(y: (track - knob) * progress)
                    .opacity(shown ? 1 : 0)
            }
        }
        .frame(width: 5)
        .padding(.vertical, 4)
        .allowsHitTesting(false)
        .onChange(of: isVisible) { _, visible in
            hideTask?.cancel()
            if visible {
                withAnimation(.easeOut(duration: 0.15)) { shown = true }
            } else {
                hideTask = Task {
                    try? await Task.sleep(for: .seconds(0.8))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeIn(duration: 0.4)) { shown = false }
                }
            }
        }
    }
}

/// Floating hint that the device list continues below; click to scroll to the end.
struct MoreBelowButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("More", systemImage: "chevron.down")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .help("Scroll to the end")
    }
}

struct SectionHeader: View {
    @Environment(DeviceStore.self) private var store
    let section: DeviceStore.Section
    let title: String
    let isDropTarget: Bool

    @State private var isHovering = false

    private var countText: String {
        let total = section.devices.count
        let on = section.devices.filter { $0.online && $0.isOn }.count
        if on > 0 { return "\(on) of \(total) on" }
        return total == 1 ? "1 device" : "\(total) devices"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.headline)
            Spacer()
            Text(countText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            Image(systemName: "line.3.horizontal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .opacity(isHovering || isDropTarget ? 1 : 0)
        }
        .padding(.horizontal, 4)
        .frame(height: 18)
        .contentShape(.rect)
        .background {
            Capsule()
                .fill(.tint.opacity(isDropTarget ? 0.25 : 0))
                .padding(.horizontal, -6)
                .padding(.vertical, -4)
        }
        .onHover { isHovering = $0 }
        .draggable(section.id) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
        }
        .contextMenu {
            let ids = store.sections.map(\.id)
            Button("Move Up") { withAnimation(.smooth) { store.moveSection(section.id, by: -1) } }
                .disabled(ids.first == section.id)
            Button("Move Down") { withAnimation(.smooth) { store.moveSection(section.id, by: 1) } }
                .disabled(ids.last == section.id)
            Divider()
            Button("Reset Room Order") { withAnimation(.smooth) { store.resetSectionOrder() } }
                .disabled(!store.hasCustomSectionOrder)
        }
        .help("Drag onto another room to reorder")
    }
}

struct DeviceTile: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let device: TuyaDevice
    let height: CGFloat

    var body: some View {
        let on = device.online && device.isOn

        Button {
            if device.isCamera {
                store.openCamera(device.id)
                openWindow(id: CameraWindow.id)
                NSApplication.shared.activate()
            } else {
                withAnimation(.smooth(duration: 0.25)) { store.toggle(device) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    Image(systemName: device.symbol)
                        .symbolVariant(on ? .fill : .none)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(on ? device.tint : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 30, height: 30, alignment: .leading)
                    Spacer()
                }
                Spacer(minLength: 0)
                Text(device.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if !device.online {
                        Circle().fill(.red).frame(width: 6, height: 6)
                    }
                    Text(device.stateText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                    if DeviceStore.isLocal(device.id) {
                        LocalOnlyBadge()
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .disabled(!device.online || (device.powerCode == nil && !device.isCamera))
        .glassEffect(
            on ? .regular.tint(device.tint.opacity(0.4)).interactive() : .regular.interactive(),
            in: .rect(cornerRadius: 22)
        )
        .opacity(device.online ? 1 : 0.6)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 6) {
                if store.pending.contains(device.id) {
                    ProgressView().controlSize(.mini)
                }
                Button {
                    store.route = .detail(device.id)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 26, height: 26)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .help("Details")
            }
            .padding(8)
        }
        .contextMenu {
            Button("Details…") { store.route = .detail(device.id) }
            if device.powerCode != nil, device.online, !device.isCamera {
                Button(device.isOn ? "Turn Off" : "Turn On") { store.toggle(device) }
            }
        }
    }
}

/// Marks WiZ and Samsung devices, which NeoNode reaches over this Wi‑Fi only (not away from home).
struct LocalOnlyBadge: View {
    var body: some View {
        Label("Local only", systemImage: "wifi")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.secondary.opacity(0.15), in: .capsule)
            .help("Controlled over your Wi‑Fi only; not available away from home")
    }
}

import SwiftUI
import QuartzCore
import WebRTC

struct DesktopView: View {
    @ObservedObject var center: DesktopCenter
    @Environment(\.openWindow) private var openWindow
    @State private var settingsSheet: SettingsSheet?
    private enum SettingsSheet: String, Identifiable {
        case permissions, unattended, privacy
        var id: String { rawValue }
    }
    private var showPermissions: Binding<Bool> {
        Binding(get: { settingsSheet == .permissions }, set: { settingsSheet = $0 ? .permissions : nil })
    }
    private var devices: [DesktopPeer] {
        var result = center.viewerSessions.compactMap(\.peer)
        if let host = center.peer, !result.contains(where: { $0.id == host.id }) { result.append(host) }
        for peer in center.peers where !result.contains(where: { $0.id == peer.id }) { result.append(peer) }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            settingsShortcuts
            DesktopPermissionReminder(center: center, showPermissions: showPermissions)
            DesktopMessage(center: center)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("同账号设备").font(.headline)
                    Text("\(devices.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(.quaternary, in: Capsule())
                    Spacer()
                    Button { Task { await center.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                        .buttonStyle(.borderless).controlSize(.small).disabled(!center.online).help("刷新设备列表")
                }
                if !center.enabled {
                    ContentUnavailableView("连接你的另一台 Mac", systemImage: "display.2",
                        description: Text("在两台 Mac 上登录同一账户，并开启远程桌面。"))
                } else if devices.isEmpty {
                    ContentUnavailableView("暂无在线设备", systemImage: "desktopcomputer",
                        description: Text("在另一台 Mac 登录相同账户并开启远程桌面。设备列表会自动更新。"))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(devices) { peer in
                                if let viewer = center.viewer(for: peer.id) {
                                    DesktopConnectedCard(center: viewer, portService: center.portService)
                                } else if center.peer?.id == peer.id {
                                    DesktopConnectedCard(center: center, portService: center.portService)
                                } else {
                                    DesktopAvailableCard(peer: peer, portService: center.portService, canConnect: center.online && center.invitation == nil) {
                                        center.connect(to: peer)
                                    }
                                }
                            }
                        }.padding(.bottom, 2)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if center.online && !center.relayAvailable {
                Label("当前服务支持设备直连，部分跨网连接可能无法建立。", systemImage: "network")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("当前服务未配置 TURN 中继：内网、Tailscale 或可打洞的网络可直连。")
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $settingsSheet) { sheet in
            switch sheet {
            case .permissions: DesktopPermissionSettingsView(center: center)
            case .unattended: DesktopUnattendedSettingsView(center: center)
            case .privacy: DesktopPrivacySettingsSheet(center: center, library: center.privacyLibrary)
            }
        }
        .onChange(of: center.enabled) { _, _ in center.permissions.refresh() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "display.2").font(.system(size: 22, weight: .medium)).foregroundStyle(Color.accentColor)
                .frame(width: 46, height: 46).background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text("远程桌面").font(.system(size: 22, weight: .semibold))
                HStack(spacing: 6) {
                    Circle().fill(center.online ? Color.green : .secondary).frame(width: 6, height: 6)
                    Text(center.status).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { center.portService.activateMappingWindow(); openWindow(id: "ports") } label: { Label("端口映射", systemImage: "arrow.left.arrow.right") }
                .controlSize(.regular)
            Toggle("开启远程桌面", isOn: $center.enabled).toggleStyle(.switch).font(.callout).fixedSize()
        }
    }

    private var settingsShortcuts: some View {
        HStack(spacing: 0) {
            DesktopSettingsShortcut(title: "访问权限", subtitle: permissionSummary, symbol: "lock.shield") {
                settingsSheet = .permissions
            }
            Divider().frame(height: 28)
            DesktopSettingsShortcut(title: "无人值守", subtitle: unattendedSummary, symbol: "checkmark.shield") {
                settingsSheet = .unattended
            }.disabled(!center.canConfigureUnattended)
            Divider().frame(height: 28)
            DesktopPrivacyShortcut(center: center, library: center.privacyLibrary) { settingsSheet = .privacy }
        }
        .padding(4).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private var permissionSummary: String {
        let missing = center.permissions.snapshot.missing(control: true).count
        return missing == 0 ? "此电脑权限已就绪" : "\(missing) 项权限待授权"
    }
    private var unattendedSummary: String {
        guard center.unattended.enabled else { return "每次连接时确认" }
        if !center.enabled { return "已配置 · 待开启远程桌面" }
        if !center.permissions.snapshot.missing(control: center.unattended.control).isEmpty { return "已配置 · 等待权限授权" }
        return "已开启 · 免确认连接"
    }
}

struct DesktopSettingsShortcut: View {
    let title: String
    let subtitle: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.callout.weight(.medium)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).help("\(title)：\(subtitle)")
            .accessibilityElement(children: .ignore).accessibilityLabel("\(title)，\(subtitle)")
    }
}

private struct DesktopPrivacyShortcut: View {
    @ObservedObject var center: DesktopCenter
    @ObservedObject var library: DesktopPrivacyLibrary
    let action: () -> Void
    private var summary: String {
        if center.isHost {
            if center.privacyChanging { return "正在切换…" }
            if !center.privacyStateKnown { return "本次共享状态未确认" }
            if center.privacyPausedForLock { return "锁屏期间暂停" }
            if center.privacyActive { return "本次共享已开启" }
            if center.privacyRequested { return "已启用 · 等待显示" }
            return "本次共享未开启"
        }
        return library.settings.automatic ? "连接时自动启用" : "连接时手动启用"
    }
    var body: some View {
        DesktopSettingsShortcut(title: "隐私屏", subtitle: summary, symbol: "lock.display", action: action)
    }
}

private struct DesktopDeviceIcon: View {
    var body: some View {
        Image(systemName: "desktopcomputer").font(.system(size: 22, weight: .regular)).foregroundStyle(.secondary)
            .frame(width: 44, height: 44).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct DesktopAvailableCard: View {
    let peer: DesktopPeer
    @ObservedObject var portService: DesktopPortService
    @Environment(\.openWindow) private var openWindow
    let canConnect: Bool
    let connect: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            DesktopDeviceIcon()
            VStack(alignment: .leading, spacing: 5) {
                Text(peer.name).font(.headline).lineLimit(1).help(peer.name)
                Text("在线 · 可连接").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("端口映射") { portService.openMapping(for: peer); openWindow(id: "ports") }
                .disabled(portService.settingsAccountID == nil)
            Button("连接", action: connect).buttonStyle(.borderedProminent).disabled(!canConnect)
        }.controlSize(.small).padding(16)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct DesktopPermissionReminder: View {
    @ObservedObject var center: DesktopCenter
    @Binding var showPermissions: Bool
    var body: some View {
        let permissions = center.permissions
        let control = permissions.requester != nil ? permissions.requestedControl : center.unattended.control
        let missing = permissions.snapshot.missing(control: control)
        if center.enabled && (permissions.requester != nil || center.unattended.enabled && !missing.isEmpty) {
            HStack(alignment: .top) {
                Image(systemName: missing.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                Text(missing.isEmpty ? "所需权限已生效，请让\(permissions.requester ?? "对方")重新发起连接。" : "\(permissions.requester.map { "\($0) 请求连接此电脑。" } ?? "")请在此电脑授权：\(missing.map(\.title).joined(separator: "、"))。")
                    .font(.callout)
                Spacer()
                Button("检查权限…") { showPermissions = true }
            }.padding(12).foregroundStyle(missing.isEmpty ? .green : .orange)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// 列表只观察连接状态，不创建视频 renderer。
private struct DesktopConnectedCard: View {
    @ObservedObject var center: DesktopCenter
    @ObservedObject var portService: DesktopPortService
    @Environment(\.openWindow) private var openWindow
    @State private var settingsPresented = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                DesktopDeviceIcon()
                VStack(alignment: .leading, spacing: 5) {
                    Text(center.peer?.name ?? "远程电脑").font(.headline).lineLimit(1)
                        .help(center.peer?.name ?? "远程电脑")
                    Text(connectionSummary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 12)
                DesktopLatencyLabel(center: center)
                if let peer = center.peer {
                    Button("端口映射") { portService.openMapping(for: peer); openWindow(id: "ports") }
                        .disabled(portService.settingsAccountID == nil)
                }
                if !center.isHost {
                    Button("打开窗口") { center.showDesktopWindow() }.buttonStyle(.borderedProminent)
                    Button { settingsPresented = true } label: { Image(systemName: "slider.horizontal.3") }
                        .help("连接设置")
                        .popover(isPresented: $settingsPresented) { DesktopViewerSettings(center: center) }
                }
                Button(center.isHost ? "停止共享" : "断开", role: .destructive) { center.disconnect() }
            }
            DesktopFileStatus(center: center)
            DesktopFileReceipt(center: center)
        }.controlSize(.small).padding(16)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
    private var connectionSummary: String {
        guard center.connected else { return center.route }
        let role = center.isHost ? "正在共享此电脑" : "已连接"
        return "\(role) · \(center.route) · \(center.controlAllowed ? "允许控制" : "仅观看")"
    }
}

/// 在控件派发事件前释放焦点，覆盖标签、标题栏空白和原生窗口按钮。
final class DesktopControlWindow: NSWindow {
    static let navigationHeight: CGFloat = 44
    var onReleaseKeyboardFocus: (() -> Void)?

    func releaseKeyboardFocus() {
        (firstResponder as? DesktopVideoNSView)?.releaseKeyboardFocus()
        makeFirstResponder(nil)
        onReleaseKeyboardFocus?()
    }

    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type), let contentView {
            let point = contentView.convert(event.locationInWindow, from: nil)
            let top = contentView.isFlipped ? point.y - contentView.bounds.minY : contentView.bounds.maxY - point.y
            if top >= 0 && top <= Self.navigationHeight { releaseKeyboardFocus() }
        }
        super.sendEvent(event)
    }
}

/// 所有观看连接共用一个窗口；关闭窗口保留连接，并停止渲染和输入。
@MainActor
final class DesktopSessionWindow: NSObject, NSWindowDelegate {
    private weak var center: DesktopCenter?
    private(set) var window: NSWindow?
    init(center: DesktopCenter) { self.center = center }
    func show() {
        guard let center, center.selectedViewer != nil else { return }
        if window == nil {
            let window = DesktopControlWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = false
            window.minSize = NSSize(width: 640, height: 400)
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.tabbingMode = .disallowed
            window.isReleasedWhenClosed = false; window.delegate = self
            window.onReleaseKeyboardFocus = { [weak center] in center?.selectedViewer?.setRemoteShortcutsActive(false) }
            window.contentView = NSHostingView(rootView: DesktopWorkspaceView(center: center))
            window.setFrameAutosaveName("TaoScreen")
            window.center(); self.window = window
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        updatePresentation()
    }
    func close() { window?.close() }
    func releaseKeyboardFocus() { (window as? DesktopControlWindow)?.releaseKeyboardFocus() }
    func updatePresentation() {
        guard let center else { return }
        let visible = window?.isVisible == true && window?.isMiniaturized == false
        window?.title = "\(center.selectedViewer?.peer?.name ?? "远程桌面") · 远程桌面"
        for viewer in center.viewerSessions {
            let selected = viewer.id == center.selectedViewerID
            viewer.setViewerPresented(selected && visible)
            viewer.setViewerWindowActive(selected && visible && window?.isKeyWindow == true)
        }
    }
    func windowDidBecomeKey(_ notification: Notification) { updatePresentation() }
    func windowDidResignKey(_ notification: Notification) { releaseKeyboardFocus(); updatePresentation() }
    func windowDidMiniaturize(_ notification: Notification) { releaseKeyboardFocus(); updatePresentation() }
    func windowDidDeminiaturize(_ notification: Notification) { updatePresentation() }
    func windowWillClose(_ notification: Notification) {
        releaseKeyboardFocus()
        for viewer in center?.viewerSessions ?? [] {
            viewer.setViewerWindowActive(false); viewer.setViewerPresented(false)
            viewer.sendInput(.init(kind: "release"))
        }
        window?.contentView = nil; window = nil
    }
}

/// 图标与浮窗共享悬停状态，移出后延迟隐藏；操作菜单期间暂缓隐藏。
@MainActor final class DesktopConnectionPopoverState: ObservableObject {
    enum HoverRegion { case indicator, panel }
    @Published private(set) var id: UUID?
    private var hoveredRegions: Set<HoverRegion> = []
    private var trackingMenus: Set<ObjectIdentifier> = []
    private var dismissTask: Task<Void, Never>?
    init(id: UUID? = nil) { self.id = id }
    func hover(_ id: UUID, inside: Bool, region: HoverRegion = .indicator) {
        if inside {
            if self.id != id { dismiss() }
            dismissTask?.cancel(); self.id = id; hoveredRegions.insert(region)
        } else {
            guard self.id == id else { return }
            hoveredRegions.remove(region)
            scheduleDismiss()
        }
    }
    func show(_ id: UUID) {
        if self.id != id { dismiss() }
        self.id = id
        scheduleDismiss()
    }
    func menuTracking(_ menu: NSMenu, active: Bool) {
        let key = ObjectIdentifier(menu)
        if active {
            guard id != nil else { return }
            trackingMenus.insert(key); dismissTask?.cancel()
        } else {
            guard trackingMenus.remove(key) != nil else { return }
            scheduleDismiss()
        }
    }
    private func scheduleDismiss() {
        dismissTask?.cancel(); dismissTask = nil
        guard let id, hoveredRegions.isEmpty, trackingMenus.isEmpty else { return }
        dismissTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self, self.id == id, self.hoveredRegions.isEmpty, self.trackingMenus.isEmpty else { return }
            self.dismiss()
        }
    }
    func dismiss() {
        dismissTask?.cancel(); dismissTask = nil; id = nil
        hoveredRegions.removeAll(); trackingMenus.removeAll()
    }
}

struct DesktopWorkspaceView: View {
    @ObservedObject var center: DesktopCenter
    @State private var settingsPresented = false
    @StateObject private var connectionInfo: DesktopConnectionPopoverState
    init(center: DesktopCenter, hoveredConnectionID: UUID? = nil) {
        self.center = center
        _connectionInfo = StateObject(wrappedValue: DesktopConnectionPopoverState(id: hoveredConnectionID))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(center.viewerSessions) { session in
                            DesktopSessionTab(center: session, selected: center.selectedViewerID == session.id, hover: { inside in
                                connectionInfo.hover(session.id, inside: inside)
                            }, showInfo: {
                                center.desktopWindow.releaseKeyboardFocus()
                                connectionInfo.show(session.id)
                            }) {
                                center.desktopWindow.releaseKeyboardFocus()
                                center.selectViewer(session.id)
                            }
                        }
                    }
                }.scrollIndicators(.hidden)
                if let selected = center.selectedViewer {
                    DesktopMacControls(center: selected, releaseFocus: center.desktopWindow.releaseKeyboardFocus)
                    Button { center.desktopWindow.releaseKeyboardFocus() } label: {
                        Label(selected.remoteShortcutsActive ? "快捷键：远端" : "快捷键：本机", systemImage: "keyboard")
                            .font(.caption.weight(.medium)).fixedSize()
                            .foregroundStyle(selected.remoteShortcutsActive ? Color.accentColor : .secondary)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(selected.remoteShortcutsActive ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08), in: Capsule())
                    }.buttonStyle(.plain)
                        .help("点击顶部释放远端焦点；选择被控电脑接收快捷键后，点击远程画面重新接管。⌃⌥Esc 随时释放。")
                    DesktopInputModePicker(center: selected) {
                        center.desktopWindow.releaseKeyboardFocus()
                    }.frame(width: 184)
                    Button {
                        center.desktopWindow.releaseKeyboardFocus()
                        selected.sendInput(.init(kind: "release")); settingsPresented.toggle()
                    } label: { Image(systemName: "slider.horizontal.3").frame(width: 28, height: 28) }
                        .buttonStyle(.plain).help("连接设置")
                        .popover(isPresented: $settingsPresented) { DesktopViewerSettings(center: selected) }
                }
            }.padding(.leading, 78).padding(.trailing, 10).frame(height: DesktopControlWindow.navigationHeight)
                .background(DesktopWindowDragArea())
                .background(.bar)
            if let selected = center.selectedViewer {
                DesktopSessionView(center: selected, settingsPresented: settingsPresented || connectionInfo.id != nil).id(selected.id)
            }
        }
        .overlayPreferenceValue(DesktopConnectionAnchorKey.self) { anchors in
            GeometryReader { geometry in
                if let id = connectionInfo.id, let anchor = anchors[id],
                   let session = center.viewerSessions.first(where: { $0.id == id }) {
                    let rect = geometry[anchor]
                    // 浮层在滚动区域之外绘制；靠窗口边缘时收回到内容区内。
                    if rect.maxX > 78 && rect.minX < geometry.size.width - 48 {
                        DesktopConnectionInfo(center: session, maximumHeight: min(440, max(100, geometry.size.height - rect.maxY - 16)),
                                              close: { connectionInfo.dismiss() })
                            .offset(x: min(max(8, rect.midX - 160), max(8, geometry.size.width - 328)),
                                    y: rect.maxY + 8)
                            .onHover { inside in
                                if inside {
                                    center.desktopWindow.releaseKeyboardFocus()
                                }
                                connectionInfo.hover(id, inside: inside, region: .panel)
                            }
                    }
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: center.selectedViewerID) { _, _ in
            settingsPresented = false; connectionInfo.dismiss()
        }
        .onChange(of: settingsPresented) { _, _ in connectionInfo.dismiss() }
        .onChange(of: center.viewerSessions.map(\.id)) { _, ids in
            if let id = connectionInfo.id, !ids.contains(id) { connectionInfo.dismiss() }
        }
        .onDisappear { connectionInfo.dismiss() }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { notification in
            if let menu = notification.object as? NSMenu { connectionInfo.menuTracking(menu, active: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { notification in
            if let menu = notification.object as? NSMenu { connectionInfo.menuTracking(menu, active: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            connectionInfo.dismiss()
        }
    }
}

/// 标题栏的唯一输入方式入口，沿用按电脑保存的偏好。
private struct DesktopInputModePicker: NSViewRepresentable {
    @ObservedObject var center: DesktopCenter
    var willChange: () -> Void = {}

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: ["远端输入法", "本机输入法"], trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.selectMode(_:)))
        control.controlSize = .small
        control.setImage(NSImage(systemSymbolName: "mic", accessibilityDescription: nil), forSegment: 1)
        control.setAccessibilityLabel("输入方式")
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.picker = self
        control.selectedSegment = center.localInputEnabled ? 1 : 0
        control.isEnabled = context.environment.isEnabled && center.controlAllowed && center.viewerControlEnabled && !center.remoteScreenLocked
        control.toolTip = center.remoteScreenLocked ? "锁屏期间使用远端按键输入，解锁后可切换。" :
            "远端输入法：将按键发送到被控电脑，使用被控电脑上的输入法。\n本机输入法：使用这台 Mac 的输入法打字或语音输入，确认后将文字填入远端输入框。\n切换后点击远端输入框继续输入。"
    }

    func makeCoordinator() -> Coordinator { Coordinator(picker: self) }

    @MainActor final class Coordinator {
        var picker: DesktopInputModePicker

        init(picker: DesktopInputModePicker) { self.picker = picker }

        @objc func selectMode(_ sender: NSSegmentedControl) {
            let enabled = sender.selectedSegment == 1
            guard enabled != picker.center.localInputEnabled else { return }
            picker.willChange()
            picker.center.localInputEnabled = enabled
        }
    }
}

private struct DesktopConnectionAnchorKey: PreferenceKey {
    static var defaultValue: [UUID: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct DesktopSessionTab: View {
    @ObservedObject var center: DesktopCenter
    let selected: Bool
    let hover: (Bool) -> Void
    let showInfo: () -> Void
    let select: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Button(action: select) {
                Text(center.peer?.name ?? "远程电脑").lineLimit(1)
            }.buttonStyle(.plain)
            Button(action: showInfo) {
                DesktopLatencyLabel(center: center, showsHelp: false)
                    .contentShape(Rectangle())
                    .anchorPreference(key: DesktopConnectionAnchorKey.self, value: .bounds) { [center.id: $0] }
                    .onHover(perform: hover)
                    .onDisappear { hover(false) }
            }.buttonStyle(.plain).help("悬停查看连接信息，移开后自动隐藏")
        }.padding(.horizontal, 12).frame(height: 30)
            .background(selected ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct DesktopWindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            (window as? DesktopControlWindow)?.releaseKeyboardFocus()
            window?.performDrag(with: event)
        }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
}

private struct DesktopSessionView: View {
    @ObservedObject var center: DesktopCenter
    let settingsPresented: Bool
    @State private var securityPresented = false
    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            if let track = center.video {
                DesktopVideoSurface(track: track,
                    canControl: center.connected && center.controlAllowed && center.viewerControlEnabled && !settingsPresented && !securityPresented,
                    send: center.sendInput,
                    paste: { center.pasteUnifiedClipboard() },
                    commitText: center.insertLocalText,
                    localInputEnabled: center.localInputEnabled && !center.remoteScreenLocked,
                    dropFiles: center.canSendFiles && center.viewerControlEnabled && !settingsPresented && !securityPresented && !center.remoteScreenLocked ? { center.dropFiles($0, at: $1) } : nil,
                    dragHover: { center.fileDragHover = $0 },
                    shortcutDestination: center.shortcutDestination,
                    inputIsCurrent: { center.acceptsViewerInput && !securityPresented },
                    captureChanged: { active in
                        DispatchQueue.main.async { center.setRemoteShortcutsActive(active) }
                    },
                    shortcutFailure: { error in
                        DispatchQueue.main.async { if center.shortcutCaptureError != error { center.shortcutCaptureError = error } }
                    })
            } else {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text(center.route).foregroundStyle(.white)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if center.remoteScreenLocked {
                DesktopLockedSessionBanner(center: center, settingsPresented: $securityPresented)
            }
            if let error = center.shortcutCaptureError {
                Text(error).font(.callout).padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(8).allowsHitTesting(false)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if center.fileDragHover {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.blue, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .top) {
                        Label(center.dropSupported ? "松开以传输并拖入此处" : "松开以发送到远端下载目录", systemImage: "arrow.down.doc.fill")
                            .font(.callout.weight(.medium)).padding(12).background(.regularMaterial, in: Capsule()).padding(20)
                    }.padding(8).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: 8) {
                if center.fileReceiveMessage != nil {
                    DesktopFileReceipt(center: center).padding(12).frame(width: 350)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let state = center.transferState {
                    DesktopTransferHUD(state: state, cancel: center.cancelFileTransfer, dismiss: center.dismissFileStatus)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }.padding(18)
        }
        .animation(.easeOut(duration: 0.2), value: center.transferState != nil)
        .animation(.easeOut(duration: 0.2), value: center.fileReceiveMessage != nil)
    }
}

struct DesktopTransferHUD: View {
    let state: DesktopTransferState
    let cancel: () -> Void
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var tint: Color {
        switch state.phase { case .failed, .warning: return .orange; case .completed: return .green; default: return .accentColor }
    }
    private var title: String {
        switch state.phase {
        case .preparing: return "准备传输"
        case .sending: return "正在发送文件"
        case .delivering: return "等待远端确认"
        case .completed: return "传输完成"
        case .warning: return "文件已保存 · 需要确认"
        case .failed: return "传输未完成"
        case .cancelled: return "已取消传输"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: state.active ? "arrow.up.doc.fill" : state.phase == .completed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.title3).foregroundStyle(tint).frame(width: 32, height: 32)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                Text(title).font(.headline)
                Spacer()
                if state.active {
                    Button("取消", action: cancel).controlSize(.small)
                } else {
                    Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭传输状态")
                }
            }
            Text(state.message).font(.callout).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
            if state.active {
                if let progress = state.progress {
                    GeometryReader { geometry in
                        Capsule().fill(tint.opacity(0.14))
                            .overlay(alignment: .leading) {
                                Capsule().fill(tint.gradient).frame(width: geometry.size.width * progress)
                            }
                    }.frame(height: 6)
                        .animation(reduceMotion ? nil : .linear(duration: 0.15), value: progress)
                        .accessibilityLabel("文件传输进度")
                        .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
                } else {
                    HStack(spacing: 8) {
                        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                            let turn = reduceMotion ? 0 : context.date.timeIntervalSince(state.startedAt)
                                .truncatingRemainder(dividingBy: 0.9) / 0.9
                            Circle().trim(from: 0.08, to: 0.82)
                                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .rotationEffect(.degrees(turn * 360))
                        }.frame(width: 14, height: 14).accessibilityHidden(true)
                        Text(state.phase == .preparing ? "正在读取文件与目标信息" : "正在校验和处理文件，请稍候")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = max(1, context.date.timeIntervalSince(state.startedAt))
                    let waiting = context.date.timeIntervalSince(state.updatedAt) >= 3
                    HStack {
                        if state.phase == .sending {
                            Text("\(ByteCountFormatter.string(fromByteCount: state.bytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: state.total, countStyle: .file))")
                            Spacer(minLength: 4)
                            if let progress = state.progress { Text(progress, format: .percent.precision(.fractionLength(0))) }
                        } else {
                            Text("已等待 \(max(0, Int(context.date.timeIntervalSince(state.updatedAt)))) 秒")
                        }
                    }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if state.phase == .sending {
                        HStack {
                            Text("第 \(max(1, state.fileIndex)) / \(state.fileCount) 个文件")
                            Spacer()
                            Text(waiting ? "等待远端响应…" : "\(ByteCountFormatter.string(fromByteCount: Int64(Double(state.bytes) / elapsed), countStyle: .file))/秒")
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let hint = state.destinationHint {
                    Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else if !state.paths.isEmpty {
                HStack {
                    Text("远端暂存文件保留 7 天").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("复制远端路径") {
                        guard let text = DesktopDropStorage.shellPaths(state.paths) else { return }
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                    }.controlSize(.small)
                }
            }
        }.padding(16).frame(width: 350)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.2), radius: 18, y: 6)
            .accessibilityElement(children: .contain)
    }
}

struct DesktopViewerSettings: View {
    @ObservedObject var center: DesktopCenter
    @State private var securityExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    inputSettings
                    displaySettings
                    if !center.isDirect { securitySettings }
                    DesktopMessage(center: center)
                    DesktopFileStatus(center: center)
                }
                .padding(16)
            }
            Divider()
            HStack {
                Button("发送文件…") { center.chooseFiles() }.disabled(!center.canSendFiles)
                Spacer()
                Button("断开连接", role: .destructive) { center.disconnect() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .controlSize(.small)
        .frame(width: 380, height: 550)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(center.peer?.name ?? "连接设置")
                    .font(.headline)
                    .lineLimit(1)
                    .help(center.peer?.name ?? "连接设置")
                    .accessibilityAddTraits(.isHeader)
                Text(center.route).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var inputSettings: some View {
        section("控制与输入") {
            row("鼠标键盘", symbol: "keyboard") {
                Toggle("鼠标键盘", isOn: $center.viewerControlEnabled)
                    .disabled(!center.controlAllowed)
            }
            Divider()
            row("快捷键接收端", symbol: "command") {
                Picker("快捷键接收端", selection: Binding(get: { center.shortcutDestination }, set: { center.setShortcutDestination($0) })) {
                    ForEach(DesktopShortcutDestination.allCases, id: \.self) { Text($0.title).tag($0) }
                }.disabled(!center.controlAllowed || !center.viewerControlEnabled)
            } details: {
                Text("选择被控电脑后，仅在此连接画面获得键盘焦点时接管快捷键。⌃⌥Esc 随时释放键盘；点击画面可重新接管。")
                if let error = center.shortcutCaptureError { Text(error).foregroundStyle(.orange) }
            }
            if !center.restrictedDirectSession {
                Divider()
                row("同步剪贴板", symbol: "clipboard") {
                    Toggle("同步剪贴板", isOn: $center.clipboardEnabled).disabled(!center.controlAllowed)
                } details: {
                    Text(!center.clipboardEnabled ? "同步已关闭，⌘V 使用远端剪贴板。" : center.clipboardSupported
                         ? "当前活动连接同步新复制的文本；⌘V 使用最近复制的来源。远端文件和图片在远端粘贴，本机文件通过 ⌘V 上传。"
                         : "对方版本尚未声明剪贴板同步能力；⌘V 使用远端剪贴板，需要时可点击「粘贴本机内容」。")
                    HStack(spacing: 8) {
                        Button("粘贴本机内容") { center.pasteClipboard() }
                            .disabled(!center.connected || !center.controlAllowed || !center.viewerControlEnabled || !center.clipboardEnabled || center.remoteScreenLocked)
                        Button("粘贴远端内容") { center.pasteRemoteClipboard() }
                            .disabled(!center.connected || !center.controlAllowed || !center.viewerControlEnabled)
                    }.buttonStyle(.bordered)
                }
            }
        }
    }

    private var displaySettings: some View {
        section("画面与声音") {
            if !center.isHost {
                videoSettings
                Divider()
            }
            row("光标", symbol: "cursorarrow") {
                Picker("光标", selection: $center.cursorMode) {
                    ForEach(DesktopCursorMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.disabled(!center.controlAllowed || !center.cursorSupported)
            }
            Divider()
            row("被控电脑隐私屏", symbol: "lock.display") {
                Toggle("被控电脑隐私屏", isOn: Binding(get: { center.privacyRequested }, set: { center.requestPrivacy($0) }))
                    .disabled(!center.connected || !center.controlAllowed || !center.privacySupported || center.privacyChanging)
            } details: {
                Text(center.privacySupported ? center.privacyStatusText : "对方版本尚未声明支持隐私屏")
            }
            if center.audioAllowed {
                Divider()
                row("静音", symbol: "speaker.slash") {
                    Toggle("静音", isOn: $center.muted)
                }
            }
        }
    }

    private var videoSettings: some View {
        row("画质选择", symbol: "display") {
            Picker("画质选择", selection: Binding(get: { center.videoSelection.selectedPreset },
                set: { center.requestVideoPreset($0) })) {
                ForEach(DesktopVideoPreset.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(!center.connected || !center.videoSelection.supported || center.videoSelection.changing)
        } details: {
            if center.videoSelection.changing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(center.videoSelection.statusText)
                }
            } else {
                Text(center.videoSelection.statusText)
                    .foregroundStyle(center.videoSelection.failure == nil ? Color.secondary : .orange)
                if center.videoSelection.failure != nil {
                    if let format = center.videoSelection.confirmed { Text(format.description) }
                    Button("重试画面设置") {
                        center.requestVideoPreset(center.videoSelection.retryPreset ?? center.videoSelection.selectedPreset)
                    }
                    .disabled(!center.connected)
                }
            }
        }
    }

    private var securitySettings: some View {
        section("安全") {
            DisclosureGroup(isExpanded: $securityExpanded) {
                DesktopRemoteSecuritySettings(center: center).padding(.top, 8)
            } label: {
                rowLabel("登录密码与断连锁屏", symbol: "key")
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func rowLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
                .accessibilityHidden(true)
            Text(title)
        }.font(.callout)
    }

    private func row<Control: View>(_ title: String, symbol: String, @ViewBuilder control: () -> Control) -> some View {
        row(title, symbol: symbol, control: control) { EmptyView() }
    }

    private func row<Control: View, Details: View>(_ title: String, symbol: String,
        @ViewBuilder control: () -> Control, @ViewBuilder details: () -> Details) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                rowLabel(title, symbol: symbol).accessibilityHidden(true)
                Spacer(minLength: 8)
                control().labelsHidden().toggleStyle(.switch)
            }.frame(minHeight: 22)
            VStack(alignment: .leading, spacing: 6, content: details)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 23)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct DesktopMessage: View {
    @ObservedObject var center: DesktopCenter
    var body: some View {
        if center.signalRecovering {
            Label("信令正在恢复，暂时保留桌面连接，最长等待一分钟。", systemImage: "arrow.triangle.2.circlepath")
                .font(.callout).foregroundStyle(.orange)
        }
        if let message = center.message {
            HStack { Text(message).font(.callout); Spacer(); Button("关闭") { center.message = nil } }
                .padding(10).background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct DesktopFileStatus: View {
    @ObservedObject var center: DesktopCenter
    var body: some View {
        if let message = center.fileMessage {
            HStack {
                Text(message).font(.caption).lineLimit(2)
                if let progress = center.fileProgress {
                    ProgressView(value: progress).frame(width: 100)
                    Text(progress, format: .percent.precision(.fractionLength(0))).font(.caption.monospacedDigit())
                    Button("取消") { center.cancelFileTransfer() }.controlSize(.small)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct DesktopFileReceipt: View {
    @ObservedObject var center: DesktopCenter

    var body: some View {
        if let message = center.fileReceiveMessage {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(message, systemImage: center.receivedFileFolder == nil ? "arrow.down.doc" : "checkmark.circle.fill")
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if center.fileReceiveProgress == nil {
                        Button(action: center.dismissFileReceipt) { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).help("关闭接收状态")
                    }
                }
                if let progress = center.fileReceiveProgress {
                    HStack {
                        ProgressView(value: progress).accessibilityLabel("文件接收进度")
                        Text(progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                    }
                } else if let folder = center.receivedFileFolder {
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                }
            }.font(.callout).controlSize(.small)
        }
    }
}

private struct DesktopLatencyLabel: View {
    @ObservedObject var center: DesktopCenter
    var showsHelp = true
    private var quality: DesktopConnectionQuality {
        DesktopConnectionQuality(milliseconds: center.connected ? center.latencyMilliseconds : nil)
    }
    var body: some View {
        if showsHelp {
            label.help("链路质量：\(quality.rawValue)。按实际 RTT 分档：低于 80 ms 良好，80–199 ms 一般，200 ms 及以上较差；每 2 秒刷新，不代表 Wi-Fi 信号强度或画面显示延迟。")
        } else { label }
    }
    private var label: some View {
        HStack(spacing: 4) {
            Image(systemName: quality.symbol)
                .foregroundStyle(quality == .good ? Color.green : quality == .unknown ? .secondary : .orange)
            Text(center.connected ? center.latencyMilliseconds.map { "\($0.formatted(.number.precision(.fractionLength(0)))) ms" } ?? "— ms" : "连接中")
        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .accessibilityLabel("连接质量\(quality.rawValue)")
    }
}

struct DesktopConnectionInfo: View {
    @ObservedObject var center: DesktopCenter
    var maximumHeight: CGFloat = 440
    var close: (() -> Void)? = nil
    private var quality: DesktopConnectionQuality {
        .init(milliseconds: center.connected ? center.latencyMilliseconds : nil)
    }
    private var status: String {
        if center.signalRecovering { return "信令恢复中" }
        if center.connected { return "已连接" }
        return center.sessionEstablished ? "连接恢复中" : "正在连接"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "display.2").foregroundStyle(.white.opacity(0.7))
                Text(center.peer?.name ?? "远程电脑").fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 4)
                Circle().fill(center.connected && !center.signalRecovering ? Color.green : .orange)
                    .frame(width: 6, height: 6)
                Text(status).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                if let close {
                    Button(action: close) { Image(systemName: "xmark").frame(width: 20, height: 20) }
                        .buttonStyle(.plain).accessibilityLabel("关闭连接信息")
                }
            }
            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 8) {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            row("连接时长", DesktopConnectionTiming.durationText(center.connectionTiming.elapsed()))
                        }
                        if let start = center.connectionTiming.startedAt {
                            row("开始时间", start.formatted(date: .abbreviated, time: .standard))
                        }
                        row("连接方式", center.route)
                        row("控制端 IP", (center.isHost ? center.connectionAddresses.remote : center.connectionAddresses.local)?.description ?? "未获取")
                        row("被控端 IP", (center.isHost ? center.connectionAddresses.local : center.connectionAddresses.remote)?.description ?? "未获取")
                        row("往返延迟", center.connected ? center.latencyMilliseconds.map {
                            "\($0.formatted(.number.precision(.fractionLength(0)))) ms · \(quality.rawValue)"
                        } ?? "测量中" : "—")
                        row("控制权限", center.controlAllowed ? (center.viewerControlEnabled ? "允许控制" : "已暂停控制") : "仅观看")
                        row("系统声音", center.audioAllowed ? (center.muted ? "已静音" : "已开启") : "未共享")
                    }
                    Text("连接地址与延迟每 2 秒刷新；中继时显示中继节点 IP。")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .font(.system(size: 12)).foregroundStyle(.white)
        .padding(14)
        .frame(width: 320, height: maximumHeight)
        .preferredColorScheme(.dark)
        .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
        .accessibilityElement(children: .contain)
    }
    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.white.opacity(0.6)).fixedSize()
            Spacer(minLength: 0)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}

private struct DesktopUnattendedSettingsView: View {
    @ObservedObject var center: DesktopCenter
    @Environment(\.dismiss) private var dismiss
    @State private var settings: DesktopUnattendedSettings
    @State private var accountID: String?

    init(center: DesktopCenter) {
        self.center = center
        _accountID = State(initialValue: center.settingsAccountID)
        _settings = State(initialValue: center.unattended)
    }

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            Label("此电脑的无人值守设置", systemImage: "checkmark.shield").font(.title2.bold())
            Toggle("允许同账号设备免确认连接此电脑", isOn: $settings.enabled)
            Text("设置仅对本机当前 TaoScreen 账号生效。开启后，同账号设备可直接查看所选屏幕，并使用下方允许的功能。")
                .font(.callout).foregroundStyle(.secondary)
            Group {
                Picker("共享屏幕", selection: $settings.displayID) {
                    Text("主屏幕（连接时自动选择）").tag(Optional<CGDirectDisplayID>.none)
                    ForEach(NSScreen.screens, id: \.desktopID) { screen in
                        Text(screen.localizedName).tag(Optional(screen.desktopID))
                    }
                    if let id = settings.displayID, !NSScreen.screens.contains(where: { $0.desktopID == id }) {
                        Text("已断开的屏幕（请重新选择）").tag(Optional(id))
                    }
                }
                Toggle("允许鼠标键盘控制、粘贴文本和接收文件", isOn: $settings.control)
                Toggle("共享系统声音", isOn: $settings.audio)
            }.disabled(!settings.enabled)
            DesktopPermissionSection(permissions: center.permissions, control: settings.control, restart: center.restartForPermissions)
            Text("首次启用需在本机授予屏幕录制权限，允许控制还需辅助功能权限。TaoScreen 保持运行时，锁屏后仍可连接，并在远程画面输入该 Mac 的密码解锁。共享期间会保持显示器唤醒；休眠、退出登录和切换用户会停止共享。开机后需先登录并启动 TaoScreen。")
                .font(.caption).foregroundStyle(.secondary)
            if let message = center.message {
                Text(message).font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("保存") {
                    if center.updateUnattended(settings, for: accountID) { dismiss() }
                }.buttonStyle(.borderedProminent).disabled(!center.canConfigureUnattended)
            }
        }.padding(24) }.frame(width: 570, height: 680)
        .onChange(of: center.settingsAccountID) { _, id in if id != accountID { dismiss() } }
    }
}

/// 所有模块都可看到共享状态和停止入口，切页不会隐藏被控提示。
struct DesktopGlobalStatus: View {
    @ObservedObject var center = DesktopCenter.shared
    @State private var showInvitation = false
    var body: some View {
        Group {
            if let invitation = center.invitation {
                HStack {
                    Label("\(invitation.peer.name) 请求连接此电脑", systemImage: "display.2")
                    Spacer()
                    Button("拒绝") { center.reject() }
                    Button("查看请求…") { showInvitation = true }.buttonStyle(.borderedProminent)
                }.padding(10).background(.blue.opacity(0.12))
            } else if center.isHost, let peer = center.peer {
                HStack {
                    Label("正在向 \(peer.name) 共享屏幕 · \(center.controlAllowed ? "允许控制" : "仅观看")", systemImage: "record.circle")
                        .foregroundStyle(.red)
                    Spacer()
                    DesktopLatencyLabel(center: center)
                    Button("停止共享", role: .destructive) { center.disconnect() }
                }.padding(10).background(.red.opacity(0.10))
            }
        }
        .onChange(of: center.invitation?.id) { _, id in showInvitation = id != nil }
        .sheet(isPresented: $showInvitation, onDismiss: { if center.invitation != nil { center.reject() } }) {
            DesktopConsentView(center: center)
        }
    }
}

private struct DesktopConsentView: View {
    @ObservedObject var center: DesktopCenter
    @Environment(\.dismiss) private var dismiss
    @State private var display = CGMainDisplayID()
    @State private var control: Bool
    @State private var sound = false
    @State private var rememberDirectDevice = false

    init(center: DesktopCenter) {
        self.center = center
        _control = State(initialValue: !center.isDirect)
    }

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            Label("远程桌面请求", systemImage: "display.2").font(.title2.bold())
            Text("\(center.invitation?.peer.name ?? "远程设备") 希望查看这台电脑。共享期间，对方可看到所选屏幕中的全部内容。")
            if center.isDirect {
                Text("这台设备使用了本次直连的连接码。请确认设备是你刚刚发给连接码的对象。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("共享屏幕", selection: $display) {
                ForEach(NSScreen.screens, id: \.desktopID) { screen in Text(screen.localizedName).tag(screen.desktopID) }
            }
            Toggle("允许鼠标键盘控制、粘贴文本和接收文件", isOn: $control)
            Toggle("共享系统声音", isOn: $sound)
            if center.canRememberDirectDevice {
                Toggle("记为可信设备", isOn: $rememberDirectDevice)
                Text("记住设备身份。无人值守权限可稍后在「可信设备」中授权。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DesktopPermissionSection(permissions: center.permissions, control: control, restart: center.restartForPermissions)
            Text("本次请求约一分钟内有效。权限不足时可先在此电脑授权；如果请求已过期或需要重启，请让对方重新发起连接。")
                .font(.caption).foregroundStyle(.secondary)
            if let message = center.message { Text(message).font(.callout).foregroundStyle(.orange) }
            Text("仅授权这一次连接，不会自动接受以后的请求。锁屏后连接会保留，允许控制时可远程输入该 Mac 的密码解锁；休眠、退出登录或切换用户会停止共享。共享期间会保持显示器唤醒。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("拒绝", role: .cancel) { center.reject(); dismiss() }
                Button("接受并共享") {
                    Task { await center.accept(display: display, control: control, audio: sound, rememberDirectDevice: rememberDirectDevice) }
                }.buttonStyle(.borderedProminent)
                    .disabled(center.invitation == nil || !center.permissions.snapshot.missing(control: control).isEmpty)
            }
        }.padding(24) }.frame(width: 560, height: 660)
        .onAppear { center.permissions.requireControl(control) }
        .onChange(of: control) { _, value in center.permissions.requireControl(value) }
        .onChange(of: center.invitation?.id) { _, id in if id == nil { dismiss() } }
        .interactiveDismissDisabled()
    }
}

private extension NSScreen {
    var desktopID: CGDirectDisplayID { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID() }
}

private struct DesktopVideoSurface: NSViewRepresentable {
    let track: RTCVideoTrack
    let canControl: Bool
    let send: (DesktopInput) -> Void
    var paste: (() -> Void)? = nil
    var commitText: ((String) -> Void)? = nil
    var localInputEnabled = true
    var dropFiles: (([URL], DesktopDropPoint) -> Bool)? = nil
    var dragHover: ((Bool) -> Void)? = nil
    var shortcutDestination: DesktopShortcutDestination = .local
    var inputIsCurrent: (() -> Bool)? = nil
    var captureChanged: ((Bool) -> Void)? = nil
    var shortcutFailure: ((String?) -> Void)? = nil
    func makeNSView(context: Context) -> DesktopVideoNSView { DesktopVideoNSView() }
    func updateNSView(_ view: DesktopVideoNSView, context: Context) {
        view.send = send; view.pasteClipboard = paste; view.dropFiles = dropFiles
        view.commitText = commitText
        view.localInputEnabled = localInputEnabled
        view.dragHover = dragHover
        view.shortcutFailure = shortcutFailure
        view.inputIsCurrent = inputIsCurrent
        view.captureChanged = captureChanged
        view.shortcutDestination = shortcutDestination
        view.canControl = canControl; view.setTrack(track)
    }
    static func dismantleNSView(_ view: DesktopVideoNSView, coordinator: ()) {
        view.dismantle()
    }
}

/// 本机预编辑字幕；点击仍由桌面画面接收，不成为独立的输入焦点。
final class DesktopCompositionSubtitle: NSView {
    private let scrollView = NSScrollView()
    private let textView = NSTextView(frame: .zero)
    private var selection = NSRange(location: 0, length: 0)
    private let subtitleFont = NSFont.systemFont(ofSize: 18, weight: .medium)

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.74).cgColor
        layer?.cornerRadius = 10
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        layer?.borderWidth = 0.5
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.contentView.drawsBackground = false
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = false
        textView.isRichText = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        scrollView.documentView = textView
        addSubview(scrollView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(text: String, selection: NSRange) {
        self.selection = selection
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 3
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: subtitleFont, .foregroundColor: NSColor.white, .paragraphStyle: paragraph
        ]))
        isHidden = text.isEmpty
    }

    func position(in videoRect: NSRect) {
        guard !textView.string.isEmpty, videoRect.width > 0, videoRect.height > 0,
              let container = textView.textContainer, let manager = textView.layoutManager else {
            isHidden = true
            return
        }
        let maximumWidth = min(640, videoRect.width * 0.8)
        let padding = min(14, maximumWidth * 0.1)
        // 先按文字的自然宽度收紧背景，长文本达到上限后再换行。
        // 每次都从完整文本重新测量，删除文字时背景也能随之缩短。
        let naturalTextWidth = ceil(textView.attributedString().size().width)
        let textWidth = max(1, min(naturalTextWidth, maximumWidth - padding * 2))
        let width = textWidth + padding * 2
        container.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        textView.setFrameSize(NSSize(width: textWidth, height: 1))
        manager.ensureLayout(for: container)
        let lineHeight = manager.defaultLineHeight(for: subtitleFont)
        let contentHeight = ceil(max(lineHeight, manager.usedRect(for: container).height,
                                     manager.extraLineFragmentRect.maxY))
        let textHeight = min(contentHeight, ceil(lineHeight * 3 + 6), videoRect.height * 0.3)
        let verticalPadding = min(10, videoRect.height * 0.03)
        let bottomInset = min(32, videoRect.height * 0.06)
        frame = NSRect(x: videoRect.midX - width / 2, y: videoRect.minY + bottomInset,
                       width: width, height: textHeight + verticalPadding * 2)
        scrollView.frame = NSRect(x: padding, y: verticalPadding, width: textWidth, height: textHeight)
        textView.setFrameSize(NSSize(width: textWidth, height: contentHeight))
        // 长段落保留完整预编辑内容，只滚动展示正在编辑的位置（听写通常在末尾）。
        textView.scrollRangeToVisible(NSRange(location: selection.location, length: 0))
        isHidden = false
    }

    func firstRect(actualRange: NSRangePointer?) -> NSRect {
        textView.firstRect(forCharacterRange: NSRange(location: selection.location, length: 0), actualRange: actualRange)
    }
}

final class DesktopVideoNSView: NSView, RTCVideoViewDelegate, NSTextInputClient {
    private let renderer = RTCMTLNSVideoView(frame: .zero)
    private var track: RTCVideoTrack?
    private var videoSize = CGSize(width: 16, height: 9)
    private var observer: NSObjectProtocol?
    private var applicationObserver: NSObjectProtocol?
    private var tracking: NSTrackingArea?
    var send: ((DesktopInput) -> Void)?
    var pasteClipboard: (() -> Void)?
    var commitText: ((String) -> Void)?
    var localInputEnabled = true {
        willSet { if newValue != localInputEnabled { releaseKeyboardFocus() } }
    }
    private var markedText = NSAttributedString(string: "")
    private var markedSelection = NSRange(location: 0, length: 0)
    private let compositionSubtitle = DesktopCompositionSubtitle(frame: .zero)
    private var interpretingEvent: NSEvent?
    private var interpretingComposition = false
    private var inputMethodHandledEvent = false
    private var discardingComposition = false
    var dropFiles: (([URL], DesktopDropPoint) -> Bool)?
    var dragHover: ((Bool) -> Void)?
    private var suppressPasteKeyUp = false
    private var forwardedKeys: Set<UInt16> = []
    private var keyboardTap: CFMachPort?
    private var keyboardSource: CFRunLoopSource?
    var shortcutFailure: ((String?) -> Void)?
    var inputIsCurrent: (() -> Bool)?
    var captureChanged: ((Bool) -> Void)?
    private(set) var keyboardFocusRequested = false
    private var acceptsInput: Bool { canControl && inputIsCurrent?() != false }
    private var acceptsKeyboardInput: Bool { acceptsInput && keyboardFocusRequested && window?.firstResponder === self }
    var shortcutDestination: DesktopShortcutDestination = .local {
        didSet {
            guard oldValue != shortcutDestination else { return }
            releaseKeyboardFocus()
        }
    }
    var canControl = false {
        didSet {
            if oldValue && !canControl { releaseKeyboardFocus() }
            if oldValue != canControl { window?.invalidateCursorRects(for: self) }
        }
    }
    override var acceptsFirstResponder: Bool { acceptsInput && keyboardFocusRequested }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { canControl }
    override var mouseDownCanMoveWindow: Bool { false }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        addSubview(renderer); renderer.delegate = self
        addSubview(compositionSubtitle)
        // The decoded RGB values are sRGB, even when this Mac uses a P3 display.
        for view in renderer.subviews {
            (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }
        registerForDraggedTypes([.fileURL])
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, (notification.object as? NSWindow) === self.window else { return }
                self.releaseKeyboardFocus()
            }
        }
        applicationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.releaseKeyboardFocus()
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let applicationObserver { NotificationCenter.default.removeObserver(applicationObserver) }
        if let keyboardTap { CFMachPortInvalidate(keyboardTap) }
        if let keyboardSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), keyboardSource, .commonModes) }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        releaseKeyboardFocus()
    }
    override func becomeFirstResponder() -> Bool {
        acceptsFirstResponder && super.becomeFirstResponder()
    }
    private var capturesKeyboard: Bool {
        acceptsKeyboardInput && shortcutDestination == .remote && NSApp.isActive && window?.isKeyWindow == true
            && window?.attachedSheet == nil
    }
    private func updateKeyboardCapture() {
        stopKeyboardCapture()
        guard capturesKeyboard else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated {
                    let view = Unmanaged<DesktopVideoNSView>.fromOpaque(info).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        view.keyboardFocusRequested = false
                        view.captureChanged?(false)
                        view.releaseInput()
                        // 不在事件回调里销毁回调自身；下个主循环撤销接管并显示实际失败。
                        DispatchQueue.main.async { [weak view] in
                            guard let view, !view.keyboardFocusRequested else { return }
                            view.releaseKeyboardFocus()
                            view.shortcutFailure?("快捷键接管已被系统停用，请重新点击画面尝试接管。")
                        }
                        return Unmanaged.passUnretained(event)
                    }
                    guard view.capturesKeyboard, let key = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
                    return view.handleCapturedKey(key) ? nil : Unmanaged.passUnretained(event)
                }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            releaseKeyboardFocus()
            shortcutFailure?("无法接管系统快捷键。请检查此 Mac 的辅助功能权限；当前系统快捷键仍由此电脑响应。")
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            releaseKeyboardFocus()
            shortcutFailure?("无法创建快捷键监听，请重新点击画面重试。")
            return
        }
        keyboardTap = tap; keyboardSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        captureChanged?(true)
        shortcutFailure?(nil)
    }
    func stopKeyboardCapture() {
        if let keyboardTap { CGEvent.tapEnable(tap: keyboardTap, enable: false); CFMachPortInvalidate(keyboardTap) }
        if let keyboardSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), keyboardSource, .commonModes) }
        keyboardTap = nil; keyboardSource = nil
        captureChanged?(false)
    }
    /// 只由活动画面的 event tap 调用；与本地 AppKit 派发互斥，避免组合键重复发送。
    @discardableResult
    func handleCapturedKey(_ event: NSEvent) -> Bool {
        guard acceptsKeyboardInput, shortcutDestination == .remote else { return false }
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.control, .option] {
            keyboardFocusRequested = false; captureChanged?(false); releaseInput()
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.keyboardFocusRequested else { return }
                self.releaseKeyboardFocus()
            }
            return true
        }
        // 文字走正常 AppKit 输入法派发；事件过滤器只接管远端快捷键。
        if localInputEnabled && (isLocalInputShortcut(event) || event.type == .flagsChanged
            || event.modifierFlags.intersection([.command, .control]).isEmpty) { return false }
        switch event.type {
        case .keyDown: keyDown(with: event)
        case .keyUp: keyUp(with: event)
        case .flagsChanged: flagsChanged(with: event)
        default: return false
        }
        return true
    }
    func setTrack(_ next: RTCVideoTrack?) {
        guard track !== next else { return }
        track?.remove(renderer); track = next; next?.add(renderer)
    }
    /// SwiftUI 正在销毁视图图谱，不能同步回调并修改 @Published 悬停状态。
    /// 状态由会话的 setViewerPresented(false) 提前清除；这里解绑回调并释放原生资源。
    func dismantle() {
        dragHover = nil
        releaseKeyboardFocus()
        setTrack(nil)
    }
    override func layout() {
        super.layout()
        let scale = min(bounds.width / max(1, videoSize.width), bounds.height / max(1, videoSize.height))
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        renderer.frame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        compositionSubtitle.position(in: renderer.frame)
        inputContext?.invalidateCharacterCoordinates()
        window?.invalidateCursorRects(for: self)
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if canControl { addCursorRect(renderer.frame, cursor: .arrow) }
    }
    nonisolated func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        Task { @MainActor [weak self] in
            guard size.width > 0, size.height > 0 else { return }
            self?.videoSize = size; self?.needsLayout = true
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag], owner: self)
        addTrackingArea(next); tracking = next
    }
    func releaseInput() { suppressPasteKeyUp = false; forwardedKeys.removeAll(); send?(.init(kind: "release")) }
    func releaseKeyboardFocus() {
        keyboardFocusRequested = false; stopKeyboardCapture(); releaseInput()
        discardComposition()
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }
    override func resignFirstResponder() -> Bool {
        keyboardFocusRequested = false; stopKeyboardCapture(); releaseInput()
        discardComposition()
        return super.resignFirstResponder()
    }
    override func mouseExited(with event: NSEvent) { releaseInput() }
    private func mouse(_ event: NSEvent, button: Bool = false, down: Bool = false) {
        if button {
            DesktopInputDiagnostics.button("window", number: event.buttonNumber, down: down, detail: "control=\(canControl)")
        }
        guard acceptsInput else { return }
        guard let point = DesktopInput.normalized(convert(event.locationInWindow, from: nil), bounds: renderer.frame) else {
            if button { DesktopInputDiagnostics.button("outside_video", number: event.buttonNumber, down: down) }
            if button && down { releaseKeyboardFocus() }
            if button && !down { releaseInput() }; return
        }
        if button && down {
            discardComposition()
            keyboardFocusRequested = true
            guard window?.makeFirstResponder(self) == true else { releaseKeyboardFocus(); return }
            updateKeyboardCapture()
        }
        send?(.init(kind: button ? "button" : "move", x: point.x, y: point.y, button: button ? event.buttonNumber : nil,
                    down: button ? down : nil, flags: UInt64(event.modifierFlags.rawValue), clicks: button ? max(1, min(3, event.clickCount)) : nil))
    }
    override func mouseMoved(with event: NSEvent) { mouse(event) }
    override func mouseDragged(with event: NSEvent) { mouse(event) }
    override func rightMouseDragged(with event: NSEvent) { mouse(event) }
    override func otherMouseDragged(with event: NSEvent) { mouse(event) }
    override func mouseDown(with event: NSEvent) { mouse(event, button: true, down: true) }
    override func mouseUp(with event: NSEvent) { mouse(event, button: true) }
    override func rightMouseDown(with event: NSEvent) { mouse(event, button: true, down: true) }
    override func rightMouseUp(with event: NSEvent) { mouse(event, button: true) }
    override func otherMouseDown(with event: NSEvent) { mouse(event, button: true, down: true) }
    override func otherMouseUp(with event: NSEvent) { mouse(event, button: true) }
    override func scrollWheel(with event: NSEvent) {
        guard acceptsInput else { return }
        send?(.init(kind: "scroll", flags: UInt64(event.modifierFlags.rawValue),
                    dx: max(-1000, min(1000, Double(event.scrollingDeltaX))), dy: max(-1000, min(1000, Double(event.scrollingDeltaY)))))
    }
    private func key(_ event: NSEvent, down: Bool) {
        guard acceptsKeyboardInput else { return }
        if down {
            guard shortcutDestination.forwards(event.modifierFlags) else { return }
            forwardedKeys.insert(event.keyCode)
        } else {
            guard forwardedKeys.remove(event.keyCode) != nil else { return }
        }
        send?(.init(kind: "key", down: down, key: event.keyCode, flags: UInt64(event.modifierFlags.rawValue)))
    }
    private func interceptPaste(_ event: NSEvent) -> Bool {
        guard acceptsKeyboardInput, shortcutDestination == .remote, event.keyCode == 9, event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
              let pasteClipboard else { return false }
        suppressPasteKeyUp = true
        if !event.isARepeat { pasteClipboard() }
        return true
    }
    @objc func paste(_ sender: Any?) {
        guard acceptsKeyboardInput, shortcutDestination == .remote else { return }
        if let pasteClipboard { pasteClipboard() }
        else {
            send?(.init(kind: "key", down: true, key: 9, flags: CGEventFlags.maskCommand.rawValue))
            send?(.init(kind: "key", down: false, key: 9, flags: CGEventFlags.maskCommand.rawValue))
        }
    }
    override func keyDown(with event: NSEvent) {
        guard acceptsKeyboardInput else { return }
        if localInputEnabled, isLocalInputShortcut(event) { return }
        guard shortcutDestination.forwards(event.modifierFlags) else { super.keyDown(with: event); return }
        if interceptPaste(event) { return }
        if localInputEnabled, event.modifierFlags.intersection([.command, .control]).isEmpty {
            interpretingEvent = event
            interpretingComposition = hasMarkedText()
            inputMethodHandledEvent = false
            defer { interpretingEvent = nil; interpretingComposition = false }
            let handled = inputContext?.handleEvent(event) == true
            if handled || inputMethodHandledEvent { return }
        }
        key(event, down: true)
    }
    override func keyUp(with event: NSEvent) {
        if event.keyCode == 9, suppressPasteKeyUp { suppressPasteKeyUp = false; return }
        key(event, down: false)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard acceptsKeyboardInput, shortcutDestination == .remote else { return false }
        if localInputEnabled && (isLocalInputShortcut(event) || event.modifierFlags.intersection([.command, .control]).isEmpty) { return false }
        if !interceptPaste(event) { key(event, down: true) }; return true
    }

    private func isLocalInputShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        return event.keyCode == 63 || (event.keyCode == 49 && (modifiers == .control || modifiers == [.control, .shift]))
    }

    override var inputContext: NSTextInputContext? { localInputEnabled ? super.inputContext : nil }
    private var acceptsTextInput: Bool {
        localInputEnabled && acceptsKeyboardInput && !discardingComposition && !isHiddenOrHasHiddenAncestor
    }

    // 听写可能在没有 keyDown 的情况下通过任一入口提交 NSString / NSAttributedString。
    override func insertText(_ insertString: Any) {
        insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        guard acceptsTextInput else { return }
        guard let text = (string as? NSAttributedString)?.string ?? (string as? String), !text.isEmpty else { return }
        inputMethodHandledEvent = true
        let composed = interpretingComposition || hasMarkedText()
        unmarkText()
        // 未经输入法转换的普通 ASCII 按键保留原来的键码路径，避免每打一键都粘贴。
        // 输入法组词、转换后的字符和无 keyDown 的语音提交均作为完整文字传输。
        if !composed, let event = interpretingEvent, text == event.characters,
           text.utf8.count == 1, let byte = text.utf8.first, (32...126).contains(byte),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            key(event, down: true)
        } else {
            releaseInput()
            commitText?(text)
        }
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard acceptsTextInput else { return }
        let next: NSAttributedString
        if let attributed = string as? NSAttributedString { next = attributed }
        else if let plain = string as? String { next = NSAttributedString(string: plain) }
        else { return }
        inputMethodHandledEvent = true
        interpretingComposition = true
        markedText = next
        let location = min(max(0, selectedRange.location), next.length)
        markedSelection = NSRange(location: location, length: min(max(0, selectedRange.length), next.length - location))
        compositionSubtitle.update(text: next.string, selection: markedSelection)
        compositionSubtitle.position(in: renderer.frame)
        inputContext?.invalidateCharacterCoordinates()
    }
    func unmarkText() {
        markedText = NSAttributedString(string: "")
        markedSelection = NSRange(location: 0, length: 0)
        compositionSubtitle.update(text: "", selection: markedSelection)
        inputContext?.invalidateCharacterCoordinates()
    }
    private func discardComposition() {
        discardingComposition = true
        defer { discardingComposition = false }
        unmarkText()
        inputContext?.discardMarkedText()
    }
    func hasMarkedText() -> Bool { markedText.length > 0 }
    func markedRange() -> NSRange { NSRange(location: hasMarkedText() ? 0 : NSNotFound, length: markedText.length) }
    func selectedRange() -> NSRange { markedSelection }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.underlineStyle, .foregroundColor] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.location >= 0, range.location < markedText.length, range.length > 0 else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0); return nil
        }
        let available = NSRange(location: range.location, length: min(range.length, markedText.length - range.location))
        actualRange?.pointee = available
        return markedText.attributedSubstring(from: available)
    }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = selectedRange()
        guard let window else { return .zero }
        if hasMarkedText(), !compositionSubtitle.isHidden {
            return compositionSubtitle.firstRect(actualRange: actualRange)
        }
        let anchor = NSRect(x: renderer.frame.midX, y: renderer.frame.minY + min(32, renderer.frame.height * 0.06),
                            width: 1, height: min(22, renderer.frame.height * 0.3))
        return window.convertToScreen(convert(anchor, to: nil))
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    override func doCommand(by selector: Selector) {
        guard acceptsTextInput, let event = interpretingEvent else { return }
        inputMethodHandledEvent = true
        if interpretingComposition || hasMarkedText() {
            if selector == #selector(NSResponder.cancelOperation(_:)) { discardComposition() }
            return
        }
        key(event, down: true)
    }
    @objc var unionRectInVisibleSelectedRange: NSRect { firstRect(forCharacterRange: selectedRange(), actualRange: nil) }
    @objc var documentVisibleRect: NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(visibleRect, to: nil))
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { localInputEnabled ? .textArea : .image }
    override func accessibilityLabel() -> String? { "远程桌面输入" }
    override func isAccessibilityFocused() -> Bool { acceptsKeyboardInput }
    override func accessibilityValue() -> Any? { markedText.string }
    override func accessibilityNumberOfCharacters() -> Int { markedText.length }
    override func accessibilitySelectedTextRange() -> NSRange { selectedRange() }
    override func accessibilitySelectedText() -> String? { "" }
    override func setAccessibilitySelectedText(_ text: String?) {
        guard let text else { return }
        insertText(text)
    }
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(setAccessibilityValue(_:)) || selector == #selector(setAccessibilitySelectedTextRange(_:)) { return false }
        if selector == #selector(setAccessibilitySelectedText(_:)) { return acceptsTextInput }
        return super.isAccessibilitySelectorAllowed(selector)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canControl, dropFiles != nil, sender.draggingSourceOperationMask.contains(.copy),
              DesktopInput.normalized(convert(sender.draggingLocation, from: nil), bounds: renderer.frame) != nil,
              sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { dragHover?(false); return [] }
        dragHover?(true)
        releaseInput()
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { dragHover?(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { dragHover?(false) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragHover?(false)
        guard canControl, sender.draggingSourceOperationMask.contains(.copy),
              let point = DesktopInput.normalized(convert(sender.draggingLocation, from: nil), bounds: renderer.frame),
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        return dropFiles?(urls, .init(x: point.x, y: point.y)) == true
    }
    override func flagsChanged(with event: NSEvent) {
        let mask: NSEvent.ModifierFlags
        switch event.keyCode {
        case 56, 60: mask = .shift
        case 59, 62: mask = .control
        case 58, 61: mask = .option
        case 54, 55: mask = .command
        case 57: mask = .capsLock
        default: return
        }
        key(event, down: event.modifierFlags.contains(mask))
    }
}

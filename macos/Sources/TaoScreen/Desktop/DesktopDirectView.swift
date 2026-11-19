import Network
import ServiceManagement
import SwiftUI

struct DesktopDirectView: View {
    @ObservedObject var service: DesktopDirectService

    var body: some View {
        DesktopDirectContent(service: service, center: service.center)
            .onAppear(perform: service.startBrowsing)
            .onDisappear(perform: service.stopBrowsing)
    }
}

private struct DesktopDirectContent: View {
    @ObservedObject var service: DesktopDirectService
    @ObservedObject var center: DesktopCenter
    @State private var request: ConnectionRequest?
    @State private var showPermissions = false
    @State private var showTrustedDevices = false

    private struct ConnectionRequest: Identifiable {
        let id = UUID()
        var device: DesktopNearbyDevice? = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("允许连接此 Mac").font(.headline)
                        Spacer()
                        Button("访问权限…") { showPermissions = true }
                        Button("可信设备…") { showTrustedDevices = true }
                        if service.receiving {
                            Button("关闭接收", action: service.stopReceiving)
                        } else {
                            Button("生成连接码", action: service.startReceiving)
                                .buttonStyle(.borderedProminent).disabled(service.busy)
                        }
                    }
                    if let code = service.code {
                        HStack {
                            Text(code).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("复制连接码") {
                                let item = NSPasteboardItem()
                                item.setString(code, forType: .string)
                                item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.writeObjects([item])
                            }
                        }
                        Text("将连接码发给控制端。连接码 5 分钟内有效，发起连接后还需在此 Mac 确认共享。")
                            .foregroundStyle(.secondary)
                        if let port = service.listeningPort {
                            Text("手动连接使用此 Mac 的局域网或 Tailscale 地址，端口 \(port)。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else if service.receiving {
                        Text("正在开启接收…").foregroundStyle(.secondary)
                    } else {
                        Text("生成连接码后，同一局域网中的另一台 Mac 可以发现此设备。")
                            .foregroundStyle(.secondary)
                    }
                    if service.unattendedEnabled {
                        Text(service.unattendedStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(6)
            }

            HStack {
                Text("附近设备").font(.headline)
                Spacer()
                Button("通过地址连接…") { request = ConnectionRequest() }.disabled(service.busy)
            }
            if let viewer = center.selectedViewer {
                HStack {
                    Label(viewer.peer?.name ?? "远程 Mac", systemImage: "display")
                    Spacer()
                    Button("打开远程窗口") { center.showDesktopWindow() }.buttonStyle(.borderedProminent)
                    Button("断开连接", role: .destructive) { viewer.disconnect() }
                }
            } else if service.busy && center.invitation == nil && !center.isHost {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在验证连接码…")
                    Spacer()
                    Button("取消", action: service.cancelConnection)
                }
            }
            if let message = service.message ?? center.message {
                Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            if let browseMessage = service.browseMessage {
                Text(browseMessage).font(.caption).foregroundStyle(.secondary)
            }
            if service.nearby.isEmpty {
                ContentUnavailableView("暂无附近设备", systemImage: "network",
                    description: Text("在另一台 Mac 上生成连接码。跨网使用 Tailscale 时，可通过地址连接。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(service.nearby) { device in
                            HStack(spacing: 12) {
                                Label(device.name, systemImage: "desktopcomputer").lineLimit(1)
                                Spacer()
                                Button("连接…") { request = ConnectionRequest(device: device) }.disabled(service.busy)
                            }
                            .padding(12)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showPermissions) { DesktopPermissionSettingsView(center: center) }
        .sheet(isPresented: $showTrustedDevices) { DesktopTrustedDevicesView(service: service) }
        .sheet(item: $request) { request in
            DesktopDirectConnectSheet(device: request.device, connect: service.connect)
        }
    }
}

private struct DesktopTrustedDevicesView: View {
    @ObservedObject var service: DesktopDirectService
    @Environment(\.dismiss) private var dismiss
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("可信设备").font(.title2.bold())
            Toggle("允许通过 Tailscale 无人值守", isOn: Binding(get: { service.unattendedEnabled }, set: service.setUnattended))
            Text(service.unattendedStatus).font(.caption).foregroundStyle(.secondary)
            Toggle("登录 macOS 后启动 TaoScreen", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, value in
                    let app = SMAppService.mainApp
                    do {
                        if value, app.status != .enabled { try app.register() }
                        if !value, app.status == .enabled || app.status == .requiresApproval { try app.unregister() }
                        launchMessage = app.status == .requiresApproval ? "请在系统设置的登录项中允许 TaoScreen。" : nil
                    } catch { launchMessage = error.localizedDescription }
                }
            if let launchMessage { Text(launchMessage).font(.caption).foregroundStyle(.orange) }
            if let message = service.message { Text(message).font(.callout).foregroundStyle(.orange) }
            Divider()
            if service.trustedDevices.isEmpty {
                ContentUnavailableView("暂无可信设备", systemImage: "laptopcomputer",
                    description: Text("先使用连接码建立直连，再在被控端的确认窗口中选择「记为可信设备」。"))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(service.trustedDevices) { device in
                            DesktopTrustedDeviceRow(device: device, service: service)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 580, height: 500)
    }
}

private struct DesktopTrustedDeviceRow: View {
    let device: DesktopTrustedDevice
    @ObservedObject var service: DesktopDirectService
    @State private var address: String

    init(device: DesktopTrustedDevice, service: DesktopDirectService) {
        self.device = device; self.service = service
        _address = State(initialValue: device.address ?? "")
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label(device.name, systemImage: "desktopcomputer").font(.headline)
                    Spacer()
                    Button("移除", role: .destructive) { service.removeTrustedDevice(device.publicKey) }
                }
                if device.canRequest {
                    Toggle("允许此设备无人值守连接到本机", isOn: Binding(get: { device.grant != nil }, set: { enabled in
                        service.updateGrant(enabled ? DesktopTrustedGrant() : nil, for: device.publicKey)
                    }))
                    if let grant = device.grant {
                        DesktopShareDisplayPicker(center: service.center, selection: Binding(get: { grant.shareDisplay }, set: { value in
                            var grant = grant; grant.virtualDisplayPreset = value.virtualPreset
                            service.updateGrant(grant, for: device.publicKey)
                        }), allowsFixedDisplay: false)
                        Toggle("允许控制鼠标和键盘", isOn: Binding(get: { grant.control }, set: { value in
                            var grant = grant; grant.control = value
                            service.updateGrant(grant, for: device.publicKey)
                        }))
                        Toggle("共享系统声音", isOn: Binding(get: { grant.audio }, set: { value in
                            var grant = grant; grant.audio = value
                            service.updateGrant(grant, for: device.publicKey)
                        }))
                    }
                }
                if device.canConnect {
                    HStack {
                        TextField("此设备的 Tailscale IP 或 MagicDNS 名称", text: $address).textFieldStyle(.roundedBorder)
                        Button("无人值守连接") { service.connectTrusted(device.publicKey, address: address) }
                            .disabled(service.busy || DesktopDirectEndpoint.parse(address, defaultPort: DesktopTailscaleAddress.port) == nil)
                    }
                }
            }.padding(5)
        }
    }
}

private struct DesktopDirectConnectSheet: View {
    let device: DesktopNearbyDevice?
    let connect: (NWEndpoint, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var code = ""

    private var endpoint: NWEndpoint? { device?.endpoint ?? DesktopDirectEndpoint.parse(address) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(device.map { "连接 \($0.name)" } ?? "通过地址连接").font(.title2.bold())
            if device == nil {
                TextField("IP 或设备名，例如 mac-studio.example.ts.net", text: $address)
                Text("默认端口 \(DesktopDirectEndpoint.port.rawValue)，也可输入地址:端口。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SecureField("粘贴被控 Mac 生成的连接码", text: $code)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("请求连接") {
                    guard let endpoint else { return }
                    connect(endpoint, code)
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(endpoint == nil || DesktopDirectCode(code) == nil)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 430)
    }
}

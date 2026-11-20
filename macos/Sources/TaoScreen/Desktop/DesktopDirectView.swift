import Network
import ServiceManagement
import SwiftUI

struct DesktopDirectView: View {
    @ObservedObject var service: DesktopDirectService

    var body: some View {
        DesktopDirectContent(service: service, center: service.center)
            .onAppear {
                service.center.permissions.refresh()
                service.startBrowsing()
                service.ensureReceivingIfPreferred()
            }
            .onDisappear(perform: service.stopBrowsing)
    }
}

private struct DesktopDirectContent: View {
    @ObservedObject var service: DesktopDirectService
    @ObservedObject var center: DesktopCenter
    @State private var nearbyRequest: DesktopNearbyDevice?
    @State private var showPermissions = false
    @State private var showTrustedDevices = false
    @State private var showUnattendedPassword = false
    @State private var targetAddress = ""
    @State private var credential = ""
    @State private var showCredential = false
    @State private var copiedBadge: String?
    @FocusState private var focusedField: ConnectField?

    private enum ConnectField { case address, credential }

    private var parsedCredential: DesktopDirectCredential {
        DesktopDirectCredential.parse(credential)
    }

    private var canSubmitQuickConnect: Bool {
        guard !service.busy else { return false }
        switch parsedCredential {
        case .directURI:
            return true
        case .legacyCode, .temporaryPassword, .fixedPassword:
            return DesktopDirectEndpoint.parse(targetAddress) != nil
        case .invalid:
            return false
        }
    }

    private var connectableTrustedDevices: [DesktopTrustedDevice] {
        service.trustedDevices.filter(\.canConnect)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DesktopProactivePermissionBanner(permissions: center.permissions, showPermissions: $showPermissions)

            if let viewer = center.selectedViewer {
                HStack(spacing: 12) {
                    Label(viewer.peer?.name ?? "远程 Mac", systemImage: "display").font(.headline)
                    Spacer()
                    Button("打开远程窗口") { center.showDesktopWindow() }.buttonStyle(.borderedProminent)
                    Button("断开连接", role: .destructive) { viewer.disconnect() }
                }
                .padding(12)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            } else if service.busy && center.invitation == nil && !center.isHost {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在验证连接并建立会话…")
                    Spacer()
                    Button("取消", action: service.cancelConnection)
                }
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }

            if let message = service.message ?? center.message {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text(message).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button("关闭") {
                        service.message = nil
                        center.message = nil
                    }.controlSize(.small)
                }
                .padding(10)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(alignment: .top, spacing: 18) {
                hostColumn.frame(minWidth: 330, maxWidth: .infinity, maxHeight: .infinity)
                connectColumn.frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showPermissions) { DesktopPermissionSettingsView(center: center) }
        .sheet(isPresented: $showTrustedDevices) { DesktopTrustedDevicesView(service: service) }
        .sheet(isPresented: $showUnattendedPassword) { DesktopUnattendedPasswordSheet(service: service) }
        .sheet(item: $nearbyRequest) { device in
            DesktopDirectConnectSheet(device: device, connect: service.connect(endpoint:credential:))
        }
    }

    private var hostColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    columnHeading("此电脑", symbol: "desktopcomputer")
                    Spacer()
                    DesktopPermissionButton(permissions: center.permissions) { showPermissions = true }
                        .controlSize(.small)
                }

                addressCard
                temporaryPasswordCard
                unattendedPasswordCard
            }
            .padding(.trailing, 4)
        }
    }

    private var addressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("本机连接地址", systemImage: "network").font(.subheadline.weight(.semibold))
                Spacer()
                if let copiedBadge {
                    Text(copiedBadge).font(.caption).foregroundStyle(.green)
                }
                Button { service.refreshNetworkInfo() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新本机网络与 Tailscale 节点")
            }

            if let ip = service.networkInfo.tailscaleIP {
                addressRow(title: "Tailscale IP", value: ip, badge: "已复制 Tailscale IP")
            }
            if let dns = service.networkInfo.tailscaleDNSName {
                addressRow(title: "MagicDNS", value: dns, badge: "已复制 MagicDNS")
            }
            if let lan = service.networkInfo.lanAddresses.first {
                addressRow(title: "局域网 IP", value: service.networkInfo.lanAddresses.joined(separator: " / "),
                           copyValue: lan, badge: "已复制局域网 IP")
            }
            if service.networkInfo.tailscaleIP == nil && service.networkInfo.tailscaleDNSName == nil && service.networkInfo.lanAddresses.isEmpty {
                Text("暂未检测到 Tailscale 或局域网地址，请确认网络或 Tailscale 已连接。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .desktopWorkspacePanel()
    }

    private func addressRow(title: String, value: String, copyValue: String? = nil, badge: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Button("复制") {
                copyPlain(copyValue ?? value, badge: badge)
            }.controlSize(.small)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(DesktopWorkspaceStyle.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private var temporaryPasswordCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("临时连接密码", systemImage: "key.fill").font(.subheadline.weight(.semibold))
                Spacer()
                Toggle("允许临时连接", isOn: Binding(
                    get: { service.receiving },
                    set: { service.setAutoReceive($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(service.busy)
            }

            if service.receiving {
                if let temp = service.formattedTemporaryPassword, let raw = service.temporaryPassword {
                    HStack(alignment: .center, spacing: 12) {
                        Text(temp)
                            .font(.system(size: 26, weight: .bold, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button("复制密码") { copyConcealed(raw, badge: "已复制临时密码") }
                        Button("刷新") { service.refreshTemporaryPassword() }
                    }
                    HStack(spacing: 8) {
                        if let summary = shareSummaryText {
                            Button("复制地址与密码") { copyConcealed(summary, badge: "已复制连接信息") }
                        }
                        if service.code != nil || service.directShareURI != nil {
                            Menu("兼容连接码") {
                                if let uri = service.directShareURI {
                                    Button("复制连接链接") { copyConcealed(uri, badge: "已复制连接链接") }
                                }
                                if let code = service.code {
                                    Button("复制完整连接码 (TS1-)") { copyConcealed(code, badge: "已复制完整连接码") }
                                }
                            }
                        }
                        Spacer()
                    }.controlSize(.small)
                    Text("对方连接后仍需在此 Mac 确认共享；端口 \(service.listeningPort ?? DesktopDirectEndpoint.port.rawValue)。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("正在开启临时连接接收…").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("开启后自动生成 6 位临时密码并允许附近局域网发现。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !center.permissions.snapshot.screenRecording {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("未授予屏幕录制权限，暂时无法共享屏幕").font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("去授权") { showPermissions = true }.controlSize(.mini)
                }
            }
        }
        .desktopWorkspacePanel()
    }

    private var unattendedPasswordCard: some View {
        let missing = center.permissions.snapshot.missing(control: service.unattendedPasswordSettings.grant.control)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Tailscale 无人值守", systemImage: "lock.shield").font(.subheadline.weight(.semibold))
                Spacer()
                Toggle("固定密码免确认", isOn: Binding(
                    get: { service.unattendedPasswordSettings.enabled },
                    set: { enabled in
                        if enabled && !service.hasUnattendedPassword {
                            showUnattendedPassword = true
                        } else {
                            service.setUnattendedPasswordEnabled(enabled)
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(service.unattendedPasswordListeningPort != nil ? .green : (service.unattendedPasswordSettings.enabled ? .orange : .secondary))
                    .frame(width: 7, height: 7)
                Text(service.unattendedPasswordStatus)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if service.hasUnattendedPassword {
                let grant = service.unattendedPasswordSettings.grant
                let displayTitle = grant.shareDisplay.virtualPreset?.title ?? "主屏幕"
                Text("默认权限：\(displayTitle) · \(grant.control ? "允许控制键鼠" : "仅观看") · \(grant.audio ? "共享系统声音" : "不共享声音")")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("仅限 Tailscale 内网：设置固定密码后无需人工点确认，支持锁屏下直连远程 Mac。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if service.unattendedPasswordSettings.enabled && !missing.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("缺少\(missing.map { $0 == .screenRecording ? "录屏" : "辅助功能" }.joined(separator: "、"))权限，连接将被拒绝")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("立即授权") { showPermissions = true }.controlSize(.mini)
                }
            }

            HStack(spacing: 8) {
                Button(service.hasUnattendedPassword ? "管理固定密码与权限…" : "设置固定密码…") {
                    showUnattendedPassword = true
                }
                Button("可信设备 (\(service.trustedDevices.count))…") {
                    showTrustedDevices = true
                }
            }.controlSize(.small)

            if service.unattendedEnabled {
                Text("已配对可信设备：\(service.unattendedStatus)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .desktopWorkspacePanel()
    }

    private var connectColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                columnHeading("连接远程电脑", symbol: "arrow.up.right.square")

                quickConnectCard
                tailscalePeersSection
                trustedDevicesSection
                nearbyDevicesSection
                recentPeersSection
            }
            .padding(.trailing, 4)
        }
    }

    private var quickConnectCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("快速连接", systemImage: "bolt.fill").font(.subheadline.weight(.semibold))
            TextField("目标地址：Tailscale IP、MagicDNS 或局域网 IP", text: $targetAddress)
                .focused($focusedField, equals: .address)
                .onSubmit { focusedField = .credential }

            HStack(spacing: 6) {
                Group {
                    if showCredential {
                        TextField("6 位临时密码、固定密码或连接码", text: $credential)
                    } else {
                        SecureField("6 位临时密码、固定密码或连接码", text: $credential)
                    }
                }
                .focused($focusedField, equals: .credential)
                .onSubmit(submitQuickConnect)

                Button { showCredential.toggle() } label: {
                    Image(systemName: showCredential ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(showCredential ? "隐藏密码" : "显示密码")
            }

            Text("自动识别 6 位临时密码（端口 \(DesktopDirectEndpoint.port.rawValue)）、8 位以上 Tailscale 固定密码（端口 \(DesktopTailscaleAddress.passwordPort.rawValue)）或兼容连接码。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(action: submitQuickConnect) { Label("连接", systemImage: "arrow.right") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmitQuickConnect)
            }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.large)
        .desktopWorkspacePanel(emphasized: true)
    }

    private func columnHeading(_ title: String, symbol: String) -> some View {
        Label {
            Text(title).font(.title3.weight(.semibold))
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(DesktopWorkspaceStyle.accent)
                .frame(width: 32, height: 32)
                .background(DesktopWorkspaceStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    @ViewBuilder
    private var tailscalePeersSection: some View {
        if !service.networkInfo.tailscalePeers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tailscale 在线 Mac").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(service.networkInfo.tailscalePeers) { peer in
                    let matchedTrusted = connectableTrustedDevices.first { trusted in
                        trusted.address == peer.ip || (peer.dnsName != nil && trusted.address == peer.dnsName)
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.name).font(.callout.weight(.medium)).lineLimit(1)
                            Text(peer.preferredAddress).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let matchedTrusted, let address = matchedTrusted.address {
                            Button("一键免密") {
                                service.connectTrusted(matchedTrusted.publicKey, address: address)
                            }.disabled(service.busy)
                        }
                        Button("填入地址") {
                            targetAddress = peer.preferredAddress
                            focusedField = .credential
                        }
                    }
                    .controlSize(.small)
                    .padding(10)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    @ViewBuilder
    private var trustedDevicesSection: some View {
        if !connectableTrustedDevices.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("已配对可信设备").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(connectableTrustedDevices) { device in
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.shield").foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name).font(.callout.weight(.medium)).lineLimit(1)
                            Text(device.address ?? "尚未记录 Tailscale 地址")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let address = device.address,
                           DesktopDirectEndpoint.parse(address, defaultPort: DesktopTailscaleAddress.port) != nil {
                            Button("无人值守连接") {
                                service.connectTrusted(device.publicKey, address: address)
                            }.disabled(service.busy)
                        } else {
                            Button("填写地址…") { showTrustedDevices = true }
                        }
                    }
                    .controlSize(.small)
                    .padding(10)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var nearbyDevicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("局域网附近设备").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if let browseMessage = service.browseMessage {
                Text(browseMessage).font(.caption).foregroundStyle(.secondary)
            }
            if service.nearby.isEmpty {
                if service.networkInfo.tailscalePeers.isEmpty && connectableTrustedDevices.isEmpty && service.recentPeers.isEmpty {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "network").foregroundStyle(DesktopWorkspaceStyle.accent)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("暂无自动发现的设备").font(.callout.weight(.medium))
                            Text("通过 Tailscale 跨网连接时，可在上方输入对方的地址和连接密码。")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .desktopWorkspacePanel(padding: 12)
                } else {
                    Text("同一局域网下打开接收的 Mac 会自动出现在这里。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ForEach(service.nearby) { device in
                    HStack(spacing: 10) {
                        Label(device.name, systemImage: "desktopcomputer").lineLimit(1)
                        Spacer()
                        Button("连接…") { nearbyRequest = device }.disabled(service.busy)
                    }
                    .controlSize(.small)
                    .padding(10)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    @ViewBuilder
    private var recentPeersSection: some View {
        if !service.recentPeers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("最近连接").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(service.recentPeers) { peer in
                    HStack(spacing: 10) {
                        Image(systemName: "clock").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.name).font(.callout.weight(.medium)).lineLimit(1)
                            Text(peer.address).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("填入") {
                            targetAddress = peer.address
                            focusedField = .credential
                        }
                        Button {
                            service.removeRecentPeer(address: peer.address)
                        } label: {
                            Image(systemName: "xmark")
                        }.buttonStyle(.borderless).help("移除记录")
                    }
                    .controlSize(.small)
                    .padding(10)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var shareSummaryText: String? {
        guard let temp = service.formattedTemporaryPassword else { return nil }
        let address = service.networkInfo.tailscaleDNSName ?? service.networkInfo.primaryAddress
        guard let address else { return nil }
        return "地址：\(address)\n临时密码：\(temp)"
    }

    private func submitQuickConnect() {
        guard canSubmitQuickConnect else { return }
        let value = credential
        credential = ""
        service.connect(address: targetAddress, credential: value)
    }

    private func copyPlain(_ value: String, badge: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        showCopiedBadge(badge)
    }

    private func copyConcealed(_ value: String, badge: String) {
        let item = NSPasteboardItem()
        item.setString(value, forType: .string)
        item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
        showCopiedBadge(badge)
    }

    private func showCopiedBadge(_ badge: String) {
        copiedBadge = badge
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if copiedBadge == badge { copiedBadge = nil }
        }
    }
}

private struct DesktopUnattendedPasswordSheet: View {
    @ObservedObject var service: DesktopDirectService
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var showPassword = false
    @State private var saving = false
    @State private var feedback: String?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Tailscale 固定密码无人值守", systemImage: "lock.shield").font(.title2.bold())
                Text("开启后，仅允许来自 Tailscale 内网的连接凭固定密码直接查看或控制此 Mac，无需桌面人工确认。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(service.hasUnattendedPassword ? "已设置固定访问密码（更换密码）" : "设置固定访问密码")
                                .font(.headline)
                            Spacer()
                            if service.hasUnattendedPassword {
                                Button("清除密码", role: .destructive) {
                                    service.clearUnattendedPassword()
                                    password = ""
                                    feedback = "已清除固定访问密码并关闭固定密码无人值守。"
                                }.controlSize(.small)
                            }
                        }

                        HStack(spacing: 8) {
                            Group {
                                if showPassword {
                                    TextField("至少 8 个字符的固定访问密码", text: $password)
                                } else {
                                    SecureField("至少 8 个字符的固定访问密码", text: $password)
                                }
                            }
                            Button { showPassword.toggle() } label: {
                                Image(systemName: showPassword ? "eye.slash" : "eye")
                            }.buttonStyle(.borderless)
                        }
                        .textFieldStyle(.roundedBorder)

                        HStack(spacing: 8) {
                            Button("随机生成强密码") {
                                password = DesktopDirectPassword.generateStrongFixed()
                                showPassword = true
                                feedback = "已生成随机密码，请复制保存后点击「保存固定密码」。"
                            }
                            if !password.isEmpty {
                                Button("复制当前密码") {
                                    let item = NSPasteboardItem()
                                    item.setString(password, forType: .string)
                                    item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.writeObjects([item])
                                    feedback = "已复制固定密码到剪贴板。"
                                }
                            }
                            Spacer()
                            Button(saving ? "正在保存…" : "保存固定密码") {
                                savePassword()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(saving || DesktopDirectPassword.validateFixed(password) != nil)
                        }.controlSize(.small)

                        if let validation = DesktopDirectPassword.validateFixed(password), !password.isEmpty {
                            Text(validation).font(.caption).foregroundStyle(.orange)
                        } else {
                            Text("本地仅在 macOS 钥匙串保存加盐 PBKDF2 校验摘要，不保存明文密码。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(6)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("启用仅限 Tailscale 的固定密码无人值守", isOn: Binding(
                            get: { service.unattendedPasswordSettings.enabled },
                            set: { service.setUnattendedPasswordEnabled($0) }
                        )).disabled(!service.hasUnattendedPassword)

                        DesktopShareDisplayPicker(center: service.center, selection: Binding(
                            get: { service.unattendedPasswordSettings.grant.shareDisplay },
                            set: { value in
                                var next = service.unattendedPasswordSettings
                                next.grant.virtualDisplayPreset = value.virtualPreset
                                service.updateUnattendedPasswordSettings(next)
                            }
                        ), allowsFixedDisplay: false)

                        Toggle("允许控制鼠标和键盘", isOn: Binding(
                            get: { service.unattendedPasswordSettings.grant.control },
                            set: { value in
                                var next = service.unattendedPasswordSettings
                                next.grant.control = value
                                service.updateUnattendedPasswordSettings(next)
                            }
                        ))

                        Toggle("共享系统声音", isOn: Binding(
                            get: { service.unattendedPasswordSettings.grant.audio },
                            set: { value in
                                var next = service.unattendedPasswordSettings
                                next.grant.audio = value
                                service.updateUnattendedPasswordSettings(next)
                            }
                        ))

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
                    }
                    .padding(6)
                }

                DesktopPermissionSection(permissions: service.center.permissions,
                                         control: service.unattendedPasswordSettings.grant.control,
                                         restart: service.center.restartForPermissions)

                Text(service.unattendedPasswordStatus).font(.caption).foregroundStyle(.secondary)
                if let feedback { Text(feedback).font(.caption).foregroundStyle(.green) }
                if let message = service.message { Text(message).font(.callout).foregroundStyle(.orange) }

                HStack {
                    Spacer()
                    Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
        .frame(width: 600, height: 680)
    }

    private func savePassword() {
        let candidate = password
        saving = true
        feedback = nil
        Task { @MainActor in
            let ok = await service.saveUnattendedPassword(candidate)
            saving = false
            if ok {
                password = ""
                showPassword = false
                feedback = "固定访问密码已保存并启用。"
            }
        }
    }
}

private struct DesktopTrustedDevicesView: View {
    @ObservedObject var service: DesktopDirectService
    @Environment(\.dismiss) private var dismiss
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("可信设备").font(.title2.bold())
                Toggle("允许已配对设备通过 Tailscale 无人值守", isOn: Binding(get: { service.unattendedEnabled }, set: service.setUnattended))
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
                DesktopPermissionSection(permissions: service.center.permissions, control: true, restart: service.center.restartForPermissions)
                Divider()
                if service.trustedDevices.isEmpty {
                    ContentUnavailableView("暂无可信设备", systemImage: "laptopcomputer",
                        description: Text("先使用临时密码或连接码建立直连，再在被控端的确认窗口中选择「记为可信设备」。"))
                        .frame(minHeight: 160)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(service.trustedDevices) { device in
                            DesktopTrustedDeviceRow(device: device, service: service)
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }.padding(24)
        }.frame(width: 600, height: 640)
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
    let device: DesktopNearbyDevice
    let connect: (NWEndpoint, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var credential = ""

    private var canSubmit: Bool {
        switch DesktopDirectCredential.parse(credential) {
        case .temporaryPassword, .legacyCode: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("连接 \(device.name)").font(.title2.bold())
            SecureField("输入被控 Mac 显示的 6 位临时密码或完整连接码", text: $credential)
                .onSubmit {
                    guard canSubmit else { return }
                    connect(device.endpoint, credential)
                    dismiss()
                }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("请求连接") {
                    connect(device.endpoint, credential)
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 440)
    }
}

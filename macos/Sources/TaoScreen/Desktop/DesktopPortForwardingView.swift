import SwiftUI

/// 以设备及规则列表为中心；只在端口映射窗口内建立专用连接。
struct DesktopPortForwardingSheet: View {
    @ObservedObject var service: DesktopPortService
    @State private var showingSettings = false
    private var selectedPeer: DesktopPeer? { service.knownPeers.first { $0.id == service.selectedPeerID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.left.arrow.right").font(.title2).foregroundStyle(Color.accentColor)
                Text("端口映射").font(.title2.weight(.semibold))
                Spacer()
                Picker("当前设备", selection: Binding(get: { service.selectedPeerID }, set: { id in
                    if let peer = service.knownPeers.first(where: { $0.id == id }) { service.openMapping(for: peer) }
                })) {
                    Text("选择设备").tag(Optional<UUID>.none)
                    ForEach(service.knownPeers) { peer in
                        Text(peer.name + (service.peers.contains(where: { $0.id == peer.id }) ? "" : " · 离线")).tag(Optional(peer.id))
                    }
                }.frame(maxWidth: 260)
                Button { Task { await service.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("刷新设备").disabled(!service.online)
                Button { showingSettings.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                    .help("端口服务设置")
                    .popover(isPresented: $showingSettings) {
                        VStack(alignment: .leading, spacing: 14) {
                            Toggle("开启此电脑的端口服务", isOn: $service.enabled)
                            Text(service.status).font(.caption).foregroundStyle(.secondary)
                            Toggle("自动允许同账号设备", isOn: Binding(get: { service.autoAccept }, set: { service.setAutoAccept($0) }))
                                .disabled(service.settingsAccountID == nil)
                            Text("允许对方通过此电脑访问指定服务。此设置独立于远程桌面授权。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(20).frame(width: 330)
                    }
            }.padding(20)
            Divider()
            if let message = service.message {
                HStack {
                    Label(message, systemImage: "exclamationmark.circle").font(.callout).textSelection(.enabled)
                    Spacer()
                    Button { service.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(12).foregroundStyle(.orange).background(Color.orange.opacity(0.07))
            }
            ForEach(service.pending) { session in
                DesktopPortConsentRow(session: session).padding(.horizontal, 20).padding(.top, 12)
            }
            if let peer = selectedPeer, let forwarder = service.mappingForwarder(for: peer) {
                DesktopPortMappingDeviceView(service: service, peer: peer, forwarder: forwarder,
                    session: service.mappingSession(for: peer.id))
                    .id((service.settingsAccountID ?? "") + peer.id.uuidString)
            } else {
                ContentUnavailableView("选择一台设备", systemImage: "network",
                    description: Text(service.settingsAccountID == nil ? "请先登录账号，再管理端口映射。" : "从设备卡片打开端口映射，或选择已在线的同账号电脑。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(minWidth: 900, minHeight: 540)
            .background(DesktopPortWindowCloseGuard(service: service))
            .task { service.activateMappingWindow() }
            .onChange(of: service.knownPeers) { _, peers in
                if service.mappingWindowActive, service.selectedPeerID == nil, let peer = peers.first { service.openMapping(for: peer) }
            }
    }
}

private struct DesktopPortMappingDeviceView: View {
    @ObservedObject var service: DesktopPortService
    let peer: DesktopPeer
    @ObservedObject var forwarder: DesktopPortForwarder
    let session: DesktopPortSession?
    private var available: Bool { service.online && service.peers.contains { $0.id == peer.id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Text(peer.name).font(.title2.weight(.semibold)).lineLimit(1).help(peer.name)
                Circle().fill(session?.connected == true ? Color.green : .secondary).frame(width: 7, height: 7)
                Text(session?.statusText ?? (available ? "未连接" : "设备离线"))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if let session {
                    Button("断开连接", role: .destructive) { session.disconnect() }
                } else {
                    Button("重新连接") { service.openMapping(for: peer) }
                        .disabled(!available).help(available ? "连接后自动启动已启用规则" : "请确认对方已开启端口服务")
                }
            }
            if forwarder.host {
                DesktopPortMappingTable(forwarder: forwarder, peerName: peer.name, incoming: true)
            } else {
                DesktopPortRulesEditor(forwarder: forwarder, peerName: peer.name,
                    connect: { service.openMapping(for: peer) }, connectionPending: session != nil)
            }
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct DesktopPortConsentRow: View {
    @ObservedObject var session: DesktopPortSession
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(session.peer.name) 请求端口映射", systemImage: "network.badge.shield.half.filled").font(.headline)
            Text("允许本次双向 TCP / UDP 转发，对方将能通过此电脑访问指定地址的服务。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("拒绝", role: .cancel) { session.reject() }
                Button("允许本次连接") { session.accept() }.buttonStyle(.borderedProminent)
            }
        }.padding(16).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct DesktopPortRequestBanner: View {
    @ObservedObject var service: DesktopPortService
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if let session = service.pending.first {
            HStack(spacing: 12) {
                Label("\(session.peer.name) 请求端口映射", systemImage: "arrow.left.arrow.right")
                Spacer()
                Button("拒绝") { session.reject() }
                Button("查看并授权…") {
                    service.selectedPeerID = session.peer.id; service.selectedSessionID = session.id
                    openWindow(id: "ports")
                }.buttonStyle(.borderedProminent)
            }.padding(12).background(Color.accentColor.opacity(0.08))
        }
    }
}

struct DesktopPortRulesEditor: View {
    @ObservedObject var forwarder: DesktopPortForwarder
    let peerName: String
    var connect: () -> Void = {}
    var connectionPending = false
    @State private var draft: DesktopPortRuleDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("映射列表").font(.headline)
                Spacer()
                Button { draft = .init() } label: { Label("添加", systemImage: "plus.circle") }
                    .disabled(!forwarder.canEdit || forwarder.rules.count >= DesktopPortLimits.rules)
            }
            if let error = forwarder.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            DesktopPortMappingTable(forwarder: forwarder, peerName: peerName,
                edit: { draft = .init(rule: $0) }, duplicate: { draft = .init(rule: $0, duplicate: true) },
                connect: { if !connectionPending { connect() } }, add: { draft = .init() })
            Text(forwarder.canStart ? "默认监听本机 127.0.0.1；目标地址可以是远端电脑或它能访问的局域网设备。" : "连接后自动启动已启用规则；离线时也可以添加、编辑或停用规则。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $draft) { value in
            DesktopPortRuleEditorSheet(draft: value, forwarder: forwarder, peerName: peerName) {
                if !forwarder.canStart && !connectionPending { connect() }
            }
        }
    }
}

struct DesktopPortMappingTable: View {
    @ObservedObject var forwarder: DesktopPortForwarder
    let peerName: String
    var incoming = false
    var edit: (DesktopPortRule) -> Void = { _ in }
    var duplicate: (DesktopPortRule) -> Void = { _ in }
    var connect: () -> Void = {}
    var add: () -> Void = {}
    @State private var error: String?
    @State private var removing: DesktopPortRule?
    private var rows: [DesktopPortRuleState] { incoming ? forwarder.incomingRules : forwarder.rules }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Table(rows) {
                TableColumn("名称") { state in
                    HStack(spacing: 9) {
                        if !incoming {
                            Toggle("启用 \(state.rule.title)", isOn: Binding(get: { state.rule.isEnabled }, set: { value in
                                perform { try forwarder.setEnabled(state.id, value); if value && !forwarder.canStart { connect() } }
                            })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                                .disabled(!forwarder.canEdit || state.phase == .stopping)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(state.rule.title).lineLimit(1).help(state.rule.title)
                            Text(state.rule.transport.rawValue + (state.rule.direction == .remoteToLocal ? " · 反向" : ""))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }.width(min: 170, ideal: 200)
                TableColumn(incoming || rows.contains(where: { $0.rule.direction == .remoteToLocal }) ? "监听端口" : "本地端口") { state in
                    Text(String(state.rule.listenPort)).monospacedDigit()
                        .help((state.rule.direction.listenerIsHost == incoming ? "此电脑" : peerName) + " " + state.rule.listener)
                }.width(75)
                TableColumn("目标地址") { state in Text(state.rule.destinationHost).lineLimit(1).textSelection(.enabled).help(state.rule.destination) }
                    .width(min: 110, ideal: 150)
                TableColumn("目标端口") { state in Text(String(state.rule.destinationPort)).monospacedDigit() }.width(75)
                TableColumn("映射状态") { state in
                    DesktopPortMappingStatus(state: state, incoming: incoming)
                }.width(min: 110, ideal: 140)
                TableColumn("操作") { state in
                    HStack(spacing: 6) {
                        if incoming {
                            Button("停止") { forwarder.stop(state.id) }.disabled(state.phase == .stopping)
                        } else {
                            if state.rule.isEnabled, state.phase == .failed, forwarder.canStart {
                                Button { perform { try forwarder.start(state.id) } } label: { Image(systemName: "arrow.clockwise") }.help("重试")
                            }
                            Menu {
                                Button("编辑") { edit(state.rule) }.disabled(state.running || !forwarder.canEdit)
                                Button("创建副本") { duplicate(state.rule) }
                                    .disabled(!forwarder.canEdit || rows.count >= DesktopPortLimits.rules)
                                Divider()
                                Button("删除", role: .destructive) { removing = state.rule }.disabled(state.running || !forwarder.canEdit)
                            } label: { Image(systemName: "ellipsis") }.menuIndicator(.hidden).fixedSize()
                                .help(state.running ? "停用后可编辑或删除；可随时创建副本" : "编辑、创建副本或删除")
                        }
                    }.controlSize(.small)
                }.width(70)
            }.frame(minHeight: 240)
                .overlay {
                    if rows.isEmpty {
                        ContentUnavailableView(incoming ? "暂无活跃映射" : "暂无映射规则", systemImage: "arrow.left.arrow.right", description: Text(incoming ? "对方启用规则后会显示在这里。" : "把远端服务映射到本地，像访问本机服务一样使用。"))
                            .overlay(alignment: .bottom) {
                                if !incoming { Button("添加映射规则", action: add).buttonStyle(.borderedProminent).disabled(!forwarder.canEdit).offset(y: 20) }
                            }
                    }
                }
            HStack(spacing: 14) {
                Text("规则 \(rows.count) / \(DesktopPortLimits.rules)")
                if !incoming { Text("已启用 \(rows.filter { $0.rule.isEnabled }.count)") }
                Text("监听 \(rows.filter { $0.phase == .listening }.count)")
                Text("异常 \(rows.filter { $0.phase == .failed || (incoming || $0.rule.isEnabled) && $0.error != nil }.count)")
                Spacer()
                Text("活动连接 \(rows.reduce(0) { $0 + $1.connections })")
            }.font(.caption).foregroundStyle(.secondary).padding(.top, 12)
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(.top, 8) }
        }
        .alert("确定要删除该规则吗？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("取消", role: .cancel) { removing = nil }
            Button("删除", role: .destructive) { if let rule = removing { perform { try forwarder.remove(rule.id) } }; removing = nil }
        } message: { Text("删除后规则“\(removing?.title ?? "")”无法恢复。") }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
    }
}

private struct DesktopPortMappingStatus: View {
    let state: DesktopPortRuleState
    let incoming: Bool
    private var label: String {
        if !incoming && !state.rule.isEnabled && !state.running { return "已停用" }
        switch state.phase {
        case .starting: return "连接中…"
        case .stopping: return "停止中…"
        case .failed: return "失败"
        case .listening: return state.error == nil ? "监听中" : "连接异常"
        case .stopped: return state.error == nil ? "等待连接" : "已停止"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).foregroundStyle(state.error != nil || state.phase == .failed ? Color.orange : state.phase == .listening ? .green : .secondary)
            if let error = state.error { Text(error).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
        }.help(state.error ?? (state.phase == .listening ? "监听已建立，不代表目标服务已可达。" : label))
    }
}

struct DesktopPortRuleEditorSheet: View {
    @State var draft: DesktopPortRuleDraft
    @ObservedObject var forwarder: DesktopPortForwarder
    let peerName: String
    var saved: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var showErrors = false
    @State private var advanced = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(draft.editing ? "编辑映射规则" : "添加映射规则").font(.title2.weight(.semibold))
            Text("通过 \(peerName) 访问目标服务").font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                field("名称", placeholder: "例如：开发后台（可选）", text: $draft.name, key: .name)
                Divider()
                field(draft.direction == .localToRemote ? "本地端口" : "远端监听端口", placeholder: "请输入端口", text: $draft.listenPort, key: .listenPort)
                Divider()
                field("目标地址", placeholder: "请输入目标地址", text: $draft.destinationHost, key: .destinationHost)
                Divider()
                field("目标端口", placeholder: "请输入端口", text: $draft.destinationPort, key: .destinationPort)
            }.padding(.horizontal, 14).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            DisclosureGroup("高级设置", isExpanded: $advanced) {
                VStack(spacing: 12) {
                    Picker("协议", selection: $draft.transport) {
                        ForEach(DesktopPortProtocol.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    Picker("转发方向", selection: $draft.direction) {
                        ForEach(DesktopPortDirection.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("监听范围", selection: $draft.listenAddress) {
                        Text("仅监听本机 · 127.0.0.1").tag("127.0.0.1")
                        Text("共享给局域网 · 0.0.0.0").tag("0.0.0.0")
                    }
                }.padding(.top, 10)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Divider()
            HStack {
                Toggle("保存后立即启用", isOn: $draft.isEnabled).toggleStyle(.checkbox)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!forwarder.canEdit)
            }
        }.padding(24).frame(width: 520).fixedSize(horizontal: false, vertical: true)
            .onAppear { advanced = draft.transport != .tcp || draft.direction != .localToRemote || draft.listenAddress != "127.0.0.1" }
    }
    private func field(_ title: String, placeholder: String, text: Binding<String>, key: DesktopPortRuleDraft.Field) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(title).frame(width: 100, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(title)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(showErrors && draft.errors[key] != nil ? Color.red : .clear))
                if showErrors, let message = draft.errors[key] { Text(message).font(.caption).foregroundStyle(.red) }
            }
        }.padding(.vertical, 12)
    }
    private func save() {
        showErrors = true
        do {
            let rule = try draft.makeRule()
            try forwarder.save(rule)
            if rule.isEnabled { saved() }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

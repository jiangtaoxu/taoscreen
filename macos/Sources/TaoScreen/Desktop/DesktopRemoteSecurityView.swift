import SwiftUI

struct DesktopRemoteSecuritySettings: View {
    @ObservedObject var center: DesktopCenter
    @State private var password = ""
    @State private var scope: DesktopRemotePasswordScope?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("远程登录密码 · 仅此电脑保存")).font(.subheadline.weight(.semibold))
            SecureField(L10n.text("被控 Mac 的登录密码"), text: $password).privacySensitive()
            HStack {
                Button(center.hasSavedRemotePassword ? L10n.text("更换密码") : L10n.text("保存到本机钥匙串")) {
                    guard let scope else { return }
                    do { try center.saveRemotePassword(password, for: scope); password = ""; error = nil }
                    catch { self.error = error.localizedDescription }
                }.disabled(scope == nil || password.isEmpty || center.authenticatingRemotePassword)
                Button(L10n.text("删除本机密码"), role: .destructive) {
                    guard let scope else { return }
                    do { try center.deleteRemotePassword(for: scope); password = ""; error = nil }
                    catch { self.error = error.localizedDescription }
                }.disabled(scope == nil || center.authenticatingRemotePassword)
            }
            if let status = error ?? center.remotePasswordMessage {
                Text(status).font(.caption).foregroundStyle(error == nil ? Color.secondary : .orange)
            } else if center.hasSavedRemotePassword {
                Label(L10n.text("已保存到本机，使用时需要验证"), systemImage: "key.fill").font(.caption).foregroundStyle(.secondary)
            }
            Text(L10n.text("密码按账号和远程设备保存在此 Mac。点击「验证后解锁」后，请用此 Mac 的触控 ID 或登录密码授权。升级前保存的密码需要重新保存一次。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(center.authenticatingRemotePassword ? L10n.text("正在验证本机身份…") : L10n.text("验证后解锁")) { center.unlockWithSavedPassword() }.disabled(!center.canUnlockWithSavedPassword)
            if let message = center.remoteSecurity.unlockMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Toggle(L10n.text("断开连接后锁定被控电脑"), isOn: Binding(get: { center.remoteSecurity.selectedLock }, set: { center.setRemoteDisconnectLock($0) }))
                .disabled(!center.connected || !center.controlAllowed || !center.remoteSecurity.supported || center.remoteSecurity.lockChanging)
            Text(center.remoteSecurity.lockStatus).font(.caption)
                .foregroundStyle(center.remoteSecurity.lockFailure == nil ? Color.secondary : .orange)
            if center.remoteSecurity.lockFailure != nil {
                Button(L10n.text("重新确认断连锁屏")) { center.setRemoteDisconnectLock(center.remoteSecurity.retryLock ?? center.remoteSecurity.selectedLock) }
                    .disabled(!center.connected || !center.controlAllowed || !center.remoteSecurity.supported || center.remoteSecurity.lockChanging)
            }
            Text(L10n.text("被控端确认后记住此设备的选择。手动断开或异常断连且重连失败时，由被控端发送系统锁屏快捷键；短暂掉线重连不会立即锁屏。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .task(id: center.remotePasswordScope?.key) {
            password = ""; error = nil; scope = center.remotePasswordScope
        }
        .onDisappear { password = "" }
    }
}

struct DesktopLockedSessionBanner: View {
    @ObservedObject var center: DesktopCenter
    @Binding var settingsPresented: Bool
    private var unlockTitle: String {
        if center.authenticatingRemotePassword { return L10n.text("正在验证本机身份…") }
        return center.remoteSecurity.unlockRequest == nil ? L10n.text("验证后解锁") : L10n.text("等待远端解锁…")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(center.controlAllowed ? L10n.text("远端已锁定 · 先点击远端密码输入框") : L10n.text("远端已锁定 · 仅观看"), systemImage: "lock.fill")
            if center.controlAllowed {
                HStack {
                    Button(unlockTitle) { center.unlockWithSavedPassword() }
                        .disabled(!center.canUnlockWithSavedPassword)
                    Button(center.hasSavedRemotePassword ? L10n.text("密码设置…") : L10n.text("保存远程密码…")) {
                        center.sendInput(.init(kind: "release")); center.setRemoteShortcutsActive(false)
                        settingsPresented = true
                    }
                }
                if let message = center.remoteSecurity.unlockMessage {
                    Text(message).font(.caption)
                } else if !center.remoteSecurity.supported {
                    Text(L10n.text("验证后解锁需要两端均为支持的版本；仍可在远端画面手动输入密码。")).font(.caption)
                }
            }
        }
        .font(.callout).padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(8)
        .sheet(isPresented: $settingsPresented) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.text("\(center.peer?.name ?? L10n.text("远程电脑")) · 本机密码设置")).font(.headline)
                ScrollView { DesktopRemoteSecuritySettings(center: center) }
                HStack { Spacer(); Button(L10n.text("完成")) { settingsPresented = false } }
            }.padding(20).frame(width: 480, height: 540)
        }
    }
}

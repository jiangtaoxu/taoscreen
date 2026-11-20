import Combine
import Foundation
import SwiftUI

/// 按服务生命周期持有活动请求：待机和暂时断网也保持运行，屏幕仍可熄灭和锁定。
@MainActor
final class RemoteAvailability: ObservableObject {
    static let shared = RemoteAvailability()
    static let enabledKey = "taoscreen.remote.keepAvailable"
    enum Service: Hashable { case desktop, direct, directUnattended, ports }

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Self.enabledKey); update() }
    }
    @Published private(set) var keepingAwake = false
    private var services: Set<Service> = []
    private let defaults: UserDefaults
    private let begin: () -> NSObjectProtocol
    private let end: (NSObjectProtocol) -> Void
    private var activity: NSObjectProtocol?

    init(defaults: UserDefaults = DesktopRuntime.defaults,
         begin: @escaping () -> NSObjectProtocol = {
             ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: L10n.text("TaoScreen 远程服务保持可连接"))
         }, end: @escaping (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }) {
        self.defaults = defaults; self.begin = begin; self.end = end
        // 保留旧版明确设置过的偏好；未设置过的新用户默认开启。
        if defaults.object(forKey: Self.enabledKey) == nil {
            defaults.set(defaults.object(forKey: "taoscreen.remote.preventSleep") as? Bool ?? true, forKey: Self.enabledKey)
        }
        enabled = defaults.bool(forKey: Self.enabledKey)
    }

    func setActive(_ service: Service, _ active: Bool) {
        if active { services.insert(service) } else { services.remove(service) }
        update()
    }

    func shutdown() { services.removeAll(); update() }

    private func update() {
        let needed = enabled && !services.isEmpty
        if needed, activity == nil { activity = begin() }
        if !needed, let activity { end(activity); self.activity = nil }
        keepingAwake = activity != nil
    }

    deinit { if let activity { end(activity) } }
}

struct RemoteAvailabilitySettings: View {
    @ObservedObject private var availability = RemoteAvailability.shared
    var body: some View {
        Section {
            Toggle(L10n.text("远程服务开启期间保持 Mac 唤醒"), isOn: $availability.enabled)
            Text(availability.keepingAwake ? L10n.text("正在保持唤醒，等待远程连接") : L10n.text("当前未保持唤醒"))
                .foregroundStyle(.secondary)
        } header: {
            Text(L10n.text("远程连接与睡眠"))
        } footer: {
            Text(L10n.text("远程桌面或独立端口服务运行时，即使没有连接也阻止自动睡眠。允许锁屏和熄屏，会增加电池耗电；合盖或手动睡眠仍可能中断连接。锁屏时仅已配置的无人值守连接可继续使用。"))
        }
    }
}

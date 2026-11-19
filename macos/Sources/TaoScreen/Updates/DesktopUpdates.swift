import AppKit
import Combine
import Sparkle
import SwiftUI

/// 与账号及业务服务解耦；后台仅探测，用户点击后才展示 Sparkle 的版本说明和安装流程。
@MainActor
final class DesktopUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = DesktopUpdates()
    private let feedURL = DesktopUpdates.configuredFeed(in: Bundle.main.infoDictionary ?? [:])

    static func configuredFeed(in info: [String: Any]) -> String? {
        guard let feed = info["SUFeedURL"] as? String,
              let url = URLComponents(string: feed), url.scheme == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil, url.fragment == nil,
              let key = info["SUPublicEDKey"] as? String, Data(base64Encoded: key)?.count == 32 else { return nil }
        return feed
    }

    @Published private(set) var availableVersion: String?
    @Published private(set) var canCheck = false
    @Published private(set) var status = "尚未检查"
    private var controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?
    private var timer: AnyCancellable?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未打包"
    }

    func startMonitoring() {
        guard controller == nil else { return }
        // swift run / 单元测试并非可替换的应用包，不启动安装器。
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            status = "请使用打包后的 TaoScreen 检查更新"
            return
        }
        guard feedURL != nil else {
            status = "此构建尚未配置自动更新"
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.startUpdater()
        controller.updater.automaticallyChecksForUpdates = false
        controller.updater.automaticallyDownloadsUpdates = false
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheck = canCheck }
        }
        probe()
        timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.probe() }
    }

    func feedURLString(for updater: SPUUpdater) -> String? { feedURL }

    func probe() {
        guard let updater = controller?.updater, updater.canCheckForUpdates else { return }
        status = "正在检查…"
        updater.checkForUpdateInformation()
    }

    /// 使用标准用户流程：先展示版本说明；选择安装后才下载、验证、替换并重启。
    func downloadUpdate() {
        guard canCheck else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
        status = "可更新至 \(item.displayVersionString)"
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableVersion = nil
        status = "已是最新版本"
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let failure = error as NSError
        if failure.domain == SUSparkleErrorDomain && failure.code == Int(SUError.noUpdateError.rawValue) {
            availableVersion = nil
        }
        // 断网和安装失败保留已发现的入口，用户仍可点击重试。
        status = Self.message(for: failure)
    }

    static func message(for error: NSError) -> String {
        if error.domain == SUSparkleErrorDomain {
            switch error.code {
            case Int(SUError.noUpdateError.rawValue):
                let reason = (error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.int32Value
                switch reason {
                case SPUNoUpdateFoundReason.onLatestVersion.rawValue: return "已是最新版本"
                case SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue: return "当前版本高于服务器发布版本"
                case SPUNoUpdateFoundReason.systemIsTooOld.rawValue: return "新版本需要更高版本的 macOS"
                case SPUNoUpdateFoundReason.systemIsTooNew.rawValue: return "新版本暂不支持当前 macOS"
                case SPUNoUpdateFoundReason.hardwareDoesNotSupportARM64.rawValue: return "新版本仅支持 Apple Silicon"
                default: return "暂无适用于当前设备的更新"
                }
            case Int(SUError.installationCanceledError.rawValue): return "已取消更新，可稍后重试"
            default: break
            }
        }
        return "检查或更新失败：\(error.localizedDescription)"
    }
}

struct DesktopUpdateButton: View {
    @ObservedObject private var updates = DesktopUpdates.shared
    var body: some View {
        if let version = updates.availableVersion {
            Button { updates.downloadUpdate() } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color.blue)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!updates.canCheck)
            .help("下载并更新至 \(version)")
            .accessibilityLabel("下载并更新至 \(version)")
        }
    }
}

struct DesktopUpdateSettings: View {
    @ObservedObject private var updates = DesktopUpdates.shared
    var body: some View {
        Section("应用更新") {
            LabeledContent("当前版本", value: updates.currentVersion)
            Text(updates.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Button(updates.availableVersion == nil ? "检查更新…" : "下载并更新…") { updates.downloadUpdate() }
                .disabled(!updates.canCheck)
        }
    }
}

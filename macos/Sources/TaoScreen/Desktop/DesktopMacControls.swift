import AppKit
import SwiftUI

/// 发送 macOS 标准快捷键，不修改被控电脑的快捷键配置。
enum DesktopMacControl: String, CaseIterable, Identifiable {
    case allWindows, dock, appWindows, desktop, fullScreen, escape
    var id: String { rawValue }
    var title: String {
        switch self {
        case .allWindows: L10n.text("所有窗口")
        case .dock: L10n.text("显示 Dock")
        case .appWindows: L10n.text("当前应用窗口")
        case .desktop: L10n.text("显示桌面")
        case .fullScreen: L10n.text("切换全屏")
        case .escape: L10n.text("退出当前界面（Esc）")
        }
    }
    var symbol: String {
        switch self {
        case .allWindows: "rectangle.3.group"
        case .dock: "dock.rectangle"
        case .appWindows: "macwindow.on.rectangle"
        case .desktop: "desktopcomputer"
        case .fullScreen: "arrow.up.left.and.arrow.down.right"
        case .escape: "escape"
        }
    }
    var shortcut: (key: UInt16, flags: CGEventFlags, title: String) {
        switch self {
        case .allWindows: (126, .maskControl, "⌃↑")
        case .dock: (99, .maskControl, "⌃F3")
        case .appWindows: (125, .maskControl, "⌃↓")
        case .desktop: (103, [], "F11")
        case .fullScreen: (3, [.maskControl, .maskCommand], "⌃⌘F")
        case .escape: (53, [], "Esc")
        }
    }
    var inputs: [DesktopInput] {
        let shortcut = shortcut
        // CGEvent 要求组合键包含真实的修饰键状态转换，不能只给主键附加 flags。
        let modifiers: [(UInt16, CGEventFlags)] = [(59, .maskControl), (58, .maskAlternate), (56, .maskShift), (55, .maskCommand)]
        let held = modifiers.filter { shortcut.flags.contains($0.1) }
        var inputs: [DesktopInput] = [.init(kind: "release")]
        var flags: CGEventFlags = []
        for (key, modifier) in held {
            flags.insert(modifier)
            inputs.append(.init(kind: "key", down: true, key: key, flags: flags.rawValue))
        }
        inputs.append(.init(kind: "key", down: true, key: shortcut.key, flags: flags.rawValue))
        inputs.append(.init(kind: "key", down: false, key: shortcut.key, flags: flags.rawValue))
        for (key, modifier) in held.reversed() {
            flags.remove(modifier)
            inputs.append(.init(kind: "key", down: false, key: key, flags: flags.rawValue))
        }
        return inputs
    }
}

struct DesktopMacControls: View {
    @ObservedObject var center: DesktopCenter
    let releaseFocus: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            ForEach([DesktopMacControl.allWindows, .dock]) { action in
                Button { perform(action) } label: {
                    Image(systemName: action.symbol).frame(width: 28, height: 28)
                }.help(L10n.text("被控 Mac：\(action.title)（\(action.shortcut.title)）"))
                    .accessibilityLabel(action.title)
            }
            Menu {
                ForEach(DesktopMacControl.allCases) { action in
                    Button { perform(action) } label: { Label(action.title + " · " + action.shortcut.title, systemImage: action.symbol) }
                }
                Divider()
                Text(L10n.text("操作被控 Mac；使用该 Mac 的标准快捷键。自定义或关闭系统快捷键后需在该 Mac 恢复。"))
            } label: { Image(systemName: "ellipsis.circle").frame(width: 28, height: 28) }
                .help(L10n.text("被控 Mac 操作")).accessibilityLabel(L10n.text("更多 Mac 操作"))
        }.buttonStyle(.plain).disabled(!center.canPerformMacControl)
    }
    private func perform(_ action: DesktopMacControl) {
        releaseFocus()
        center.performMacControl(action)
    }
}

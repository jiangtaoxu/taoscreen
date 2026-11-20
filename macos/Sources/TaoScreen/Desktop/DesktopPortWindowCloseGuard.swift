import AppKit
import SwiftUI

/// 关闭映射窗口前确认停止本机发起的映射，保留接收端服务及远程桌面。
struct DesktopPortWindowCloseGuard: NSViewRepresentable {
    let service: DesktopPortService
    func makeCoordinator() -> Coordinator { Coordinator(service: service) }
    func makeNSView(context: Context) -> WindowProbe {
        let view = WindowProbe()
        view.attach = { [weak coordinator = context.coordinator] window in coordinator?.attach(window) }
        return view
    }
    func updateNSView(_ view: WindowProbe, context: Context) { context.coordinator.service = service }
    static func dismantleNSView(_ view: WindowProbe, coordinator: Coordinator) { coordinator.detach() }

    final class WindowProbe: NSView {
        var attach: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach?(window) }
    }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        var service: DesktopPortService
        private weak var window: NSWindow?
        private weak var previous: NSWindowDelegate?
        private var confirming = false
        private var approved = false
        init(service: DesktopPortService) { self.service = service }
        func attach(_ window: NSWindow?) {
            guard self.window !== window else { return }
            detach(); self.window = window
            if let window { previous = window.delegate; window.delegate = self }
        }
        func detach() {
            if let window, window.delegate === self { window.delegate = previous }
            window = nil; previous = nil
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if approved { return previous?.windowShouldClose?(sender) ?? true }
            if !service.hasOutgoingMappings {
                service.disconnectOutgoingMappings()
                return previous?.windowShouldClose?(sender) ?? true
            }
            guard !confirming else { return false }
            confirming = true
            let alert = NSAlert()
            alert.messageText = L10n.text("确定要关闭端口映射吗？")
            alert.informativeText = L10n.text("关闭后将断开本机发起的映射连接，所有对应规则停止监听。规则及启用状态保留，下次连接后恢复。")
            alert.addButton(withTitle: L10n.text("关闭并断开"))
            alert.addButton(withTitle: L10n.text("取消"))
            alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
                guard let self else { return }
                self.confirming = false
                if response == .alertFirstButtonReturn {
                    self.service.disconnectOutgoingMappings(); self.approved = true
                    sender?.performClose(nil)
                    self.approved = false
                }
            }
            return false
        }
        override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || previous?.responds(to: selector) == true }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            previous?.responds(to: selector) == true ? previous : super.forwardingTarget(for: selector)
        }
    }
}

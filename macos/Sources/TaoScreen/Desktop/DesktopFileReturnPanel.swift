import AppKit
import SwiftUI

/// 被控端的原生拖放目标。窗口随共享画面传输，也可用本机鼠标操作。
@MainActor
final class DesktopFileReturnPanel {
    private enum Stage {
        case hidden, drop, confirm([URL], retry: Bool), transfer(DesktopTransferState)
    }

    private final class Model: ObservableObject {
        @Published var stage: Stage = .hidden
        @Published var hovering = false
        var peer = ""
    }

    private struct Gesture {
        let pasteboardVersion: Int
        var remote: Bool
        var releasedAt: Date?
    }

    private let model = Model()
    private var panel: NSPanel?
    private var displayID: CGDirectDisplayID?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var probe: Timer?
    private var gesture: Gesture?
    private var allowed: (() -> Bool)?
    private var send: (([URL]) -> Bool)?
    private var cancel: (() -> Void)?

    func start(displayID: CGDirectDisplayID, peer: String, allowed: @escaping () -> Bool,
               send: @escaping ([URL]) -> Bool, cancel: @escaping () -> Void) {
        self.displayID = displayID
        model.peer = peer
        self.allowed = allowed
        self.send = send
        self.cancel = cancel
        guard localMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event) }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event) }
        }
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil; globalMonitor = nil
        allowed = nil; send = nil; cancel = nil
        resetGesture()
        hide()
        panel?.close(); panel = nil
    }

    private func observe(_ event: NSEvent) {
        guard let event = event.cgEvent,
              event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(ProcessInfo.processInfo.processIdentifier) else { return }
        observe(event.type, remote: false)
    }

    func observe(_ type: CGEventType, remote: Bool) {
        switch type {
        case .leftMouseDown:
            guard allowed?() == true else { return }
            // The posted remote event can also be delivered to an AppKit monitor.
            if gesture?.remote == true, !remote { return }
            resetGesture()
            gesture = Gesture(pasteboardVersion: NSPasteboard(name: .drag).changeCount, remote: remote)
        case .leftMouseDragged:
            guard gesture != nil, allowed?() == true else { return }
            if remote { gesture?.remote = true }
            guard probe == nil else { return }
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkDrag() }
            }
            probe = timer
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .eventTracking)
        case .leftMouseUp:
            gesture?.releasedAt = .now
            if probe == nil { resetGesture() }
        default: break
        }
    }

    private func checkDrag() {
        guard let gesture else { resetGesture(); return }
        // Allow AppKit to deliver performDragOperation after a posted mouse-up.
        if allowed?() != true || gesture.releasedAt.map({ Date().timeIntervalSince($0) >= 0.25 }) == true {
            resetGesture()
            if case .drop = model.stage { hide() }
            return
        }
        guard gesture.releasedAt == nil else { return }
        if !gesture.remote, NSEvent.pressedMouseButtons & 1 == 0 {
            self.gesture?.releasedAt = .now
            return
        }
        let pasteboard = NSPasteboard(name: .drag)
        if pasteboard.changeCount != gesture.pasteboardVersion,
           pasteboard.availableType(from: [.fileURL, .init("NSFilenamesPboardType")]) != nil {
            switch model.stage {
            case .hidden: show(.drop)
            case .transfer(let state) where !state.active: show(.drop)
            default: break
            }
        }
    }

    private func resetGesture() {
        probe?.invalidate(); probe = nil; gesture = nil
    }

    private var acceptsDrop: Bool {
        guard case .drop = model.stage else { return false }
        return allowed?() == true
    }

    private func receive(_ urls: [URL]) -> Bool {
        guard acceptsDrop, !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
        resetGesture()
        model.hovering = false
        show(.confirm(urls, retry: false))
        return true
    }

    private func confirm() {
        guard case .confirm(let urls, _) = model.stage else { return }
        guard allowed?() == true, send?(urls) == true else {
            show(.confirm(urls, retry: true))
            return
        }
    }

    func updateTransfer(_ state: DesktopTransferState) {
        guard localMonitor != nil else { return }
        show(.transfer(state))
    }

    private func hide() {
        model.stage = .hidden
        model.hovering = false
        panel?.orderOut(nil)
    }

    private func show(_ stage: Stage) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { hide(); return }
        model.stage = stage
        let frame = CGRect(x: screen.visibleFrame.maxX - 344, y: screen.visibleFrame.minY + 18, width: 326, height: 142)
        let panel = self.panel ?? makePanel(frame: frame)
        guard !panel.isVisible else { return }
        panel.setFrame(frame, display: false)
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = animate ? 0 : 1
        if animate { panel.setFrameOrigin(CGPoint(x: frame.minX, y: frame.minY - 10)) }
        panel.orderFrontRegardless()
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 1
                panel.animator().setFrameOrigin(frame.origin)
            }
        }
    }

    private func makePanel(frame: CGRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let target = DropView(frame: CGRect(origin: .zero, size: frame.size))
        target.registerForDraggedTypes([.fileURL, .init("NSFilenamesPboardType")])
        target.canDrop = { [weak self] in self?.acceptsDrop == true }
        target.hover = { [weak self] in self?.model.hovering = $0 }
        target.receive = { [weak self] in self?.receive($0) == true }
        let content = HostingView(rootView: Content(model: model, confirm: { [weak self] in self?.confirm() },
                                                    dismiss: { [weak self] in self?.hide() },
                                                    cancel: { [weak self] in self?.cancel?() }))
        content.frame = target.bounds
        content.autoresizingMask = [.width, .height]
        target.addSubview(content)
        panel.contentView = target
        self.panel = panel
        return panel
    }

    private final class HostingView: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private final class DropView: NSView {
        var canDrop: (() -> Bool)?
        var hover: ((Bool) -> Void)?
        var receive: (([URL]) -> Bool)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            let accepts = canDrop?() == true && sender.draggingSourceOperationMask.contains(.copy)
                && sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            hover?(accepts)
            return accepts ? .copy : []
        }
        override func draggingExited(_ sender: NSDraggingInfo?) { hover?(false) }
        override func draggingEnded(_ sender: NSDraggingInfo) { hover?(false) }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard canDrop?() == true, sender.draggingSourceOperationMask.contains(.copy),
                  let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
            return receive?(urls) == true
        }
    }

    private struct Content: View {
        @ObservedObject var model: Model
        let confirm: () -> Void
        let dismiss: () -> Void
        let cancel: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 9) {
                switch model.stage {
                case .hidden: EmptyView()
                case .drop:
                    Label("拖到这里，发送到控制端", systemImage: "arrow.up.doc")
                        .font(.headline)
                    Text("松开后确认发送").foregroundStyle(.secondary)
                case .confirm(let urls, let retry):
                    Label("发送到 \(model.peer)", systemImage: "arrow.up.doc").font(.headline).lineLimit(1)
                    if let first = urls.first {
                        Text(urls.count == 1 ? first.lastPathComponent : "\(first.lastPathComponent) 等 \(urls.count) 项")
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Text(retry ? "文件通道暂不可用，请重试" : "保存到 下载 / TaoScreen")
                        .foregroundStyle(retry ? Color.orange : .secondary)
                    HStack {
                        Spacer()
                        Button("取消", action: dismiss)
                        Button("发送", action: confirm).buttonStyle(.borderedProminent)
                    }
                case .transfer(let state):
                    HStack {
                        Label(state.active ? "正在发送到控制端" : title(state.phase),
                              systemImage: state.active ? "arrow.up.doc" : state.phase == .completed ? "checkmark.circle.fill" : "info.circle")
                            .font(.headline)
                        Spacer()
                        if state.active { Button("取消", action: cancel) }
                        else { Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless).help("关闭") }
                    }
                    Text(state.message).lineLimit(2).truncationMode(.middle)
                    if state.active {
                        if let progress = state.progress {
                            HStack {
                                ProgressView(value: progress).accessibilityLabel("文件发送进度")
                                Text(progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                            }
                        } else { ProgressView().controlSize(.small) }
                    }
                }
            }
            .font(.callout)
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(model.hovering ? Color.accentColor : .primary.opacity(0.14),
                                  lineWidth: model.hovering ? 2 : 1)
                    .allowsHitTesting(false)
            }
        }

        private func title(_ phase: DesktopTransferState.Phase) -> String {
            switch phase {
            case .completed: "发送完成"
            case .cancelled: "已取消"
            case .failed: "发送失败"
            default: "请在控制端确认"
            }
        }
    }
}

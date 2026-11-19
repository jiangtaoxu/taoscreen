import AppKit
import Carbon
import OSLog

/// Owns one real AppKit drag. The proxy is nonactivating and disappears as soon
/// as AppKit takes ownership. General pasteboard and target focus are untouched.
@MainActor
final class DesktopNativeDrag: NSObject {
    enum Outcome: Equatable { case accepted, rejected, cancelled, unavailable, timedOut }
    private static let log = Logger(subsystem: "com.xujiangtao.taoscreen", category: "drop")
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var panel: NSPanel?
    private var view: SourceView?
    private var timers: [Timer] = []
    private var allowed: (() -> Bool)?
    private var validateTarget: (() -> Bool)?
    private var eventTap: CFMachPort?
    private var eventSource: CFRunLoopSource?
    private var marker = Int64.random(in: 1...Int64.max)
    private var eventNumber = Int64.random(in: 1...Int64(Int32.max))
    private var lastPoint = CGPoint.zero
    private var held = false
    private var sessionStarted = false
    private var destination = CGPoint.zero
    private var cancelling: Outcome?
    private var activeID: UUID?
    private(set) var isActive = false
    var onDiagnostic: ((String) -> Void)?
    private func diagnose(_ stage: String) {
        Self.log.notice("native-drag stage=\(stage, privacy: .public)")
        onDiagnostic?(stage)
    }

    /// Geometry uses global Quartz points, including negative secondary displays.
    nonisolated static func geometry(at point: CGPoint, display: CGRect, appKitTop: CGFloat) -> (start: CGPoint, panel: CGRect) {
        let offset: CGFloat = point.x - display.minX >= 32 ? -24 : 24
        let start = CGPoint(x: min(display.maxX - 1, max(display.minX, point.x + offset)), y: point.y)
        return (start, CGRect(x: start.x - 6, y: appKitTop - start.y - 6, width: 12, height: 12))
    }

    func deliver(_ urls: [URL], at point: CGPoint, display: CGRect,
                 allowed: @escaping () -> Bool, validateTarget: @escaping () -> Bool) async -> Outcome {
        guard !isActive, !Task.isCancelled, !urls.isEmpty, urls.allSatisfy(\.isFileURL),
              allowed(), validateTarget(), AXIsProcessTrusted(), CGPreflightPostEventAccess(),
              !CGEventSource.buttonState(.combinedSessionState, button: .left),
              !IsSecureEventInputEnabled(), let screen = NSScreen.screens.first else { return .unavailable }
        let id = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                self.allowed = allowed; self.validateTarget = validateTarget
                isActive = true; activeID = id; sessionStarted = false; cancelling = nil; destination = point
                marker = Int64.random(in: 1...Int64.max)
                let geometry = Self.geometry(at: point, display: display, appKitTop: screen.frame.maxY)
                let panel = NSPanel(contentRect: geometry.panel, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.level = .floating
                panel.hidesOnDeactivate = false
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
                panel.isOpaque = false; panel.backgroundColor = .windowBackgroundColor; panel.hasShadow = false
                // WindowServer excludes fully transparent/nearly invisible source
                // windows from mouse hit testing. Hide only AFTER AppKit starts.
                panel.alphaValue = 0.1
                let view = SourceView(urls: urls, owner: self, id: id)
                panel.contentView = view; self.panel = panel; self.view = view
                guard installObserver() else { finish(.unavailable); return }
                panel.orderFrontRegardless()
                lastPoint = geometry.start
                schedule(0.08) { self.post(.mouseMoved, at: geometry.start) }
                schedule(0.14) {
                    self.held = true
                    self.post(.leftMouseDown, at: geometry.start)
                }
                // Only bootstrap here. Motion and release are scheduled from
                // AppKit's actual start callback, so a busy target cannot consume
                // the hover interval before its dragging session even exists.
                schedule(0.22) {
                    let direction: CGFloat = point.x >= geometry.start.x ? 1 : -1
                    self.post(.leftMouseDragged, at: CGPoint(x: geometry.start.x + direction * 3, y: point.y))
                }
                schedule(2) {
                    if !self.sessionStarted { self.diagnose("session-not-started"); self.cancel(outcome: .unavailable) }
                }
                schedule(5) { self.cancel(outcome: .timedOut) }
            }
        }, onCancel: { Task { @MainActor [weak self] in if self?.activeID == id { self?.cancel() } } })
    }

    private func driveSession() {
        let start = lastPoint
        // Hide the source before moving onto the real target. Keep the source
        // view alive until the end callback, as required by AppKit.
        schedule(0.02) { self.panel?.orderOut(nil) }
        for step in 1...12 {
            schedule(0.04 + Double(step) / 60) {
                let fraction = CGFloat(step) / 12
                let eased = fraction * fraction * (3 - 2 * fraction)
                self.post(.leftMouseDragged, at: CGPoint(x: start.x + (self.destination.x - start.x) * eased,
                                                       y: start.y + (self.destination.y - start.y) * eased))
            }
        }
        schedule(0.50) {
            guard self.validateTarget?() == true else { self.diagnose("target-changed"); self.cancel(); return }
            self.held = false
            self.post(.leftMouseUp, at: self.destination)
        }
    }

    func cancel() { cancel(outcome: .cancelled) }

    private func cancel(outcome: Outcome) {
        guard isActive, cancelling == nil else { return }
        cancelling = outcome
        timers.forEach { $0.invalidate() }; timers.removeAll()
        if sessionStarted {
            for down in [true, false] {
                if let event = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down) { post(event) }
            }
        }
        if held { held = false; post(.leftMouseUp, at: lastPoint) }
        panel?.orderOut(nil)
        // Keep the source alive until AppKit reports the end of its drag. The
        // watchdog also handles a session that never began or lost its callback.
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(outcome) }
        }
        timers.append(timer); RunLoop.main.add(timer, forMode: .common)
    }

    private func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive, self.cancelling == nil else { return }
                guard self.allowed?() == true, !IsSecureEventInputEnabled() else { self.cancel(); return }
                action()
            }
        }
        timers.append(timer); RunLoop.main.add(timer, forMode: .common)
    }

    private func post(_ type: CGEventType, at point: CGPoint) {
        lastPoint = point
        guard let event = CGEvent(mouseEventSource: CGEventSource(stateID: .privateState), mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { cancel(); return }
        event.setIntegerValueField(.mouseEventNumber, value: eventNumber)
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.setDoubleValueField(.mouseEventPressure, value: held ? 1 : 0)
        post(event)
    }
    private func post(_ event: CGEvent) {
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.post(tap: .cghidEventTap)
    }

    /// A physical mouse/key event must never finish our drag at a different target.
    /// Swallow the event that cancels our drag so a physical mouse-up cannot
    /// commit it at another location before AppKit processes Escape.
    private func installObserver() -> Bool {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                   .rightMouseDown, .otherMouseDown, .keyDown, .flagsChanged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let external = MainActor.assumeIsolated {
                    let owner = Unmanaged<DesktopNativeDrag>.fromOpaque(context).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput ||
                        event.getIntegerValueField(.eventSourceUserData) != owner.marker {
                        owner.diagnose("external-input-\(type.rawValue)")
                        owner.cancel()
                        return true
                    }
                    return false
                }
                return external ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return false }
        eventTap = tap; eventSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
    }

    private func finish(_ outcome: Outcome) {
        guard isActive else { return }
        let actual = cancelling ?? outcome
        isActive = false; activeID = nil
        timers.forEach { $0.invalidate() }; timers.removeAll()
        if let eventTap { CFMachPortInvalidate(eventTap) }
        if let eventSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventSource, .commonModes) }
        eventTap = nil; eventSource = nil
        if held { held = false; post(.leftMouseUp, at: lastPoint) }
        panel?.orderOut(nil); panel?.close(); panel = nil; view = nil
        allowed = nil; validateTarget = nil
        let continuation = continuation; self.continuation = nil
        Self.log.notice("native-drag outcome=\(String(describing: actual), privacy: .public)")
        continuation?.resume(returning: actual)
    }

    private final class SourceView: NSView, NSDraggingSource {
        let urls: [URL]
        let id: UUID
        weak var owner: DesktopNativeDrag?
        var down: NSEvent?
        var started = false
        init(urls: [URL], owner: DesktopNativeDrag, id: UUID) { self.urls = urls; self.owner = owner; self.id = id; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { down = event; owner?.diagnose("mouse-down") }
        override func mouseDragged(with event: NSEvent) {
            guard !started, down != nil, let owner, owner.activeID == id, owner.cancelling == nil else { return }
            started = true
            let anchor = convert(event.locationInWindow, from: nil)
            let items = urls.enumerated().map { index, url in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                item.setDraggingFrame(NSRect(x: anchor.x - 16 + CGFloat(index % 3 * 3), y: anchor.y - 16, width: 32, height: 32),
                                      contents: NSWorkspace.shared.icon(forFile: url.path))
                return item
            }
            let session = beginDraggingSession(with: items, event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = false
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            guard let owner, owner.activeID == id else { return }
            owner.sessionStarted = true
            // Configure here too: the callback can run before beginDraggingSession
            // returns. Cancellation must never fly back to the hidden proxy.
            session.animatesToStartingPositionsOnCancelOrFail = false
            owner.diagnose("session-started")
            owner.driveSession()
        }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            guard owner?.activeID == id else { return }
            owner?.sessionStarted = false
            owner?.finish(operation.contains(.copy) ? .accepted : .rejected)
        }
    }
}

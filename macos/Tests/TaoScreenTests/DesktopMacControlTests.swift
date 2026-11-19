import Testing
import AppKit
@testable import TaoScreen

struct DesktopMacControlTests {
    @Test @MainActor func receiverPreservesSystemFunctionAndArrowKeyFlags() {
        var events: [CGEvent] = []
        let receiver = DesktopInputReceiver(canPost: { true }, post: { events.append($0) })
        receiver.enabled = true
        for key: UInt16 in [126, 125, 99, 103] {
            events.removeAll()
            let systemEvent = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: key, keyDown: true)!
            receiver.receive(.init(kind: "key", down: true, key: key, flags: CGEventFlags.maskControl.rawValue))
            let actual = events.last!
            let intrinsic: CGEventFlags = [.maskSecondaryFn, .maskNumericPad]
            #expect(!systemEvent.flags.intersection(intrinsic).isEmpty)
            #expect(actual.flags.intersection(intrinsic) == systemEvent.flags.intersection(intrinsic))
            #expect(actual.flags.contains(.maskControl))
            receiver.receive(.init(kind: "key", down: false, key: key, flags: CGEventFlags.maskControl.rawValue))
        }
    }
    @Test func macActionsUseOrderedKeyPairsWithoutChangingClipboardOrPreferences() {
        #expect(DesktopMacControl.allWindows.shortcut.key == 126)
        #expect(DesktopMacControl.dock.shortcut.key == 99)
        for action in DesktopMacControl.allCases {
            let inputs = action.inputs
            #expect(inputs.allSatisfy(\.isValid) && inputs.first?.kind == "release")
            let main = inputs.filter { $0.key == action.shortcut.key }
            #expect(main.map(\.down) == [true, false])
            #expect(main.allSatisfy { $0.flags == action.shortcut.flags.rawValue })
            var held: Set<UInt16> = []
            for input in inputs.dropFirst() {
                if input.down == true { held.insert(input.key!) }
                else { #expect(held.remove(input.key!) != nil) }
            }
            #expect(held.isEmpty && inputs.last?.flags == 0)
        }
        #expect(DesktopMacControl.allWindows.inputs.compactMap(\.key) == [59, 126, 126, 59])
        #expect(DesktopMacControl.fullScreen.inputs.compactMap(\.key) == [59, 55, 3, 3, 55, 59])
    }
    @Test @MainActor func systemActionEventsIncludeModifierChangesAndReleaseThem() {
        var events: [CGEvent] = []
        let receiver = DesktopInputReceiver(canPost: { true }, post: { events.append($0) })
        receiver.enabled = true
        for input in DesktopMacControl.allWindows.inputs { receiver.receive(input) }
        #expect(events.map(\.type) == [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
        #expect(events[0].flags.contains(.maskControl))
        #expect(events[1].flags.contains([.maskControl, .maskSecondaryFn, .maskNumericPad]))
        #expect(!events[3].flags.contains(.maskControl))
    }
    @Test @MainActor func disconnectedAndHostSessionsCannotSendMacActions() {
        let center = DesktopCenter()
        #expect(!center.canPerformMacControl)
        center.performMacControl(.allWindows)
        #expect(!center.connected && center.message == nil)
    }
}

import AppKit
import SwiftUI
import Testing
@testable import TaoScreen

struct DesktopConnectionInfoTests {
    @Test func addressesUseOnlySelectedPairAndKeepEndpointRoles() {
        var statistics: [String: (type: String, values: [String: NSObject])] = [
            "transport": ("transport", ["selectedCandidatePairId": "active" as NSString]),
            "active": ("candidate-pair", ["localCandidateId": "local" as NSString, "remoteCandidateId": "remote" as NSString]),
            "local": ("local-candidate", ["address": "192.0.2.10" as NSString, "candidateType": "host" as NSString]),
            "remote": ("remote-candidate", ["address": "2001:db8::20" as NSString, "candidateType": "relay" as NSString]),
            "unused": ("remote-candidate", ["address": "203.0.113.99" as NSString, "candidateType": "host" as NSString])
        ]
        let result = DesktopConnectionAddresses.selected(statistics: statistics)
        #expect(result.local?.ip == "192.0.2.10" && result.local?.relayed == false)
        #expect(result.remote?.description == "2001:db8::20" + L10n.text("（中继）"))
        for missing in ["", "hidden.local", "192.0.2.999", "not-an-ip"] {
            statistics["remote"]?.values["address"] = missing as NSString
            #expect(DesktopConnectionAddresses.selected(statistics: statistics).remote == nil)
        }
        statistics["another-transport"] = ("transport", ["selectedCandidatePairId": "another-pair" as NSString])
        #expect(DesktopConnectionAddresses.selected(statistics: statistics) == .init())
        statistics.removeValue(forKey: "another-transport")
        statistics.removeValue(forKey: "transport")
        #expect(DesktopConnectionAddresses.selected(statistics: statistics) == .init())
    }

    @Test @MainActor func addressesStayWithTheirSessionAndClearOnDisconnect() throws {
        let center = DesktopCenter()
        defer { center.shutdown() }
        let first = center.prepareViewer(for: .init(id: UUID(), name: "Mac A"))
        let second = center.prepareViewer(for: .init(id: UUID(), name: "Mac B"))
        let firstID = try #require(first.sessionID), secondID = try #require(second.sessionID)
        first.receiveRTCState(.connected, id: firstID); second.receiveRTCState(.connected, id: secondID)
        let addresses = DesktopConnectionAddresses(local: .init(ip: "192.0.2.10", relayed: false), remote: .init(ip: "192.0.2.20", relayed: false))
        first.receiveConnectionAddresses(addresses, id: UUID())
        #expect(first.connectionAddresses == .init())
        first.receiveConnectionAddresses(addresses, id: firstID)
        #expect(first.connectionAddresses == addresses && second.connectionAddresses == .init())
        first.receiveRTCState(.disconnected, id: firstID)
        #expect(first.connectionAddresses == .init())
        first.receiveConnectionAddresses(addresses, id: firstID)
        #expect(first.connectionAddresses == .init())
        first.receiveRTCState(.connected, id: firstID)
        first.receiveConnectionAddresses(addresses, id: firstID)
        first.disconnect(notify: false)
        #expect(first.connectionAddresses == .init())
        #expect(second.sessionID == secondID)
    }

    @Test @MainActor func hoveringAcrossGapKeepsPanelOpenUntilPointerLeaves() async throws {
        let state = DesktopConnectionPopoverState()
        let first = UUID()
        state.hover(first, inside: true); state.hover(first, inside: false)
        try await Task.sleep(for: .milliseconds(50))
        state.hover(first, inside: true, region: .panel)
        try await Task.sleep(for: .milliseconds(550))
        #expect(state.id == first)
        state.show(first) // 点击也不再固定浮窗。
        state.hover(first, inside: false, region: .panel)
        try await waitForDismissal(state)
        #expect(state.id == nil)
    }

    @Test @MainActor func menuTrackingDelaysDismissalUntilMenuCloses() async throws {
        let state = DesktopConnectionPopoverState()
        let first = UUID(), menu = NSMenu(), submenu = NSMenu()
        state.hover(first, inside: true, region: .panel)
        state.menuTracking(menu, active: true)
        state.menuTracking(submenu, active: true)
        state.hover(first, inside: false, region: .panel)
        state.menuTracking(submenu, active: false)
        try await Task.sleep(for: .milliseconds(550))
        #expect(state.id == first)
        state.menuTracking(menu, active: false)
        try await waitForDismissal(state)
        #expect(state.id == nil)
    }

    @Test @MainActor func hoverRegionsAndSessionChangesCancelStaleDismissals() async throws {
        let state = DesktopConnectionPopoverState()
        let first = UUID(), second = UUID()
        state.hover(first, inside: true)
        state.hover(first, inside: true, region: .panel)
        state.hover(first, inside: false, region: .panel)
        try await Task.sleep(for: .milliseconds(550))
        #expect(state.id == first) // 浮窗的移出事件不能覆盖仍在图标内的状态。
        state.hover(first, inside: true); state.hover(first, inside: false)
        state.hover(second, inside: true)
        state.hover(first, inside: false)
        try await Task.sleep(for: .milliseconds(550))
        #expect(state.id == second)
        state.hover(second, inside: false)
        try await waitForDismissal(state)
        #expect(state.id == nil)
        state.show(second)
        try await waitForDismissal(state)
        #expect(state.id == nil) // 无悬停的按钮激活也会自动收起。
    }

    @MainActor private func waitForDismissal(_ state: DesktopConnectionPopoverState) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while state.id != nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    @Test @MainActor func realRTCReportsSelectedEndpointAddressesAndClearsThemOnClose() async throws {
        let configuration = DesktopConfiguration(iceServers: [], relayAvailable: false)
        let host = try DesktopRTC(configuration: configuration, host: true, purpose: .ports)
        let viewer = try DesktopRTC(configuration: configuration, host: false, purpose: .ports)
        defer { host.close(); viewer.close() }
        var hostAddresses = DesktopConnectionAddresses(), viewerAddresses = DesktopConnectionAddresses()
        host.onConnectionAddresses = { hostAddresses = $0 }
        viewer.onConnectionAddresses = { viewerAddresses = $0 }
        host.onSignal = { kind, value in if kind == "candidate" { viewer.addCandidate(value) } }
        viewer.onSignal = { kind, value in if kind == "candidate" { host.addCandidate(value) } }
        try await host.setRemote(viewer.makeDescription(offer: true), offer: true)
        try await viewer.setRemote(host.makeDescription(offer: false), offer: false)
        func endpointsMatch() -> Bool {
            guard let local = hostAddresses.local, let remote = hostAddresses.remote else { return false }
            return local.ip == viewerAddresses.remote?.ip && remote.ip == viewerAddresses.local?.ip
        }
        // 双方独立采样，首轮地址可能分别来自切换前后的 IPv4、IPv6 候选对。
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !endpointsMatch() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(hostAddresses.local != nil && hostAddresses.remote != nil)
        #expect(viewerAddresses.local != nil && viewerAddresses.remote != nil)
        #expect(hostAddresses.local?.ip == viewerAddresses.remote?.ip)
        #expect(viewerAddresses.local?.ip == hostAddresses.remote?.ip)
        host.close(); viewer.close()
        #expect(hostAddresses == .init() && viewerAddresses == .init())
    }

    @Test @MainActor func connectionPanelAndMoreMenuPreviews() throws {
        _ = NSApplication.shared
        let center = DesktopCenter()
        defer { center.shutdown() }
        let viewer = center.prepareViewer(for: .init(id: UUID(), name: "Mac Studio"))
        viewer.receiveRTCState(.connected, id: try #require(viewer.sessionID))
        viewer.receiveConnectionAddresses(.init(local: .init(ip: "192.0.2.10", relayed: false), remote: .init(ip: "2001:db8:1234:5678:abcd:ef01:2345:6789", relayed: false)), id: try #require(viewer.sessionID))
        viewer.receiveVideoSettings(.init(action: .status, preset: .ultra, width: 3840, height: 2160))
        if let directory = ProcessInfo.processInfo.environment["TAOSCREEN_CONNECTION_PANEL_PREVIEW"] {
            let output = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            func export<V: View>(_ content: V, size: CGSize, name: String) throws {
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .aqua)
                let view = NSHostingView(rootView: content)
                window.contentView = view
                defer { window.contentView = nil }
                view.frame = NSRect(origin: .zero, size: size)
                view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name))
            }
            try export(DesktopConnectionInfo(center: viewer, close: {}), size: CGSize(width: 320, height: 440), name: "connection-info.png")
            try export(DesktopConnectionInfo(center: viewer, maximumHeight: 340, close: {}), size: CGSize(width: 320, height: 340), name: "connection-info-compact.png")
            try export(DesktopViewerSettings(center: viewer).environment(\.colorScheme, .light).background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 380, height: 550), name: "connection-settings.png")
        }
    }
}

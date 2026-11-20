import AppKit
import Carbon.HIToolbox
import Combine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum DesktopPrivacyPreset: String, CaseIterable, Identifiable, Codable {
    case charcoal, midnight, forest
    var id: String { rawValue }
    var name: String {
        switch self { case .charcoal: L10n.text("深灰 · 隐私保护"); case .midnight: L10n.text("深蓝 · 远程办公"); case .forest: L10n.text("墨绿 · 请勿打扰") }
    }
    var title: String {
        switch self { case .charcoal: L10n.text("隐私屏已开启"); case .midnight: L10n.text("正在远程办公"); case .forest: L10n.text("专注时间，请勿打扰") }
    }
    var color: Color {
        switch self {
        case .charcoal: Color(red: 0.10, green: 0.11, blue: 0.13)
        case .midnight: Color(red: 0.06, green: 0.12, blue: 0.23)
        case .forest: Color(red: 0.07, green: 0.18, blue: 0.15)
        }
    }
}

struct DesktopPrivacyImage: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    var selectionID: String { id.uuidString }
    var filename: String { id.uuidString + ".png" }
}

struct DesktopPrivacySettings: Codable, Equatable {
    var automatic = false
    var selection = DesktopPrivacyPreset.charcoal.rawValue
    var images: [DesktopPrivacyImage] = []
}

/// 图片复制到本机素材库；不依赖原文件路径，不随账号同步。
@MainActor
final class DesktopPrivacyLibrary: ObservableObject {
    @Published private(set) var settings: DesktopPrivacySettings
    @Published private(set) var importing = false
    @Published var error: String?
    var onChange: (() -> Void)?
    let directory: URL
    private var thumbnails: [UUID: NSImage] = [:]
    private var settingsURL: URL { directory.appendingPathComponent("settings.json") }

    init(directory: URL = DesktopRuntime.supportDirectory.appendingPathComponent("DesktopPrivacy", isDirectory: true)) {
        self.directory = directory
        let url = directory.appendingPathComponent("settings.json")
        var loaded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(DesktopPrivacySettings.self, from: $0) } ?? .init()
        loaded.images = Array(loaded.images.prefix(20)).filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.filename).path) }
        if DesktopPrivacyPreset(rawValue: loaded.selection) == nil && !loaded.images.contains(where: { $0.selectionID == loaded.selection }) {
            loaded.selection = DesktopPrivacyPreset.charcoal.rawValue
        }
        settings = loaded
    }

    var preset: DesktopPrivacyPreset { DesktopPrivacyPreset(rawValue: settings.selection) ?? .charcoal }
    var selectedImage: DesktopPrivacyImage? { settings.images.first { $0.selectionID == settings.selection } }

    func image(_ item: DesktopPrivacyImage, thumbnail: Bool = false) -> NSImage? {
        if thumbnail, let cached = thumbnails[item.id] { return cached }
        guard let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(item.filename) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnail ? 400 : 3840
              ] as CFDictionary) else { return nil }
        let result = NSImage(cgImage: cg, size: .zero)
        if thumbnail { thumbnails[item.id] = result }
        return result
    }

    func select(_ id: String) {
        guard DesktopPrivacyPreset(rawValue: id) != nil || settings.images.contains(where: { $0.selectionID == id }) else { return }
        var next = settings; next.selection = id; save(next)
    }
    func setAutomatic(_ value: Bool) { var next = settings; next.automatic = value; save(next) }
    func remove(_ item: DesktopPrivacyImage) {
        var next = settings
        next.images.removeAll { $0.id == item.id }
        if next.selection == item.selectionID { next.selection = DesktopPrivacyPreset.charcoal.rawValue }
        guard save(next) else { return }
        thumbnails[item.id] = nil
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(item.filename))
    }

    @discardableResult
    private func save(_ next: DesktopPrivacySettings) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: settingsURL, options: .atomic)
            settings = next; error = nil; onChange?(); return true
        } catch { self.error = L10n.text("无法保存隐私屏设置：\(error.localizedDescription)"); return false }
    }

    func importImages(_ urls: [URL]) async {
        guard !importing else { return }
        guard settings.images.count + urls.count <= 20 else { error = L10n.text("最多保存 20 张自定义图片。"); return }
        importing = true; error = nil
        defer { importing = false }
        for url in urls {
            do {
                let data = try await Task.detached(priority: .userInitiated) { try DesktopPrivacyImageImport.normalizedPNG(url) }.value
                let item = DesktopPrivacyImage(id: UUID(), name: String(url.deletingPathExtension().lastPathComponent.prefix(80)))
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent(item.filename)
                try data.write(to: destination, options: .atomic)
                var next = settings; next.images.append(item); next.selection = item.selectionID
                if !save(next) { try? FileManager.default.removeItem(at: destination); return }
            } catch { self.error = L10n.text("无法导入「\(url.lastPathComponent)」：\(error.localizedDescription)"); return }
        }
    }
}

enum DesktopPrivacyImageImport {
    static func normalizedPNG(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 20 * 1024 * 1024 else {
            throw CloudError(L10n.text("请选择不超过 20 MB 的图片文件。"))
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 3840
              ] as CFDictionary) else { throw CloudError(L10n.text("图片格式无效或内容已损坏。")) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw CloudError(L10n.text("无法转换图片。")) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CloudError(L10n.text("无法保存图片。")) }
        return data as Data
    }
}

struct DesktopPrivacyMessage: Codable, Equatable {
    enum Action: String, Codable { case request, status }
    var kind = "desktop-privacy.v1"
    var action: Action
    var enabled: Bool
    var active = false
    var changing = false
    var failure: String?
    var isValid: Bool {
        kind == "desktop-privacy.v1" && (failure?.utf8.count ?? 0) <= 1024
            && (!active || enabled)
            && (action == .status || (!active && !changing && failure == nil))
    }
}

struct DesktopPrivacyArtwork: View {
    let preset: DesktopPrivacyPreset
    var image: NSImage?
    var compact = false
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                preset.color
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    Color.black.opacity(0.36)
                }
                VStack(spacing: compact ? 5 : 18) {
                    Image(systemName: "lock.display").font(.system(size: compact ? 18 : 48, weight: .light))
                    Text(image == nil ? preset.title : L10n.text("隐私屏已开启"))
                        .font(.system(size: compact ? 11 : 32, weight: .semibold))
                    if !compact {
                        Text(L10n.text("此电脑正在通过 TaoScreen 远程使用")).font(.title3).foregroundStyle(.white.opacity(0.8))
                        Text(L10n.text("本机键鼠仍可使用 · 按 ⌃⌥⇧Esc 退出隐私屏"))
                            .font(.callout).foregroundStyle(.white.opacity(0.65)).padding(.top, 12)
                    }
                }.foregroundStyle(.white).padding(compact ? 8 : 32)
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
    }
}

/// 本地遮罩不成为 key window，也不改变点击命中；采集必须显式排除这些窗口。
@MainActor
final class DesktopPrivacyCurtain {
    private(set) var windows: [NSWindow] = []
    var windowIDs: Set<CGWindowID> { Set(windows.map { CGWindowID($0.windowNumber) }) }
    var onEmergencyExit: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?

    private final class CurtainWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    func show(preset: DesktopPrivacyPreset, image: NSImage?, screens: [NSScreen] = NSScreen.screens,
              present: Bool = true) throws {
        guard !screens.isEmpty else { throw CloudError(L10n.text("没有可遮挡的显示器。")) }
        if hotKey == nil { try installEmergencyExit() }
        // 保留原窗口，避免更换样式时短暂露出桌面；只为新增屏幕创建窗口。
        while windows.count < screens.count {
            let window = CurtainWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = true; window.hidesOnDeactivate = false
            window.isOpaque = true; window.backgroundColor = .black; window.hasShadow = false
            window.animationBehavior = .none
            windows.append(window)
        }
        for (window, screen) in zip(windows, screens) {
            window.setFrame(screen.frame, display: false)
            window.contentView = NSHostingView(rootView: DesktopPrivacyArtwork(preset: preset, image: image))
            if present { window.orderFrontRegardless() }
        }
        while windows.count > screens.count { windows.removeLast().close() }
    }

    private func installEmergencyExit() throws {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x42525056, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<DesktopPrivacyCurtain>.fromOpaque(context).takeUnretainedValue().onEmergencyExit?()
            }
            return noErr
        }, 1, &type, context, &hotKeyHandler)
        let registered = installed == noErr ? RegisterEventHotKey(UInt32(kVK_Escape), UInt32(controlKey | optionKey | shiftKey),
            EventHotKeyID(signature: 0x42525056, id: 1), GetApplicationEventTarget(), 0, &hotKey) : installed
        guard registered == noErr else {
            stop(); throw CloudError(L10n.text("无法注册隐私屏退出快捷键 ⌃⌥⇧Esc，请检查快捷键冲突后重试。"))
        }
    }

    func stop() {
        windows.forEach { $0.close() }; windows.removeAll()
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }; hotKeyHandler = nil
    }
}

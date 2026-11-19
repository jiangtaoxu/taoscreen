import SwiftUI
import UniformTypeIdentifiers

struct DesktopPrivacySettingsSheet: View {
    @ObservedObject var center: DesktopCenter
    @ObservedObject var library: DesktopPrivacyLibrary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "lock.display").font(.title2).foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text("此电脑的隐私屏").font(.title2.weight(.semibold))
                    Text("遮住本机屏幕，远端仍可正常查看和操作桌面。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Divider()
            ScrollView {
                DesktopPrivacySettingsView(center: center, library: library).padding(24)
            }
            Divider()
            HStack {
                Text("设置即时保存，仅在此电脑生效").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }.frame(width: 640, height: 540)
            .onExitCommand { dismiss() }
    }
}

struct DesktopPrivacySettingsView: View {
    @ObservedObject var center: DesktopCenter
    @ObservedObject var library: DesktopPrivacyLibrary
    @State private var preview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(get: { library.settings.automatic }, set: { library.setAutomatic($0) })) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("连接时自动启用").font(.callout.weight(.medium))
                        Text("其他设备连接此电脑时，自动遮住所有本机屏幕。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.toggleStyle(.switch)
                if center.isHost {
                    Divider()
                    Toggle(isOn: Binding(get: { center.privacyRequested }, set: { center.setHostPrivacy($0) })) {
                        HStack(spacing: 8) {
                            Text("本次共享启用").font(.callout.weight(.medium))
                            if center.privacyChanging { ProgressView().controlSize(.mini) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.toggleStyle(.switch).disabled(!center.connected || center.privacyChanging)
                    Text(center.privacyStatusText).font(.caption)
                        .foregroundStyle(center.privacyActive ? Color.green : .secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(16).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Text("屏幕样式").font(.headline)
                Spacer()
                Button("预览") { preview = true }
                Button { chooseImages() } label: {
                    Label(library.importing ? "正在导入…" : "导入图片…", systemImage: "photo.badge.plus")
                }.disabled(library.importing)
            }.controlSize(.small)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 164), spacing: 12, alignment: .top)], alignment: .leading, spacing: 14) {
                ForEach(DesktopPrivacyPreset.allCases) { preset in
                    tile(id: preset.id, title: preset.name, preset: preset, image: nil)
                }
                ForEach(library.settings.images) { item in
                    tile(id: item.selectionID, title: item.name, preset: .charcoal, image: library.image(item, thumbnail: true))
                        .contextMenu { Button("删除图片", role: .destructive) { library.remove(item) } }
                }
            }.font(.callout)
            if let selected = library.selectedImage {
                HStack {
                    Text("图片铺满屏幕，超出部分裁切").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("删除所选图片", role: .destructive) { library.remove(selected) }.controlSize(.small)
                }
            }
            if let error = library.error { Text(error).font(.caption).foregroundStyle(.orange) }
            Label("本机键鼠仍可使用，按 ⌃⌥⇧Esc 可随时退出隐私屏。", systemImage: "keyboard")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $preview) {
            VStack(spacing: 0) {
                DesktopPrivacyArtwork(preset: library.preset, image: library.selectedImage.flatMap { library.image($0) })
                    .frame(width: 720, height: 405)
                HStack {
                    Text("样式预览 · 本机键鼠仍可使用").foregroundStyle(.secondary)
                    Spacer()
                    Button("完成") { preview = false }.keyboardShortcut(.defaultAction)
                }.padding(14)
            }.onExitCommand { preview = false }
        }
    }

    private func tile(id: String, title: String, preset: DesktopPrivacyPreset, image: NSImage?) -> some View {
        Button { library.select(id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                DesktopPrivacyArtwork(preset: preset, image: image, compact: true)
                    .aspectRatio(16.0 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(alignment: .topTrailing) {
                        if library.settings.selection == id {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Color.accentColor).padding(6)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(library.settings.selection == id ? Color.accentColor : .clear, lineWidth: 2))
                Text(title).font(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).help(title)
            .accessibilityLabel(title).accessibilityAddTraits(library.settings.selection == id ? .isSelected : [])
    }

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.title = "选择隐私屏图片"; panel.prompt = "导入"
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .webP]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.begin { result in
            guard result == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in await library.importImages(urls) }
        }
    }
}

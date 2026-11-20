import SwiftUI

struct DesktopShareDisplayPicker: View {
    @ObservedObject var center: DesktopCenter
    @Binding var selection: DesktopShareDisplay
    var allowsFixedDisplay = true
    @State private var screens = NSScreen.screens

    var body: some View {
        Picker(L10n.text("共享屏幕"), selection: $selection) {
            Text(allowsFixedDisplay ? L10n.text("主屏幕（连接时选择）") : L10n.text("主屏幕")).tag(DesktopShareDisplay.main)
            if allowsFixedDisplay {
                ForEach(screens, id: \.self) { screen in
                    if let id = screen.desktopDisplayID, id != center.managedVirtualDisplayID {
                        Text(screen.localizedName).tag(DesktopShareDisplay.fixed(id))
                    }
                }
                if case let .fixed(id) = selection,
                   id == center.managedVirtualDisplayID || !screens.contains(where: { $0.desktopDisplayID == id }) {
                    Text(L10n.text("已断开的屏幕（请重新选择）")).tag(DesktopShareDisplay.fixed(id))
                }
            }
            ForEach(DesktopVirtualDisplayPreset.allCases) { preset in
                Text(preset.title).tag(DesktopShareDisplay.virtual(preset))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
        if selection.virtualPreset != nil {
            Text(L10n.text("连接时创建扩展屏，断开后自动移除。"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

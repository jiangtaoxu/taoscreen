import Foundation

enum DesktopRuntime {
    static let defaults = UserDefaults.standard
    private static let bundleIdentifier: String = {
        if Bundle.main.bundleURL.pathExtension == "app", let identifier = Bundle.main.bundleIdentifier {
            return identifier
        }
        return "org.taoscreen.development"
    }()
    static let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(bundleIdentifier, isDirectory: true)
    static func keychainService(_ suffix: String) -> String { "\(bundleIdentifier).\(suffix)" }
}

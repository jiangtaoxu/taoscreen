import Foundation

enum DesktopLanguage: String, CaseIterable {
    case system
    case english = "en"
    case chinese = "zh-Hans"

    static let preferenceKey = "taoscreen.language"

    static var preference: Self {
        DesktopRuntime.defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .system
    }

    static func resolve(_ preference: Self, preferredLanguages: [String]) -> Self {
        guard preference == .system else { return preference }
        for identifier in preferredLanguages {
            switch Locale(identifier: identifier).language.languageCode?.identifier {
            case "zh": return .chinese
            case "en": return .english
            default: continue
            }
        }
        return .english
    }
}

enum L10n {
    static let language = DesktopLanguage.resolve(DesktopLanguage.preference, preferredLanguages: Locale.preferredLanguages)
    static let locale = Locale(identifier: language.rawValue)

    private static let translations: [String: String] = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "English", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let translations = try? JSONDecoder().decode([String: String].self, from: data)
        else { preconditionFailure("The TaoScreen English localization resource is invalid or missing.") }
        return translations
    }()

    static func text(_ template: Template) -> String {
        let pattern = language == .english ? value(template.key) : template.key
        guard !template.arguments.isEmpty else { return pattern }
        var result = pattern
        for match in placeholders.matches(in: pattern, range: NSRange(pattern.startIndex..., in: pattern)).reversed() {
            guard let token = Range(match.range, in: result),
                  let digits = Range(match.range(at: 1), in: result),
                  let position = Int(result[digits]), template.arguments.indices.contains(position - 1)
            else { continue }
            result.replaceSubrange(token, with: template.arguments[position - 1])
        }
        return result
    }

    /// Localizes string values kept in their original form in storage or at the API boundary.
    static func value(_ key: String) -> String {
        language == .english ? (translations[key] ?? key) : key
    }

    private static let placeholders = try! NSRegularExpression(pattern: #"\{([1-9][0-9]*)\}"#)

    struct Template: ExpressibleByStringInterpolation {
        let key: String
        let arguments: [String]

        init(stringLiteral value: String) {
            key = value
            arguments = []
        }

        init(stringInterpolation: StringInterpolation) {
            key = stringInterpolation.key
            arguments = stringInterpolation.arguments
        }

        struct StringInterpolation: StringInterpolationProtocol {
            fileprivate var key = ""
            fileprivate var arguments: [String] = []

            init(literalCapacity: Int, interpolationCount: Int) {
                key.reserveCapacity(literalCapacity)
                arguments.reserveCapacity(interpolationCount)
            }

            mutating func appendLiteral(_ literal: String) {
                key += literal
            }

            mutating func appendInterpolation<T>(_ value: T) {
                arguments.append(String(describing: value))
                key += "{\(arguments.count)}"
            }
        }
    }
}

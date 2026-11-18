import Foundation

/// Снимок проблем для виджетов на экране «Домой»: приложение пишет, расширение читает.
/// Общая папка (App Group) есть только в пробной сборке с виджетами; без неё запись безвредна.
struct WidgetProblem: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var host: String
    var severity: Int
    var clock: Date
    var acked: Bool
}

struct WidgetSnapshot: Codable {
    var count: Int
    var high: Int
    var unacked: Int
    var top: [WidgetProblem]
    var updated: Date
    var offline: Bool

    static let empty = WidgetSnapshot(count: 0, high: 0, unacked: 0, top: [], updated: .distantPast, offline: false)
}

enum SharedGroup {
    static let fallback = "group.com.personal.grafana"

    /// Имя группы берём из профиля подписи: Sideloadly может переименовать его под свою команду.
    static let id: String = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let d = try? Data(contentsOf: url), let s = String(data: d, encoding: .isoLatin1),
              let a = s.range(of: "<?xml"), let b = s.range(of: "</plist>") else { return fallback }
        let xml = String(s[a.lowerBound..<b.upperBound])
        guard let pl = try? PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any],
              let ent = pl["Entitlements"] as? [String: Any],
              let groups = ent["com.apple.security.application-groups"] as? [String],
              let g = groups.first(where: { !$0.contains("*") }) else { return fallback }
        return g
    }()

    static var defaults: UserDefaults? { UserDefaults(suiteName: id) }

    /// true, только если подпись действительно дала доступ к общей папке.
    static var available: Bool { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) != nil }

    static func save(_ s: WidgetSnapshot) {
        guard let d = try? JSONEncoder().encode(s) else { return }
        defaults?.set(d, forKey: "widgetSnapshot")
    }

    static func load() -> WidgetSnapshot? {
        guard let d = defaults?.data(forKey: "widgetSnapshot") else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: d)
    }
}

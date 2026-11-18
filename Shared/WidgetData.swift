import Foundation
import Security

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

/// Адрес и токен Zabbix для виджета через связку ключей. Профиль бесплатной подписи обычно
/// разрешает группу ключей «КОМАНДА.*», поэтому приложение и виджет могут делить один элемент.
enum SharedKeychain {
    static let profileEntitlements: [String: Any] = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let d = try? Data(contentsOf: url), let s = String(data: d, encoding: .isoLatin1),
              let a = s.range(of: "<?xml"), let b = s.range(of: "</plist>") else { return [:] }
        let xml = String(s[a.lowerBound..<b.upperBound])
        let pl = (try? PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil)) as? [String: Any]
        return pl?["Entitlements"] as? [String: Any] ?? [:]
    }()

    /// «TEAMID.com.personal.grafana.shared» — из профиля подписи; nil без профиля (симулятор).
    static let group: String? = {
        let groups = profileEntitlements["keychain-access-groups"] as? [String] ?? []
        guard let g = groups.first else { return nil }
        if g.hasSuffix(".*") { return String(g.dropLast(1)) + "com.personal.grafana.shared" }
        return g
    }()

    private static func base() -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "com.personal.grafana.widget",
                                kSecAttrAccount as String: "zabbix"]
        if let group { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    @discardableResult
    static func save(url: String, token: String) -> OSStatus {
        let q = base()
        SecItemDelete(q as CFDictionary)
        guard !url.isEmpty, !token.isEmpty else { return errSecSuccess }
        var add = q
        add[kSecValueData as String] = Data((url + "\n" + token).utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> (url: String, token: String)? {
        var q = base()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
              let s = String(data: d, encoding: .utf8) else { return nil }
        let parts = s.split(separator: "\n", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }
}

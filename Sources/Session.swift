import Foundation
import Security
import WebKit
import LocalAuthentication

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: Keychain (пароль хранится только здесь)

enum Keychain {
    private static let service = "com.personal.grafana"

    static func save(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: Ограничитель параллельных запросов (сервер не любит лавину)

actor Gate {
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let limit: Int
    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() }
    }
}

// MARK: Сессия Grafana

@MainActor
final class Session: ObservableObject {
    static let defaultServer = ""

    @Published var server: String
    @Published var user: String
    @Published var loggedIn = false
    @Published var restoring = true
    @Published var loginError: String?
    var demo = false
    var zbxGroups: [JSON]?

    let gate = Gate(limit: 3)
    private let urlSession: URLSession
    private var datasources: [JSON]?

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.timeoutIntervalForRequest = 45
        urlSession = URLSession(configuration: cfg)
        server = UserDefaults.standard.string(forKey: "server") ?? Session.defaultServer
        user = UserDefaults.standard.string(forKey: "user") ?? ""
        if Launch.demo {
            demo = true; loggedIn = true; restoring = false; user = "demo"
        } else {
            Task { await restore() }
        }
    }

    var baseURL: String {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private var savedPassword: String? { Keychain.load(account: "password") }

    func restore() async {
        defer { restoring = false }
        guard !user.isEmpty, let pw = savedPassword else { return }
        do { try await login(user: user, password: pw) }
        catch { loginError = error.localizedDescription }
    }

    func login(user: String, password: String) async throws {
        guard let url = URL(string: baseURL + "/login") else { throw APIError(message: "Неверный адрес сервера") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["user": user, "password": password])
        let t0 = Date()
        let data: Data, resp: URLResponse
        do { (data, resp) = try await urlSession.data(for: req) }
        catch { AppHealth.shared.fail(error.localizedDescription); throw error }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = (try? JSONDecoder().decode(JSON.self, from: data))?["message"].string
            throw APIError(message: msg ?? "Не удалось войти (HTTP \(code))")
        }
        UserDefaults.standard.set(server, forKey: "server")
        UserDefaults.standard.set(user, forKey: "user")
        Keychain.save(password, account: "password")
        self.user = user
        datasources = nil
        await syncCookiesToWebView()
        loginError = nil
        loggedIn = true
    }

    func logout() {
        Keychain.delete(account: "password")
        if let url = URL(string: baseURL), let cookies = HTTPCookieStorage.shared.cookies(for: url) {
            for c in cookies { HTTPCookieStorage.shared.deleteCookie(c) }
        }
        WKWebsiteDataStore.default().fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { recs in
            WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: recs) {}
        }
        loggedIn = false
    }

    /// Веб-вид панелей использует ту же сессию, что и нативный API.
    func syncCookiesToWebView() async {
        guard let url = URL(string: baseURL),
              let cookies = HTTPCookieStorage.shared.cookies(for: url) else { return }
        let store = WKWebsiteDataStore.default().httpCookieStore
        for c in cookies { await store.setCookie(c) }
    }

    // MARK: запросы

    func request(_ path: String, method: String = "GET", body: JSON? = nil, retry: Bool = true) async throws -> JSON {
        if demo { return Demo.respond(path: path, method: method, body: body) }
        guard let url = URL(string: baseURL + path) else { throw APIError(message: "Неверный адрес") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let t0 = Date()
        let cacheKey = OfflineCache.isRead(path: path, method: method, body: body) ? OfflineCache.key(path: path, method: method, body: body) : nil
        let data: Data, resp: URLResponse
        do { (data, resp) = try await urlSession.data(for: req) }
        catch {
            AppHealth.shared.fail(error.localizedDescription)
            if error is URLError, let k = cacheKey, let c = OfflineCache.load(k) {
                OfflineState.shared.served(c.at)
                return c.json
            }
            throw error
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, retry, let pw = savedPassword {
            try await login(user: user, password: pw)
            return try await request(path, method: method, body: body, retry: false)
        }
        let json = (try? JSONDecoder().decode(JSON.self, from: data)) ?? .null
        guard (200..<300).contains(code) else {
            let msg = json["message"].string ?? json["error"].string
                ?? json["results"].object.values.compactMap { $0["error"].string }.first
            AppHealth.shared.fail(msg ?? "HTTP \(code)")
            throw APIError(message: msg ?? "Ошибка сервера (HTTP \(code))")
        }
        AppHealth.shared.ok(ms: Int(Date().timeIntervalSince(t0) * 1000))
        OfflineState.shared.online()
        if let k = cacheKey, !json.isNull, json["error"].isNull { OfflineCache.save(k, data) }
        return json
    }

    func allDatasources() async -> [JSON] {
        if let d = datasources { return d }
        let list = (try? await request("/api/datasources"))?.array ?? []
        datasources = list
        return list
    }

    func webURL(_ pathAndQuery: String) -> URL? { URL(string: baseURL + pathAndQuery) }
}

// MARK: Блокировка Face ID

@MainActor
final class AppLock: ObservableObject {
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "faceid") }
    }
    @Published var locked: Bool
    @Published var timeout: Int = UserDefaults.standard.integer(forKey: "lockTimeout") {
        didSet { UserDefaults.standard.set(timeout, forKey: "lockTimeout") }
    }
    private var backgroundAt: Date?

    init() {
        let e = UserDefaults.standard.bool(forKey: "faceid")
        enabled = e
        locked = e
    }

    func lockIfNeeded() {
        guard enabled else { return }
        backgroundAt = Date()
        if timeout == 0 { locked = true }
    }

    /// При возврате из фона: заблокировать, если прошло больше заданного времени.
    func checkTimeout() {
        guard enabled, let t = backgroundAt else { return }
        if Date().timeIntervalSince(t) >= Double(timeout * 60) { locked = true }
        backgroundAt = nil
    }

    func unlock() async {
        guard locked else { return }
        let ctx = LAContext()
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Вход в Grafana")
            if ok { locked = false }
        } catch {}
    }
}

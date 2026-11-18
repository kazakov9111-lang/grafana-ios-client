import SwiftUI
import AppIntents
import CoreSpotlight
import UniformTypeIdentifiers
import WidgetKit
import CryptoKit
import Security
import Charts

// v3.2: проверка подключения, офлайн-кэш всех экранов, Siri (открыть экран, подтвердить, хост),
// проблемы в Spotlight, данные для виджетов, адаптивные фоны, стойки из инвентаря.

// MARK: Адаптивные цвета (тёмная и светлая тема)

extension Color {
    static let appBG = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.07, alpha: 1) : .systemGroupedBackground })
    static let appChip = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.15, alpha: 1) : .tertiarySystemFill })
}

// MARK: Офлайн-кэш ответов (только чтение)

enum OfflineCache {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("offline", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Кэшируем только чтение: GET, ds/query и методы Zabbix *.get.
    static func isRead(path: String, method: String, body: JSON?) -> Bool {
        if method == "GET" { return true }
        if path.hasPrefix("/api/ds/query") { return true }
        if path.hasSuffix("/resources/zabbix-api"), let m = body?["method"].string { return m.hasSuffix(".get") || m == "apiinfo.version" }
        return false
    }

    /// Ключ без «текущего времени»: from/to заменяются длиной периода, иначе кэш никогда не совпадёт.
    static func key(path: String, method: String, body: JSON?) -> String {
        var s = method + " " + path
        if let b = body {
            let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
            if let d = try? enc.encode(norm(b)) { s += String(decoding: d, as: UTF8.self) }
        }
        return SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func norm(_ j: JSON) -> JSON {
        switch j {
        case .object(var o):
            let now = Date().timeIntervalSince1970
            for (a, b) in [("from", "to"), ("time_from", "time_till")] {
                guard let f = o[a]?.double else { continue }
                let fs = f > 1e11 ? f / 1000 : f
                let t = o[b]?.double.map { $0 > 1e11 ? $0 / 1000 : $0 } ?? now
                o[a] = .string("span\(Int(((t - fs) / 60).rounded()))")
                o[b] = nil
            }
            o["requestId"] = nil
            return .object(o.mapValues(norm))
        case .array(let a): return .array(a.map(norm))
        default: return j
        }
    }

    static func save(_ key: String, _ data: Data) {
        let url = dir.appendingPathComponent(key)
        Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }
    }

    static func load(_ key: String) -> (json: JSON, at: Date)? {
        let url = dir.appendingPathComponent(key)
        guard let d = try? Data(contentsOf: url), let j = try? JSONDecoder().decode(JSON.self, from: d) else { return nil }
        let at = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
        return (j, at)
    }

    /// Не больше 500 файлов: старые удаляем при запуске.
    static func prune() {
        Task.detached(priority: .background) {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            guard files.count > 500 else { return }
            let sorted = files.sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a < b
            }
            for f in sorted.prefix(files.count - 400) { try? fm.removeItem(at: f) }
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static var sizeText: String {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return "\(files.count) ответов, " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

@MainActor
final class OfflineState: ObservableObject {
    static let shared = OfflineState()
    /// Самые старые данные, показанные из кэша; nil — связь есть.
    @Published var since: Date?

    func served(_ at: Date) {
        if since == nil || at < since! { since = at }
    }
    func online() { if since != nil { since = nil } }
}

struct OfflineBanner: View {
    @ObservedObject private var st = OfflineState.shared
    var body: some View {
        if let s = st.since {
            Label("Нет связи · данные на " + s.formatted(date: Calendar.current.isDateInToday(s) ? .omitted : .abbreviated, time: .shortened),
                  systemImage: "wifi.slash")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Color.orange.opacity(0.9)))
                .foregroundStyle(.black)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }
}

// MARK: Снимок для виджетов и Spotlight

/// Данные для виджетов при запуске и каждом возврате в приложение (не только на вкладке «Проблемы»).
@MainActor func refreshWidgets() async {
    WidgetKeys.sync()
    guard let s = Badge.session else { return }
    var n = 0
    while s.restoring && n < 150 { try? await Task.sleep(nanoseconds: 100_000_000); n += 1 }
    guard s.loggedIn, let ps = try? await s.loadProblems() else { return }
    AppSnapshot.publish(ps)
}

enum AppSnapshot {
    @MainActor static func publish(_ all: [Problem]) {
        let ps = ProblemFilters.visible(all)
        let sorted = ps.sorted { ($0.severity, $0.clock) > ($1.severity, $1.clock) }
        let snap = WidgetSnapshot(count: ps.count, high: ps.filter { $0.severity >= 4 }.count, unacked: ps.filter { !$0.acked }.count,
                                  top: sorted.prefix(8).map { WidgetProblem(id: $0.id, name: $0.name, host: $0.host, severity: $0.severity, clock: $0.clock, acked: $0.acked) },
                                  updated: Date(), offline: OfflineState.shared.since != nil)
        SharedGroup.save(snap)
        WidgetCenter.shared.reloadAllTimelines()
        indexProblems(sorted)
    }

    /// Активные проблемы в поиске iPhone: «ping», имя хоста, текст триггера.
    static func indexProblems(_ ps: [Problem]) {
        let items = ps.prefix(100).map { p -> CSSearchableItem in
            let a = CSSearchableItemAttributeSet(contentType: UTType.text)
            a.title = p.name
            a.contentDescription = (p.host.isEmpty ? "" : p.host + " · ") + sevName(p.severity) + (p.acked ? " · подтверждена" : "")
            a.keywords = ["проблема", "zabbix", p.host]
            let it = CSSearchableItem(uniqueIdentifier: "problem|\(p.id)|\(p.name)", domainIdentifier: "problems", attributeSet: a)
            it.expirationDate = Date().addingTimeInterval(86400)
            return it
        }
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: ["problems"]) { _ in
            if !items.isEmpty { CSSearchableIndex.default().indexSearchableItems(Array(items)) { _ in } }
        }
    }
}

// MARK: Проверка подключения

struct ConnCheck: Identifiable {
    let id: String
    let title: String
    let icon: String
    let hint: String
    var state = 0          // 0 ждёт, 1 идёт, 2 ок, 3 пусто/частично, 4 ошибка
    var detail = ""
    var ms: Int?
}

struct ConnectionCheckView: View {
    @EnvironmentObject var session: Session
    @State private var items: [ConnCheck] = []
    @State private var running = false

    var body: some View {
        List {
            Section {
                let done = items.filter { $0.state >= 2 }
                let ok = items.filter { $0.state == 2 || $0.state == 3 }.count
                HStack {
                    if running { ProgressView().padding(.trailing, 4) }
                    Text(running ? "Проверяю \(done.count + 1) из \(items.count)…" : "Работает \(ok) из \(items.count)")
                        .font(.headline)
                    Spacer()
                }
                Text("Только чтение: приложение ничего не меняет в Zabbix и Grafana. Права на запись проверяются по списку групп, где у учётки есть право записи.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(items) { c in
                    HStack(alignment: .top, spacing: 10) {
                        stateIcon(c.state).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Label(c.title, systemImage: c.icon).font(.subheadline.weight(.semibold))
                                Spacer()
                                if let ms = c.ms { Text("\(ms) мс").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                            }
                            if !c.detail.isEmpty { Text(c.detail).font(.caption).foregroundStyle(c.state == 4 ? Color.red : Color.secondary) }
                            if c.state == 4 || c.state == 3 { Text(c.hint).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            Section {
                Button { Task { await run() } } label: { Label("Проверить снова", systemImage: "arrow.clockwise") }.disabled(running)
                ShareLink(item: report) { Label("Поделиться результатом", systemImage: "square.and.arrow.up") }.disabled(running)
            } footer: {
                Text("В отчёте нет адреса сервера и логина — только названия проверок и ответы.")
            }
        }
        .navigationTitle("Проверка подключения")
        .task { if items.isEmpty { await run() } }
    }

    private func stateIcon(_ s: Int) -> some View {
        Group {
            switch s {
            case 1: ProgressView().controlSize(.small)
            case 2: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case 3: Image(systemName: "minus.circle.fill").foregroundStyle(.orange)
            case 4: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            default: Image(systemName: "circle").foregroundStyle(.secondary)
            }
        }
    }

    private var report: String {
        "Проверка подключения Grafana (iOS), \(Date().formatted(date: .abbreviated, time: .shortened))\n" +
        items.map { c in
            let mark = ["…", "…", "OK", "пусто", "ОШИБКА"][min(c.state, 4)]
            return "[\(mark)] \(c.title)" + (c.detail.isEmpty ? "" : ": \(BugReport.redact(c.detail, server: session.baseURL, user: session.user))") + (c.ms.map { " (\($0) мс)" } ?? "")
        }.joined(separator: "\n")
    }

    /// Вызов Zabbix строго через Grafana (а не по токену), чтобы проверить именно этот путь.
    private func viaGrafana(_ method: String, _ params: [String: JSON]) async throws -> JSON {
        guard let ds = await session.zabbixDS() else { throw APIError(message: "Источник данных Zabbix не найден") }
        let body: JSON = .object(["datasourceId": .number(Double(ds.id)), "method": .string(method), "params": .object(params)])
        let r = try await session.request("/api/datasources/uid/\(ds.uid)/resources/zabbix-api", method: "POST", body: body)
        if !r["error"].isNull {
            let e = r["error"]
            throw APIError(message: [e["message"].string, e["data"].string].compactMap { $0 }.joined(separator: ": "))
        }
        return r["result"]
    }

    private static let one: [String: JSON] = ["limit": .number(1)]

    private func listCheck(_ method: String, _ extra: [String: JSON] = [:], what: String) -> () async throws -> (Int, String) {
        {
            var p = Self.one
            for (k, v) in extra { p[k] = v }
            let r = try await viaGrafana(method, p)
            return r.array.isEmpty ? (3, "Доступ есть, но \(what) не найдено") : (2, "Доступ есть, \(what) есть")
        }
    }

    private var plan: [(ConnCheck, () async throws -> (Int, String))] {
        var list: [(ConnCheck, () async throws -> (Int, String))] = [
            (ConnCheck(id: "health", title: "Сервер Grafana", icon: "server.rack", hint: "Проверьте адрес сервера и интернет."), {
                let r = try await session.request("/api/health")
                return (2, "Отвечает" + (r["version"].string.map { ", версия \($0)" } ?? ""))
            }),
            (ConnCheck(id: "user", title: "Вход в Grafana", icon: "person.badge.key", hint: "Выйдите и войдите заново в Настройках."), {
                let r = try await session.request("/api/user")
                let admin = r["isGrafanaAdmin"].bool == true
                return (2, "Сессия действует" + (admin ? ", администратор" : ""))
            }),
            (ConnCheck(id: "ds", title: "Источник данных Zabbix", icon: "cylinder.split.1x2", hint: "В Grafana должен быть источник данных типа Zabbix, доступный этой учётке."), {
                guard await session.zabbixDS() != nil else { throw APIError(message: "Не найден") }
                return (2, "Найден")
            }),
            (ConnCheck(id: "ver", title: "Zabbix API", icon: "bolt.horizontal", hint: "Плагин Zabbix в Grafana не достучался до сервера Zabbix."), {
                let r = try await viaGrafana("apiinfo.version", [:])
                return (2, "Отвечает" + (r.string.map { ", версия \($0)" } ?? ""))
            }),
            (ConnCheck(id: "problems", title: "Проблемы", icon: "exclamationmark.triangle", hint: "Учётке нужны права чтения на группы хостов."), {
                let r = try await viaGrafana("problem.get", ["output": .array([.string("eventid")]), "recent": .bool(false)])
                return (2, "Видно активных проблем: \(r.array.count)")
            }),
            (ConnCheck(id: "hosts", title: "Хосты", icon: "desktopcomputer", hint: "Учётке нужны права чтения на группы хостов."), {
                let r = try await viaGrafana("host.get", ["output": .array([.string("hostid")]), "monitored_hosts": .bool(true)])
                return r.array.isEmpty ? (3, "Ни одного хоста не видно") : (2, "Видно хостов: \(r.array.count)")
            }),
            (ConnCheck(id: "alerts", title: "Журнал уведомлений", icon: "paperplane", hint: "Нужен для «Хронологии» в карточке проблемы: кому ушло уведомление и дошло ли."),
             listCheck("alert.get", ["output": .array([.string("alertid")])], what: "записей")),
            (ConnCheck(id: "sla", title: "SLA", icon: "chart.bar.doc.horizontal", hint: "Экран «SLA и веб-проверки». SLA настраиваются в Zabbix: Службы → SLA."),
             listCheck("sla.get", ["output": .array([.string("slaid")])], what: "SLA")),
            (ConnCheck(id: "web", title: "Веб-проверки", icon: "globe", hint: "Веб-сценарии Zabbix для экрана «SLA и веб-проверки»."),
             listCheck("httptest.get", ["output": .array([.string("httptestid")])], what: "сценариев")),
            (ConnCheck(id: "dash", title: "Дашборды Zabbix", icon: "rectangle.3.group", hint: "Раздел «Дашборды Zabbix»."),
             listCheck("dashboard.get", ["output": .array([.string("dashboardid")])], what: "дашбордов")),
            (ConnCheck(id: "maps", title: "Карты Zabbix", icon: "map", hint: "Раздел «Карты Zabbix»."),
             listCheck("map.get", ["output": .array([.string("sysmapid")])], what: "карт")),
            (ConnCheck(id: "maint", title: "Плановые работы", icon: "wrench.and.screwdriver", hint: "Список плановых работ. Создание требует типа пользователя Admin."),
             listCheck("maintenance.get", ["output": .array([.string("maintenanceid")])], what: "плановых работ")),
            (ConnCheck(id: "inv", title: "Инвентарь", icon: "shippingbox", hint: "Включите инвентарь в настройках хостов Zabbix."),
             listCheck("host.get", ["output": .array([.string("hostid")]), "withInventory": .bool(true)], what: "хостов с инвентарём")),
            (ConnCheck(id: "write", title: "Подтверждение через Grafana", icon: "checkmark.bubble", hint: "Если групп с записью нет, задайте токен Zabbix в Настройках → «Подтверждение проблем»."), {
                let r = try await viaGrafana("hostgroup.get", ["output": .array([.string("groupid")]), "editable": .bool(true)])
                return r.array.isEmpty ? (3, "Только чтение: подтверждать через Grafana нельзя") : (2, "Запись разрешена в \(r.array.count) группах")
            }),
            (ConnCheck(id: "galerts", title: "Алерты Grafana", icon: "bell.badge", hint: "Раздел «Алерты Grafana». Нужна роль с доступом к правилам оповещений."), {
                let r = try await session.request("/api/prometheus/grafana/api/v1/rules")
                let n = r["data"]["groups"].array.reduce(0) { $0 + $1["rules"].array.count }
                return n == 0 ? (3, "Доступ есть, правил нет") : (2, "Правил: \(n)")
            })
        ]
        list.append((ConnCheck(id: "wkeys", title: "Токен для виджета", icon: "key.horizontal",
                               hint: "Виджет берёт адрес и токен Zabbix из связки ключей. Задайте их в Настройках → «Подтверждение проблем»."), {
            let r = WidgetKeys.sync()
            switch r {
            case errSecSuccess: return WidgetKeys.hasValues ? (2, "Передан виджету (группа ключей \(SharedKeychain.group ?? "по умолчанию"))") : (3, "Адрес или токен Zabbix не заданы")
            case -34018: return (3, "Подпись не дала общую связку ключей — виджет не увидит токен")
            default: return (3, "Ошибка связки ключей \(r)")
            }
        }))
        if ZabbixDirect.config != nil {
            list.append((ConnCheck(id: "token", title: "Токен Zabbix (напрямую)", icon: "key", hint: "Проверьте адрес Zabbix и срок действия токена в Настройках."), {
                let r = try await session.zabbixAny("hostgroup.get", .object(["output": .array([.string("groupid")]), "editable": .bool(true)]))
                return r.array.isEmpty ? (3, "Токен работает, но прав записи нет — подтверждать нельзя") : (2, "Токен работает, запись в \(r.array.count) группах")
            }))
        }
        return list
    }

    private func run() async {
        running = true
        let p = plan
        items = p.map(\.0)
        for (i, step) in p.enumerated() {
            items[i].state = 1
            let t0 = Date()
            do {
                let (st, text) = try await step.1()
                items[i].state = st; items[i].detail = text
            } catch {
                items[i].state = 4
                items[i].detail = humanZabbixError(error.localizedDescription)
            }
            items[i].ms = Int(Date().timeIntervalSince(t0) * 1000)
        }
        running = false
    }

    private func humanZabbixError(_ m: String) -> String {
        let l = m.lowercased()
        if l.contains("no permissions") || l.contains("permission") { return "Нет прав: " + m }
        if l.contains("offline") || l.contains("not connected") || l.contains("timed out") { return "Нет связи: " + m }
        return m
    }
}

// MARK: Siri и кнопка «Действие»

enum AppScreen: String, AppEnum {
    case overview, problems, systems, panels, settings

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Экран"
    static var caseDisplayRepresentations: [AppScreen: DisplayRepresentation] = [
        .overview: "Обзор", .problems: "Проблемы", .systems: "Системы", .panels: "Панели", .settings: "Настройки"
    ]
    var tab: Int { [.overview: 0, .problems: 1, .systems: 2, .panels: 4, .settings: 3][self] ?? 0 }
}

struct OpenScreenIntent: AppIntent {
    static var title: LocalizedStringResource = "Открыть экран"
    static var description = IntentDescription("Открывает нужную вкладку приложения. Удобно повесить на кнопку «Действие».")
    static var openAppWhenRun = true

    @Parameter(title: "Экран", default: .problems) var screen: AppScreen

    @MainActor func perform() async throws -> some IntentResult {
        DeepLink.shared.tab = screen.tab
        return .result()
    }
}

struct AckLatestIntent: AppIntent {
    static var title: LocalizedStringResource = "Подтвердить последнюю проблему"
    static var description = IntentDescription("Подтверждает самую свежую неподтверждённую проблему (сначала высокие). Спрашивает перед записью в Zabbix.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let s = await readySession() else {
            return .result(dialog: IntentDialog(stringLiteral: "Приложение Grafana не подключено. Откройте его и войдите."))
        }
        let ps = ProblemFilters.visible(try await s.loadProblems()).filter { !$0.acked }
        guard let p = ps.filter({ $0.severity >= 4 }).max(by: { $0.clock < $1.clock }) ?? ps.max(by: { $0.clock < $1.clock }) else {
            return .result(dialog: IntentDialog(stringLiteral: "Неподтверждённых проблем нет."))
        }
        let what = p.name + (p.host.isEmpty ? "" : " на \(p.host)")
        try await requestConfirmation(result: .result(dialog: IntentDialog(stringLiteral: "Подтвердить «\(what)»?")))
        try await s.acknowledge(eventId: p.id, message: "Подтверждено через Siri")
        return .result(dialog: IntentDialog(stringLiteral: "Подтверждено: \(what)."))
    }
}

struct HostStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Состояние хоста"
    static var description = IntentDescription("Говорит, есть ли проблемы у хоста (по части имени).")

    @Parameter(title: "Хост", requestValueDialog: IntentDialog("Какой хост?")) var host: String

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let s = await readySession() else {
            return .result(dialog: IntentDialog(stringLiteral: "Приложение Grafana не подключено. Откройте его и войдите."))
        }
        let q = host.trimmingCharacters(in: .whitespaces)
        let ps = try await s.loadProblems().filter { $0.host.localizedCaseInsensitiveContains(q) }
        if ps.isEmpty { return .result(dialog: IntentDialog(stringLiteral: "У «\(q)» активных проблем нет.")) }
        let hosts = Set(ps.map(\.host))
        let worst = ps.max { $0.severity < $1.severity }!
        var t = "Проблем: \(ps.count)"
        if hosts.count > 1 { t += " на \(hosts.count) хостах" }
        t += ". Самая серьёзная: \(worst.name)" + (hosts.count > 1 ? " на \(worst.host)." : ".")
        let un = ps.filter { !$0.acked }.count
        if un > 0 { t += " Не подтверждено: \(un)." }
        return .result(dialog: IntentDialog(stringLiteral: t))
    }
}

// MARK: Стойки из инвентаря

enum RackImport {
    /// Хосты с полем «стойка» в инвентаре Zabbix → раздел «Стойки». Юниты неизвестны — раскладываем сверху вниз.
    static func run(_ hosts: [InvHost]) -> (racks: Int, added: Int) {
        let byRack = Dictionary(grouping: hosts.filter { !$0.rack.isEmpty }, by: \.rack)
        var racks = RackStore.shared.racks
        var added = 0
        for (name, hs) in byRack.sorted(by: { $0.key < $1.key }) {
            var r = racks.first { $0.name == name } ?? Rack(name: name)
            let have = Set(r.slots.map(\.host))
            var top = (r.slots.map(\.u).min() ?? (r.units + 1)) - 1
            for h in hs.sorted(by: { $0.name < $1.name }) where !have.contains(h.name) {
                if top < 1 { r.units += 1; top = 1 }
                r.slots.append(RackSlot(host: h.name, u: top, size: 1))
                top -= 1; added += 1
            }
            if let i = racks.firstIndex(where: { $0.id == r.id }) { racks[i] = r } else { racks.append(r) }
        }
        RackStore.shared.racks = racks
        return (byRack.count, added)
    }
}

// MARK: Настройка виджета (адрес и токен вводятся в самом виджете)

struct WidgetSetupSection: View {
    @State private var copied: String?
    private func copy(_ text: String, _ what: String) {
        UIPasteboard.general.setItems([["public.utf8-plain-text": text]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
        copied = what + " скопирован на 2 минуты"
    }
    var body: some View {
        let url = UserDefaults.standard.string(forKey: "zbxURL") ?? ""
        let token = Keychain.load(account: "zbxToken") ?? ""
        Section {
            Button { copy(url, "Адрес") } label: { Label("Скопировать адрес Zabbix", systemImage: "link") }.disabled(url.isEmpty)
            Button { copy(token, "Токен") } label: { Label("Скопировать токен Zabbix", systemImage: "key") }.disabled(token.isEmpty)
            if let copied { Text(copied).font(.caption).foregroundStyle(.green) }
        } header: { Text("Виджет на экран «Домой»") } footer: {
            Text("Виджет сам спрашивает Zabbix раз в 15–30 минут, адрес и токен берёт из «Подтверждения проблем» автоматически. Если iOS показывает у виджета «Изменить виджет», их можно вписать и там (кнопки выше). Исключённые группы и фильтры приложения на виджет не действуют.")
        }
    }
}

enum WidgetKeys {
    static var hasValues: Bool {
        !(UserDefaults.standard.string(forKey: "zbxURL") ?? "").isEmpty && !(Keychain.load(account: "zbxToken") ?? "").isEmpty
    }
    /// Копия адреса и токена Zabbix для виджета; при изменении — перерисовать виджеты.
    @discardableResult static func sync() -> OSStatus {
        let url = UserDefaults.standard.string(forKey: "zbxURL")?.trimmingCharacters(in: .whitespaces) ?? ""
        let token = Keychain.load(account: "zbxToken") ?? ""
        let before = SharedKeychain.load()
        let r = SharedKeychain.save(url: url, token: token)
        if before?.url != url || before?.token != token { WidgetCenter.shared.reloadAllTimelines() }
        return r
    }
}

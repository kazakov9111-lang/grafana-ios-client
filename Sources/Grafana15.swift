import SwiftUI
import Charts
import MapKit
import UserNotifications
#if canImport(FoundationModels)
import FoundationModels
#endif

// v3.1: сторож мониторинга, отчёт об ошибке встряхиванием, SLA сервисов и веб-проверки,
// инвентарь хостов, статус для сотрудников, «вы дежурите», NOC-сетка, тема и размер текста,
// избранные метрики.

// MARK: Сторож: «мониторинг ослеп»

enum Watchdog {
    static var minutes: Int { UserDefaults.standard.integer(forKey: "watchdogMin") }

    /// Свежесть данных: самое новое значение среди agent.ping / icmpping.
    static func check(_ s: Session) async {
        guard minutes > 0 else { return }
        guard let r = try? await s.zabbixResult("item.get", [
            "output": .array([.string("lastclock")]),
            "filter": .object(["key_": .array([.string("agent.ping"), .string("icmpping"), .string("zabbix[uptime]")])]),
            "monitored": .bool(true), "limit": .number(500)
        ]) else { return }
        let last = r.array.compactMap { $0["lastclock"].double }.max() ?? 0
        guard last > 0 else { return }
        let age = Date().timeIntervalSince1970 - last
        let d = UserDefaults.standard
        d.set(last, forKey: "watchdogLast")
        let fired = d.bool(forKey: "watchdogFired")
        if age > Double(minutes * 60) {
            if !fired {
                d.set(true, forKey: "watchdogFired")
                notify("Мониторинг ослеп", "Zabbix не получал свежих данных \(duration(seconds: age)). Проверьте сервер Zabbix, базу и прокси.")
            }
        } else if fired {
            d.set(false, forKey: "watchdogFired")
            notify("Мониторинг снова видит", "Данные в Zabbix опять поступают.")
        }
    }

    private static func notify(_ t: String, _ b: String) {
        let c = UNMutableNotificationContent()
        c.title = t; c.body = b; c.sound = .default
        c.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "watchdog\(Date().timeIntervalSince1970)", content: c, trigger: nil))
    }
}

struct WatchdogBanner: View {
    @AppStorage("watchdogFired") private var fired = false
    @AppStorage("watchdogLast") private var last = 0.0

    var body: some View {
        if fired || Launch.screen == "blind" {
            HStack(spacing: 10) {
                Image(systemName: "eye.slash.fill").font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Мониторинг ослеп").font(.headline)
                    Text(last > 0 ? "Последние данные в Zabbix — \(duration(seconds: Date().timeIntervalSince1970 - last)) назад"
                                  : "Zabbix давно не получал данных")
                        .font(.caption)
                }
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(12)
            .background(Color.red.gradient, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct WatchdogSettingsView: View {
    @EnvironmentObject var session: Session
    @AppStorage("watchdogMin") private var minutes = 0
    @AppStorage("watchdogLast") private var last = 0.0
    @State private var checking = false

    var body: some View {
        Form {
            Section {
                Picker("Тревога, если нет данных", selection: $minutes) {
                    Text("Выключено").tag(0); Text("10 минут").tag(10); Text("15 минут").tag(15); Text("30 минут").tag(30); Text("1 час").tag(60)
                }
            } footer: {
                Text("Приложение смотрит, когда в Zabbix последний раз пришли данные доступности (agent.ping, icmpping). Если давно — значит, «ослеп» сам мониторинг: упал сервер, база или прокси, и о настоящих авариях вы не узнаете. Проверка идёт при открытии и при фоновом обновлении (iOS запускает его сама, примерно раз в 15–60 минут).")
            }
            Section {
                Button(checking ? "Проверяю…" : "Проверить сейчас") {
                    checking = true
                    Task { await Watchdog.check(session); checking = false }
                }
                .disabled(minutes == 0 || checking)
                if last > 0 {
                    LabeledContent("Последние данные", value: duration(seconds: Date().timeIntervalSince1970 - last) + " назад")
                }
            }
        }
        .navigationTitle("Сторож мониторинга")
    }
}

// MARK: Встряхнуть — отчёт об ошибке

extension Notification.Name { static let deviceShaken = Notification.Name("deviceShaken") }

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { NotificationCenter.default.post(name: .deviceShaken, object: nil) }
        super.motionEnded(motion, with: event)
    }
}

enum BugReport {
    @MainActor static func snapshot() -> UIImage? {
        guard let w = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.keyWindow else { return nil }
        let r = UIGraphicsImageRenderer(bounds: w.bounds)
        return r.image { _ in w.drawHierarchy(in: w.bounds, afterScreenUpdates: false) }
    }

    /// Убираем адреса, почту, IP и имя пользователя — отчёт можно отправлять в чат.
    static func redact(_ s: String, server: String, user: String) -> String {
        var r = s
        if let host = URL(string: server)?.host, !host.isEmpty { r = r.replacingOccurrences(of: host, with: "<сервер>") }
        if !user.isEmpty { r = r.replacingOccurrences(of: user, with: "<пользователь>") }
        let rules = [("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "<почта>"),
                     ("\\b\\d{1,3}(\\.\\d{1,3}){3}\\b", "<ip>"),
                     ("https?://[^\\s\"]+", "<ссылка>")]
        for (p, rep) in rules { r = r.replacingOccurrences(of: p, with: rep, options: .regularExpression) }
        return r
    }

    @MainActor static func diagnostics(_ session: Session) -> String {
        let b = Bundle.main
        let v = (b.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") + " (" + (b.infoDictionary?["CFBundleVersion"] as? String ?? "?") + ")"
        var sys = utsname(); uname(&sys)
        let model = withUnsafePointer(to: &sys.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) } }
        let d = UserDefaults.standard
        let keys = ["minSeverity", "groupProblems", "foldDeps", "notifyNew", "quietOn", "lockTimeout", "appTheme", "textSize",
                    "swipeLeft", "swipeRight", "badgeMode", "watchdogMin", "pfChip", "refreshSec", "chartStyle"]
        let settings = keys.map { k in "  \(k) = \(d.object(forKey: k).map { "\($0)" } ?? "—")" }.joined(separator: "\n")
        var t = """
        Grafana для iPhone \(v)
        iOS \(UIDevice.current.systemVersion), \(model)
        Время: \(ISO8601DateFormatter().string(from: Date()))
        Сервер: \(session.baseURL)
        Пользователь: \(session.user)
        Zabbix напрямую: \((d.string(forKey: "zbxURL") ?? "").isEmpty ? "нет" : "да")
        Очередь офлайн-действий: \(ActionQueue.shared.items.count)
        Исключённые группы: \(ProblemFilters.shared.excluded.count)
        Настройки:
        \(settings)
        """
        let log = (d.stringArray(forKey: "mxLog") ?? []).prefix(10).joined(separator: "\n")
        if !log.isEmpty { t += "\nMetricKit:\n" + log }
        return redact(t, server: session.baseURL, user: session.user)
    }
}

struct BugReportSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let shot: UIImage?
    @State private var comment = ""
    @State private var includeShot = true
    @State private var diag = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Что случилось") {
                    TextField("Например: не открывается дашборд «Серверы»", text: $comment, axis: .vertical).lineLimit(3...6)
                }
                if let shot {
                    Section {
                        Toggle("Приложить снимок экрана", isOn: $includeShot)
                        if includeShot {
                            Image(uiImage: shot).resizable().scaledToFit().frame(maxHeight: 260).clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    } footer: { Text("Снимок прикладывается как есть — проверьте, нет ли на нём лишнего.") }
                }
                Section {
                    Text(diag).font(.caption2.monospaced()).textSelection(.enabled)
                } header: { Text("Диагностика") } footer: {
                    Text("Адрес сервера, имя пользователя, почта, IP и ссылки заменены метками. Токены и пароли в отчёт не попадают.")
                }
            }
            .navigationTitle("Сообщить об ошибке")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Отправить") {
                        let text = (comment.isEmpty ? "" : "Комментарий: \(comment)\n\n") + diag
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grafana-report.txt")
                        try? text.write(to: url, atomically: true, encoding: .utf8)
                        var items: [Any] = [url]
                        if includeShot, let shot { items.append(shot) }
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { presentShare(items) }
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear { diag = BugReport.diagnostics(session) }
        }
    }
}

struct ShakeReporter: ViewModifier {
    @AppStorage("shakeReport") private var enabled = true
    @State private var shot: UIImage?
    @State private var show = Launch.screen == "bug"

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .deviceShaken)) { _ in
                guard enabled, !show else { return }
                shot = BugReport.snapshot()
                Haptics.tap()
                show = true
            }
            .sheet(isPresented: $show) { BugReportSheet(shot: shot) }
    }
}

// MARK: SLA сервисов и веб-проверки

struct SLARowData: Identifiable {
    let id: String
    let sla: String
    let service: String
    let slo: Double
    let periods: [Double]   // старые → новые
}

struct WebCheck: Identifiable {
    let id: String
    let name: String
    let host: String
    let failedStep: Int
    let error: String
    let time: Double?
}

struct ServicesSLAView: View {
    @EnvironmentObject var session: Session
    @State private var rows: [SLARowData] = []
    @State private var web: [WebCheck] = []
    @State private var loading = true
    @State private var note: String?

    var body: some View {
        List {
            Section {
                if loading { ProgressView() }
                if !loading && rows.isEmpty { Text(note ?? "В Zabbix не настроены SLA (Сервисы → SLA).").font(.footnote).foregroundStyle(.secondary) }
                ForEach(rows) { r in
                    let cur = r.periods.last ?? 100
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.service).font(.subheadline.weight(.semibold))
                                Text(r.sla + " · цель \(String(format: "%.2f", r.slo))%").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(String(format: "%.3f%%", cur)).font(.headline.monospacedDigit())
                                .foregroundStyle(cur >= r.slo ? Color.green : Color.red)
                        }
                        HStack(spacing: 3) {
                            ForEach(Array(r.periods.enumerated()), id: \.offset) { _, v in
                                RoundedRectangle(cornerRadius: 3).fill(v >= r.slo ? Color.green.opacity(0.75) : Color.red.opacity(0.85))
                                    .frame(height: 14)
                                    .overlay(Text(String(format: "%.1f", v)).font(.system(size: 8, weight: .semibold)).foregroundStyle(.white))
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: { Text("SLA сервисов") } footer: {
                if !rows.isEmpty { Text("Квадраты — последние периоды SLA, справа текущий. Красный — ниже цели.") }
            }
            Section("Веб-проверки") {
                if !loading && web.isEmpty { Text("Веб-сценариев нет").font(.footnote).foregroundStyle(.secondary) }
                ForEach(web) { w in
                    HStack(alignment: .top) {
                        Image(systemName: w.failedStep == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(w.failedStep == 0 ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(w.name).font(.subheadline)
                            Text(w.host + (w.failedStep > 0 ? " · упал шаг \(w.failedStep)" : "")).font(.caption).foregroundStyle(.secondary)
                            if !w.error.isEmpty { Text(w.error).font(.caption).foregroundStyle(.red) }
                        }
                        Spacer()
                        if let t = w.time { Text(formatValue(t, unit: "s")).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .navigationTitle("SLA и веб-проверки")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        defer { loading = false }
        if Launch.demo {
            rows = [SLARowData(id: "1", sla: "Офис 99.9", service: "Почта Exchange", slo: 99.9, periods: [99.98, 99.95, 100, 99.71]),
                    SLARowData(id: "2", sla: "Офис 99.9", service: "Файловые ресурсы", slo: 99.9, periods: [100, 100, 99.99, 100]),
                    SLARowData(id: "3", sla: "Филиалы 99.5", service: "Связь с филиалами", slo: 99.5, periods: [99.8, 99.2, 99.7, 99.9]),
                    SLARowData(id: "4", sla: "Сайты 99.95", service: "Корпоративный портал", slo: 99.95, periods: [99.99, 100, 100, 100])]
            web = [WebCheck(id: "1", name: "Портал: вход", host: "Web Portal", failedStep: 0, error: "", time: 0.42),
                   WebCheck(id: "2", name: "OWA: страница входа", host: "MBX1", failedStep: 2, error: "Ответ 503 вместо 200", time: 3.8),
                   WebCheck(id: "3", name: "1С: веб-клиент", host: "APP1", failedStep: 0, error: "", time: 1.1)]
            return
        }
        do {
            let slas = try await session.zabbixResult("sla.get", ["output": .array(["slaid", "name", "slo", "status"].map { .string($0) }),
                                                                   "filter": .object(["status": .number(1)])]).array
            var out: [SLARowData] = []
            var names: [String: String] = [:]
            for s in slas.prefix(10) {
                guard let id = s["slaid"].string else { continue }
                let r = try await session.zabbixResult("sla.getsli", ["slaid": .string(id), "periods": .number(6)])
                let sids = r["serviceids"].array.compactMap { $0.string }
                let missing = sids.filter { names[$0] == nil }
                if !missing.isEmpty, let sv = try? await session.zabbixResult("service.get", ["serviceids": .array(missing.map { .string($0) }),
                                                                                            "output": .array([.string("serviceid"), .string("name")])]) {
                    for x in sv.array { if let i = x["serviceid"].string { names[i] = x["name"].string ?? i } }
                }
                let sli = r["sli"].array   // [период][сервис]
                for (k, sid) in sids.enumerated() {
                    let vals = sli.compactMap { $0[k]["sli"].double }
                    out.append(SLARowData(id: id + "-" + sid, sla: s["name"].string ?? "", service: names[sid] ?? sid,
                                          slo: s["slo"].double ?? 99.9, periods: vals))
                }
            }
            rows = out.sorted { ($0.periods.last ?? 100) - $0.slo < ($1.periods.last ?? 100) - $1.slo }
        } catch { note = "SLA недоступны: " + error.localizedDescription }
        if let tests = try? await session.zabbixResult("httptest.get", ["output": .array(["httptestid", "name", "hostid"].map { .string($0) }),
                                                                        "monitored": .bool(true), "selectHosts": .array([.string("name")])]) {
            let items = (try? await session.zabbixResult("item.get", ["webitems": .bool(true), "monitored": .bool(true),
                                                                      "search": .object(["key_": .string("web.test.")]),
                                                                      "output": .array(["key_", "lastvalue", "hostid"].map { .string($0) })]))?.array ?? []
            func val(_ prefix: String, _ name: String) -> JSON? {
                items.first { ($0["key_"].string ?? "").hasPrefix(prefix + "[" + name) }?["lastvalue"]
            }
            web = tests.array.compactMap { t in
                guard let id = t["httptestid"].string, let n = t["name"].string else { return nil }
                return WebCheck(id: id, name: n, host: t["hosts"][0]["name"].string ?? "", failedStep: val("web.test.fail", n)?.int ?? 0,
                                error: val("web.test.error", n)?.string ?? "", time: val("web.test.time", n)?.double)
            }.sorted { $0.failedStep > $1.failedStep }
        }
    }
}

// MARK: Инвентарь хостов

struct InvHost: Identifiable, Hashable {
    let id: String
    let name: String
    let serial: String
    let model: String
    let vendor: String
    let location: String
    let rack: String
    let lat: Double?
    let lon: Double?
}

struct InventoryView: View {
    @EnvironmentObject var session: Session
    @State private var hosts: [InvHost] = []
    @State private var levels: [String: Level] = [:]
    @State private var loading = true
    @State private var q = ""
    @State private var byRack = false

    private var shown: [InvHost] {
        hosts.filter { q.isEmpty || [$0.name, $0.serial, $0.model, $0.location, $0.rack].contains { $0.localizedCaseInsensitiveContains(q) } }
    }

    var body: some View {
        List {
            let pins = shown.filter { $0.lat != nil && $0.lon != nil }
            if !pins.isEmpty {
                Section {
                    Map(initialPosition: .automatic) {
                        ForEach(pins) { (h: InvHost) in
                            Annotation(shortName(h.name), coordinate: CLLocationCoordinate2D(latitude: h.lat ?? 0, longitude: h.lon ?? 0)) {
                                pinDot(h)
                            }
                        }
                    }
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets())
                } footer: { Text("Точки — хосты с координатами из инвентаря Zabbix (location_lat / location_lon).") }
            }
            Picker("Группировка", selection: $byRack) { Text("По месту").tag(false); Text("По стойке").tag(true) }
                .pickerStyle(.segmented)
            if loading { ProgressView() }
            if !loading && hosts.isEmpty { Text("Инвентарь не заполнен: включите его в настройках хостов Zabbix (вручную или автоматически).").font(.footnote).foregroundStyle(.secondary) }
            let groups = Dictionary(grouping: shown) { byRack ? $0.rack : $0.location }.sorted { $0.key < $1.key }
            ForEach(groups, id: \.key) { g in
                Section(g.key.isEmpty ? "Не указано" : g.key) {
                    ForEach(g.value.sorted { $0.name < $1.name }) { h in
                        NavigationLink(value: HostMini(id: h.id, name: h.name)) {
                            HStack {
                                Circle().fill((levels[h.name] ?? .ok) == .ok ? Color.green : (levels[h.name] ?? .ok).color).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(h.name).font(.subheadline)
                                    Text([h.vendor, h.model].filter { !$0.isEmpty }.joined(separator: " ") + (h.serial.isEmpty ? "" : " · S/N \(h.serial)"))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $q, prompt: "Имя, серийный номер, модель, место")
        .navigationTitle("Инвентарь")
        .task { await load() }
    }

    private func pinDot(_ h: InvHost) -> some View {
        let l = levels[h.name] ?? .ok
        return Circle().fill(l == .ok ? Color.green : l.color)
            .frame(width: 14, height: 14).overlay(Circle().stroke(Color.white, lineWidth: 2))
    }

    private func load() async {
        defer { loading = false }
        levels = hostLevels((try? await session.loadProblems()) ?? [])
        if Launch.demo {
            let r = (try? await session.zabbixResult("host.get", ["output": .array([.string("hostid"), .string("name")])]))?.array ?? []
            let coords: [(Double, Double)] = [(55.75, 37.62), (55.76, 37.6), (54.71, 20.51), (55.79, 49.12), (59.93, 30.33), (68.97, 33.07), (53.2, 50.15)]
            hosts = r.prefix(24).enumerated().map { i, h in
                let c = coords[safe: i]
                return InvHost(id: h["hostid"].string ?? "\(i)", name: h["name"].string ?? "", serial: String(format: "CZ%05dX", 31_000 + i * 137),
                               model: ["ProLiant DL380 Gen10", "PowerEdge R740", "hEX S", "DS1821+"][i % 4], vendor: ["HPE", "Dell", "MikroTik", "Synology"][i % 4],
                               location: c == nil ? "Серверная, Москва" : "Филиал \(i + 1)", rack: "Стойка \(i % 3 + 1)",
                               lat: c?.0, lon: c?.1)
            }
            return
        }
        let r = (try? await session.zabbixResult("host.get", [
            "output": .array([.string("hostid"), .string("name")]),
            "selectInventory": .array(["serialno_a", "model", "vendor", "location", "location_lat", "location_lon", "site_rack", "hardware"].map { .string($0) }),
            "withInventory": .bool(true), "monitored_hosts": .bool(true)
        ]))?.array ?? []
        hosts = r.compactMap { h in
            guard let id = h["hostid"].string else { return nil }
            let inv = h["inventory"]
            func s(_ k: String) -> String { (inv[k].string ?? "").trimmingCharacters(in: .whitespaces) }
            let lat = Double(s("location_lat").replacingOccurrences(of: ",", with: "."))
            let lon = Double(s("location_lon").replacingOccurrences(of: ",", with: "."))
            return InvHost(id: id, name: h["name"].string ?? id, serial: s("serialno_a"), model: s("model").isEmpty ? s("hardware") : s("model"),
                           vendor: s("vendor"), location: s("location"), rack: s("site_rack"),
                           lat: (lat ?? 0) == 0 ? nil : lat, lon: (lon ?? 0) == 0 ? nil : lon)
        }
    }
}

// MARK: Статус для сотрудников

struct StatusLine: Identifiable {
    let id: String
    let title: String
    let icon: String
    let state: Int   // 0 работает, 1 задержки, 2 сбой
    let note: String
}

enum StatusPage {
    static let categories: [(String, String, [String])] = [
        ("Почта", "envelope.fill", ["exchange", "mbx", "mail", "smtp", "owa", "почт"]),
        ("Интернет и связь с филиалами", "network", ["icmp", "mikrotik", "ping", "канал", "провайдер", "unreachable", "недоступ"]),
        ("Файлы и общие папки", "folder.fill", ["file", "smb", "synology", "схд", "storage", "nas", "диск"]),
        ("1С и рабочие программы", "app.badge.fill", ["1c", "1с", "sql", "app", "rdp", "terminal", "терминал"]),
        ("Сайты и портал", "globe", ["ssl", "http", "web", "сайт", "портал", "сертификат"]),
        ("Телефония и VPN", "phone.fill", ["vpn", "sip", "asterisk", "телефон"])
    ]

    static func lines(_ ps: [Problem]) -> [StatusLine] {
        categories.map { c in
            let hit = ps.filter { p in c.2.contains { p.name.lowercased().contains($0) || p.host.lowercased().contains($0) } }
            let worst = hit.map(\.severity).max() ?? 0
            let st = worst >= 4 ? 2 : (worst == 3 ? 1 : 0)
            let note = st == 0 ? "Работает штатно" : (st == 1 ? "Возможны задержки" : "Сбой, специалисты уже работают")
            return StatusLine(id: c.0, title: c.0, icon: c.1, state: st, note: note)
        }
    }

    static func text(_ l: [StatusLine]) -> String {
        let bad = l.filter { $0.state > 0 }
        var t = "Статус ИТ-сервисов на \(Date().formatted(.dateTime.day().month().hour().minute().locale(Locale(identifier: "ru_RU")))):\n"
        if bad.isEmpty { t += "Все сервисы работают штатно. 👍" }
        for x in l { t += "\n" + (x.state == 0 ? "🟢" : x.state == 1 ? "🟡" : "🔴") + " " + x.title + " — " + x.note.lowercased() }
        if !bad.isEmpty { t += "\n\nСообщим, когда всё восстановится. Вопросы — в ИТ-поддержку." }
        return t
    }
}

struct StatusCardImage: View {
    let lines: [StatusLine]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Статус ИТ-сервисов").font(.title2.weight(.bold))
            Text(Date().formatted(.dateTime.day().month().hour().minute().locale(Locale(identifier: "ru_RU")))).font(.caption).foregroundStyle(.secondary)
            ForEach(lines) { l in
                HStack(spacing: 10) {
                    Image(systemName: l.icon).frame(width: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(l.title).font(.subheadline.weight(.semibold))
                        Text(l.note).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle().fill(l.state == 0 ? Color.green : l.state == 1 ? Color.orange : Color.red).frame(width: 14, height: 14)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(Color.white)
        .foregroundStyle(.black)
        .environment(\.colorScheme, .light)
    }
}

struct StatusPageView: View {
    @EnvironmentObject var session: Session
    @State private var lines: [StatusLine] = []
    @State private var text = ""
    @State private var writing = false
    @State private var aiNote: String?

    var body: some View {
        List {
            Section {
                ForEach(lines) { l in
                    HStack(spacing: 10) {
                        Image(systemName: l.icon).foregroundStyle(.secondary).frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(l.title).font(.subheadline.weight(.semibold))
                            Text(l.note).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Circle().fill(l.state == 0 ? Color.green : l.state == 1 ? Color.orange : Color.red).frame(width: 12, height: 12)
                    }
                }
                if lines.isEmpty { ProgressView() }
            } footer: { Text("Сервисы определяются по словам в названии проблем и хостов. Подробностей и имён серверов сотрудники не увидят.") }
            Section("Текст сообщения") {
                TextField("Текст", text: $text, axis: .vertical).lineLimit(6...16).font(.callout)
                Button { Task { await draft() } } label: {
                    Label(writing ? "Пишу…" : "Переписать моделью Apple (на телефоне)", systemImage: "apple.intelligence")
                }
                .disabled(writing)
                if let aiNote { Text(aiNote).font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                Button { presentShare([text]) } label: { Label("Поделиться текстом (Telegram, почта)", systemImage: "paperplane") }
                Button {
                    let r = ImageRenderer(content: StatusCardImage(lines: lines)); r.scale = 3
                    if let img = r.uiImage { presentShare([img]) }
                } label: { Label("Поделиться картинкой", systemImage: "photo") }
            }
        }
        .navigationTitle("Статус для сотрудников")
        .task {
            let ps = ProblemFilters.visible((try? await session.loadProblems()) ?? [])
            lines = StatusPage.lines(ps)
            text = StatusPage.text(lines)
        }
    }

    private func draft() async {
        writing = true
        defer { writing = false }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let ctx = lines.map { "\($0.title): \($0.note)" }.joined(separator: "\n")
            if let a = await OnDeviceLLM.answer(question: "Напиши короткое вежливое объявление для сотрудников офиса о состоянии ИТ-сервисов. Без технических терминов и имён серверов, 3–6 строк, с эмодзи-кружками статуса.", context: ctx) {
                text = a; aiNote = nil; return
            }
        }
        #endif
        aiNote = "Модель Apple недоступна на этом устройстве — оставлен шаблон."
    }
}

// MARK: «Вы дежурите сейчас»

struct OnDutyCard: View {
    @ObservedObject private var duty = DutyStore.shared

    var body: some View {
        let now = Date()
        if let i = duty.shifts.firstIndex(where: { $0.start <= now && now < $0.end }) {
            let s = duty.shifts[i]
            let mine = Launch.demo || (!duty.me.isEmpty && s.person == duty.me)
            HStack(spacing: 12) {
                Image(systemName: mine ? "person.badge.shield.checkmark.fill" : "person.fill").font(.title2)
                    .foregroundStyle(mine ? .white : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mine ? "Вы дежурите сейчас" : "Сейчас дежурит \(s.person)").font(.headline)
                    Text("до " + s.end.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(Locale(identifier: "ru_RU")))
                         + " · осталось " + duration(seconds: s.end.timeIntervalSince(now)))
                        .font(.caption).opacity(0.85)
                }
                Spacer()
                if mine && s.accepted == nil {
                    Button("Принять") { duty.shifts[i].accepted = Date(); Haptics.success() }
                        .buttonStyle(.borderedProminent).tint(.white.opacity(0.25))
                } else if mine {
                    Image(systemName: "checkmark.seal.fill")
                }
            }
            .foregroundStyle(mine ? Color.white : Color.primary)
            .padding(12)
            .background(mine ? AnyShapeStyle(Color.orange.gradient) : AnyShapeStyle(Color.secondary.opacity(0.12)), in: RoundedRectangle(cornerRadius: 14))
        } else if !duty.me.isEmpty, let next = duty.shifts.filter({ $0.person == duty.me && $0.start > now }).min(by: { $0.start < $1.start }) {
            Label("Ваше следующее дежурство — " + next.start.formatted(.dateTime.weekday(.wide).day().month().hour().minute().locale(Locale(identifier: "ru_RU"))),
                  systemImage: "calendar.badge.clock")
                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: NOC-сетка всех хостов

struct NOCGridView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var hosts: [HostMini] = []
    @State private var problems: [Problem] = []
    @State private var updated: Date?
    @State private var open: HostMini?
    @State private var onlyBad = false
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        let lv = hostLevels(problems)
        let list = hosts.filter { !onlyBad || lv[$0.name] != nil }
            .sorted { rank(lv[$0.name]) == rank(lv[$1.name]) ? $0.name < $1.name : rank(lv[$0.name]) > rank(lv[$1.name]) }
        NavigationStack {
            ScrollView {
                HStack(spacing: 14) {
                    stat(lv.values.filter { $0 == .bad }.count, "авария", .red)
                    stat(lv.values.filter { $0 == .warn }.count, "внимание", .orange)
                    stat(max(0, hosts.count - lv.count), "в норме", .green)
                    Spacer()
                    if let updated { Text(updated, style: .time).font(.caption2).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 10)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 4)], spacing: 4) {
                    ForEach(list) { h in
                        let l = lv[h.name] ?? .ok
                        Button { open = h } label: {
                            Text(shortName(h.name)).font(.system(size: 10, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.7)
                                .multilineTextAlignment(.center).foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: 40).padding(2)
                                .background(l == .ok ? Color.green.opacity(0.35) : l.color, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
                if hosts.isEmpty { ProgressView().padding(40) }
            }
            .background(Color.black)
            .navigationTitle("NOC: \(hosts.count) хостов")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Toggle("Только проблемные", isOn: $onlyBad).toggleStyle(.button) }
            }
            .sheet(item: $open) { h in NavigationStack { HostExplorerView(host: h) } }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
        .onReceive(timer) { _ in Task { await load() } }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func stat(_ n: Int, _ t: String, _ c: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 9, height: 9)
            Text("\(n)").font(.subheadline.weight(.bold).monospacedDigit())
            Text(t).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func rank(_ l: Level?) -> Int { l == .bad ? 2 : l == .warn ? 1 : 0 }

    private func load() async {
        problems = ProblemFilters.visible((try? await session.loadProblems()) ?? [])
        let r = (try? await session.zabbixResult("host.get", ["output": .array([.string("hostid"), .string("name")]), "monitored_hosts": .bool(true)]))?.array ?? []
        hosts = r.compactMap { h in h["hostid"].string.map { HostMini(id: $0, name: h["name"].string ?? $0) } }
        updated = Date()
    }
}

// MARK: Тема и размер текста

struct AppearanceMod: ViewModifier {
    @AppStorage("appTheme") private var theme = "dark"
    @AppStorage("textSize") private var textSize = 0

    private var scheme: ColorScheme? {
        switch Launch.value("--theme") ?? theme {
        case "light": return .light
        case "system": return nil
        default: return .dark
        }
    }

    @ViewBuilder func body(content: Content) -> some View {
        let c = content.preferredColorScheme(scheme)
        switch textSize {
        case -1: c.dynamicTypeSize(.small)
        case 1: c.dynamicTypeSize(.xLarge)
        case 2: c.dynamicTypeSize(.xxxLarge)
        default: c
        }
    }
}

struct AppearanceSettings: View {
    @AppStorage("appTheme") private var theme = "dark"
    @AppStorage("textSize") private var textSize = 0
    @AppStorage("shakeReport") private var shake = true

    var body: some View {
        Picker(selection: $theme) {
            Text("Тёмная").tag("dark"); Text("Светлая").tag("light"); Text("Как в системе").tag("system")
        } label: { Label("Тема", systemImage: "circle.lefthalf.filled") }
        Picker(selection: $textSize) {
            Text("Мельче").tag(-1); Text("Как в системе").tag(0); Text("Крупнее").tag(1); Text("Очень крупно").tag(2)
        } label: { Label("Размер текста", systemImage: "textformat.size") }
        Toggle(isOn: $shake) { Label("Встряхнуть — сообщить об ошибке", systemImage: "iphone.radiowaves.left.and.right") }
    }
}

// MARK: Избранные метрики

struct FavItem: Codable, Identifiable, Hashable {
    let id: String     // itemid
    let name: String
    let host: String
    let units: String
}

final class FavStore: ObservableObject {
    static let shared = FavStore()
    @Published var items: [FavItem] { didSet { if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: "favItems") } } }

    init() {
        if let d = UserDefaults.standard.data(forKey: "favItems"), let v = try? JSONDecoder().decode([FavItem].self, from: d) {
            items = v
        } else if Launch.demo {
            items = [FavItem(id: "10", name: "ICMP response time", host: "Moscow DC", units: "s"),
                     FavItem(id: "20", name: "ICMP response time", host: "Moscow", units: "s"),
                     FavItem(id: "40", name: "ICMP response time", host: "Kazan", units: "s")]
        } else { items = [] }
    }

    func contains(_ id: String) -> Bool { items.contains { $0.id == id } }
    func toggle(_ f: FavItem) {
        if contains(f.id) { items.removeAll { $0.id == f.id } } else { items.append(f) }
        Haptics.tap()
    }
}

struct FavoritesCard: View {
    @EnvironmentObject var session: Session
    @ObservedObject private var store = FavStore.shared
    @State private var series: [String: Series] = [:]
    @State private var last: [String: Double] = [:]
    @State private var edit = false
    @State private var open: FavItem?

    var body: some View {
        if !store.items.isEmpty {
            PanelCard(title: "Избранные метрики", subtitle: "закреплено \(store.items.count)", expandable: false) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(store.items) { f in
                        Button { open = f } label: { tile(f) }.buttonStyle(.plain)
                    }
                }
                Button { edit = true } label: { Label("Изменить", systemImage: "star") }.font(.caption)
            }
            .task(id: store.items) { await load() }
            .sheet(isPresented: $edit) { FavPickerView() }
            .sheet(item: $open) { f in FavDetailView(item: f) }
        }
    }

    private func tile(_ f: FavItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(f.host).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(f.name).font(.caption.weight(.semibold)).lineLimit(1)
            Text(last[f.id].map { formatValue($0, unit: f.units) } ?? "—").font(.title3.weight(.bold).monospacedDigit()).foregroundStyle(.orange)
            if let s = series[f.id], s.points.count > 2 {
                Chart(s.points) { p in
                    LineMark(x: .value("t", p.t), y: .value("v", p.v)).foregroundStyle(.orange).interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 28)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private func load() async {
        let ss = await session.itemSeries(store.items.map(\.id), hours: 6)
        var m: [String: Series] = [:], l: [String: Double] = [:]
        for (i, f) in store.items.enumerated() {
            if let s = ss.first(where: { $0.name.hasSuffix(f.name) && $0.name.hasPrefix(f.host) }) ?? ss[safe: i] {
                m[f.id] = s; l[f.id] = s.points.last?.v
            }
        }
        series = m; last = l
    }
}

struct FavDetailView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let item: FavItem
    @State private var hours = 6.0
    @State private var zoom: ClosedRange<Date>?
    @State private var series: [Series] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                RangeChips(hours: $hours)
                if zoom != nil { Button("Сбросить масштаб") { zoom = nil }.font(.caption) }
                InteractiveChart(series: series, unit: item.units, height: 260) { zoom = $0 }
                Spacer()
            }
            .padding()
            .navigationTitle(item.host)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { FavStore.shared.toggle(item); dismiss() } label: { Image(systemName: "star.slash") }
                }
            }
            .task(id: "\(hours)-\(zoom?.lowerBound.timeIntervalSince1970 ?? 0)") {
                if let z = zoom {
                    series = await session.itemSeries([item.id], hours: z.upperBound.timeIntervalSince(z.lowerBound) / 3600, to: z.upperBound)
                } else {
                    series = await session.itemSeries([item.id], hours: hours)
                }
            }
            .onChange(of: hours) { _ in zoom = nil }
        }
    }
}

struct FavPickerView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = FavStore.shared
    @State private var host: HostMini?
    @State private var pick = false
    @State private var items: [FavItem] = []
    @State private var values: [String: String] = [:]
    @State private var q = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Закреплено") {
                    if store.items.isEmpty { Text("Пока ничего").foregroundStyle(.secondary) }
                    ForEach(store.items) { f in
                        VStack(alignment: .leading) { Text(f.name).font(.subheadline); Text(f.host).font(.caption).foregroundStyle(.secondary) }
                    }
                    .onDelete { store.items.remove(atOffsets: $0) }
                    .onMove { store.items.move(fromOffsets: $0, toOffset: $1) }
                }
                Section {
                    Button { pick = true } label: { Label(host.map { "Хост: \($0.name)" } ?? "Выбрать хост…", systemImage: "server.rack") }
                    ForEach(items.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }) { f in
                        Button { store.toggle(f) } label: {
                            HStack {
                                Image(systemName: store.contains(f.id) ? "star.fill" : "star").foregroundStyle(.orange)
                                Text(f.name).font(.subheadline).foregroundStyle(.primary)
                                Spacer()
                                Text(values[f.id] ?? "").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text("Добавить") } footer: { Text("Закреплённые метрики видны на «Обзоре» с графиком за 6 часов.") }
            }
            .searchable(text: $q, prompt: "Метрика")
            .navigationTitle("Избранные метрики")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } }
            }
            .sheet(isPresented: $pick) { HostPicker(chosen: []) { h in host = h } }
            .task(id: host?.id) { await loadItems() }
        }
    }

    private func loadItems() async {
        guard let h = host else { return }
        let r = (try? await session.zabbixResult("item.get", ["hostids": .array([.string(h.id)]), "monitored": .bool(true),
                                                              "output": .array(["itemid", "name", "lastvalue", "units", "value_type"].map { .string($0) }),
                                                              "sortfield": .string("name")]))?.array ?? []
        var v: [String: String] = [:]
        items = r.compactMap { x in
            let vt = x["value_type"].int ?? 0
            guard let id = x["itemid"].string, vt == 0 || vt == 3 else { return nil }
            let u = x["units"].string ?? ""
            if let d = x["lastvalue"].double { v[id] = formatValue(d, unit: u) }
            return FavItem(id: id, name: x["name"].string ?? id, host: h.name, units: u)
        }
        values = v
    }
}

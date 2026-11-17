import SwiftUI
import Charts
import LocalAuthentication
import EventKit

// v2.9 (функции): Face ID перед записью, метки в Grafana, плановые работы в Календарь,
// «кто менял Zabbix», поиск по всему, прогнозы, зависимости хостов, «до и после»,
// метрики приложения в Zabbix, ссылки grafanaapp://problem/<eventid>.

// MARK: Face ID перед действиями, которые меняют Zabbix

enum FaceGate {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "faceIdWrites") as? Bool ?? true }

    static func ok(_ reason: String) async -> Bool {
        guard enabled, !Launch.demo else { return true }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return true }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

// MARK: Метки на графиках ↔ аннотации Grafana

extension Session {
    /// Метка в Grafana для всей организации (видна на всех дашбордах с аннотациями). Возвращает id.
    func postAnnotation(date: Date, text: String) async -> Int? {
        guard !demo else { return nil }
        let body: JSON = .object(["time": .number((date.timeIntervalSince1970 * 1000).rounded()),
                                  "text": .string(text), "tags": .array([.string("mobile-app")])])
        return (try? await request("/api/annotations", method: "POST", body: body))?["id"].int
    }

    func fetchAnnotations(days: Int = 30) async -> [(id: Int, date: Date, text: String)] {
        guard !demo else { return [] }
        let to = Int(Date().timeIntervalSince1970 * 1000), from = to - days * 86_400_000
        let r = (try? await request("/api/annotations?from=\(from)&to=\(to)&limit=300&type=annotation"))?.array ?? []
        return r.compactMap { a in
            guard let id = a["id"].int, let t = a["time"].double else { return nil }
            let text = (a["text"].string ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            return (id, Date(timeIntervalSince1970: t / 1000), text.isEmpty ? "Метка" : text)
        }
    }

    /// Свои метки уходят в Grafana, чужие из Grafana появляются на графиках «Панелей».
    func syncAnnotations() async {
        guard UserDefaults.standard.object(forKey: "annoToGrafana") as? Bool ?? true else { return }
        let store = Annotations.shared
        store.sink = { [weak self] d, t in
            guard let self else { return nil }
            return await self.postAnnotation(date: d, text: t)
        }
        let remote = await fetchAnnotations()
        let known = Set(store.items.compactMap(\.remoteId))
        for r in remote where !known.contains(r.id) {
            store.items.append(Annotation(key: "panels", date: r.date, text: r.text, remoteId: r.id))
        }
    }
}

// MARK: Плановые работы → Календарь iOS

enum CalendarExport {
    static func add(_ m: ZMaintenance) async -> String {
        let store = EKEventStore()
        let granted = (try? await store.requestWriteOnlyAccessToEvents()) ?? false
        guard granted else { return "Нет доступа к Календарю: разрешите в Настройках iOS → Grafana → Календари." }
        let e = EKEvent(eventStore: store)
        e.title = "Работы: " + (m.hosts.isEmpty ? m.name : m.hosts.joined(separator: ", "))
        e.startDate = m.since
        e.endDate = m.till
        e.notes = [m.note, m.name].filter { !$0.isEmpty }.joined(separator: "\n")
        e.calendar = store.defaultCalendarForNewEvents
        e.addAlarm(EKAlarm(relativeOffset: -1800))
        do { try store.save(e, span: .thisEvent); return "Добавлено в Календарь" }
        catch { return "Не удалось: \(error.localizedDescription)" }
    }
}

// MARK: Кто менял Zabbix (журнал аудита по отдельному токену)

struct AuditRow: Identifiable {
    let id: String
    let date: Date
    let user: String
    let action: Int
    let type: Int
    let object: String
    let ip: String
}

enum AuditNames {
    static func action(_ a: Int) -> (String, String) {
        switch a {
        case 0: return ("добавил", "plus.circle")
        case 1: return ("изменил", "pencil.circle")
        case 2: return ("удалил", "trash.circle")
        case 4: return ("вышел", "rectangle.portrait.and.arrow.right")
        case 7: return ("выполнил", "play.circle")
        case 8: return ("вошёл", "person.crop.circle.badge.checkmark")
        case 9: return ("неудачный вход", "exclamationmark.lock")
        case 10: return ("очистил историю", "clock.badge.xmark")
        case 11: return ("обновил конфигурацию", "arrow.clockwise.circle")
        default: return ("действие \(a)", "circle")
        }
    }

    static func type(_ t: Int) -> String {
        [0: "пользователь", 3: "способ оповещения", 4: "хост", 5: "действие", 6: "график", 11: "группа пользователей",
         13: "триггер", 14: "группа хостов", 15: "элемент данных", 17: "сценарий", 19: "обслуживание", 20: "карта",
         22: "веб-сценарий", 23: "правило обнаружения", 25: "скрипт", 26: "прокси", 28: "регулярное выражение",
         29: "макрос", 30: "шаблон", 31: "прототип триггера", 33: "дашборд", 36: "прототип элемента",
         40: "настройки", 42: "аутентификация", 44: "роль", 45: "API-токен", 48: "SLA", 50: "группа шаблонов"][t] ?? "объект \(t)"
    }
}

struct AuditView: View {
    @State private var token = Keychain.load(account: "auditToken") ?? ""
    @State private var rows: [AuditRow] = []
    @State private var loading = false
    @State private var error: String?
    @State private var showLogins = false
    @State private var query = ""

    private var shown: [AuditRow] {
        rows.filter { r in
            (showLogins || ![4, 8].contains(r.action)) &&
            (query.isEmpty || r.object.localizedCaseInsensitiveContains(query) || r.user.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        List {
            if token.isEmpty && !Launch.demo {
                Section {
                    SecureField("API-токен Zabbix с правом auditlog.get", text: $token)
                    Button("Сохранить") { Keychain.save(token, account: "auditToken"); Task { await load() } }.disabled(token.isEmpty)
                } footer: {
                    Text("Журнал аудита Zabbix читает только суперадминистратор, поэтому нужен отдельный токен. Удобно завести отдельного пользователя с ролью, где разрешён только auditlog.get. Токен хранится в Keychain телефона.")
                }
            }
            Section {
                Toggle("Показывать входы и выходы", isOn: $showLogins)
            }
            if loading { ProgressView() }
            if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
            ForEach(shown) { r in
                let a = AuditNames.action(r.action)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: a.1).foregroundStyle(r.action == 2 || r.action == 9 ? Level.bad.color : (r.action == 0 ? Level.ok.color : Color.orange))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(r.user) \(a.0) \(AuditNames.type(r.type))").font(.subheadline)
                        if !r.object.isEmpty { Text(r.object).font(.caption).lineLimit(2) }
                        Text("\(ruDate(r.date)) · \(r.ip)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Кто менял Zabbix")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Хост, триггер или пользователь")
        .toolbar {
            if !token.isEmpty {
                Menu {
                    Button("Сменить токен", role: .destructive) { Keychain.delete(account: "auditToken"); token = ""; rows = [] }
                } label: { Image(systemName: "key") }
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        if Launch.demo {
            let now = Date()
            rows = [
                AuditRow(id: "1", date: now.addingTimeInterval(-1200), user: "Admin", action: 1, type: 13, object: "MSA 2040: Disk health is in failure", ip: "10.0.0.5"),
                AuditRow(id: "2", date: now.addingTimeInterval(-5400), user: "Admin", action: 0, type: 11, object: "Мобильное приложение (запись)", ip: "10.0.0.5"),
                AuditRow(id: "3", date: now.addingTimeInterval(-7200), user: "app-ack", action: 7, type: 25, object: "Mikrotik - Branch 3", ip: "203.0.113.7"),
                AuditRow(id: "4", date: now.addingTimeInterval(-86400), user: "Admin", action: 2, type: 15, object: "HYPER3: старый элемент температуры", ip: "10.0.0.5"),
                AuditRow(id: "5", date: now.addingTimeInterval(-90000), user: "unknown", action: 9, type: 0, object: "admin", ip: "198.51.100.11")
            ]
            return
        }
        guard !token.isEmpty, let base = ZabbixDirect.config?.url ?? URL(string: (UserDefaults.standard.string(forKey: "zbxURL") ?? "") + "/api_jsonrpc.php") else {
            if !token.isEmpty { error = "Укажите адрес Zabbix в Настройках → «Подтверждение проблем»." }
            return
        }
        loading = true
        defer { loading = false }
        do {
            let r = try await ZabbixDirect.result(.init(url: base, token: token), method: "auditlog.get", params: [
                "output": .array(["auditid", "clock", "username", "action", "resourcetype", "resourcename", "ip"].map { .string($0) }),
                "time_from": .number(Date().addingTimeInterval(-7 * 86400).timeIntervalSince1970.rounded()),
                "sortfield": .string("clock"), "sortorder": .string("DESC"), "limit": .number(300)
            ])
            rows = r.array.map { a in
                AuditRow(id: a["auditid"].string ?? UUID().uuidString, date: Date(timeIntervalSince1970: a["clock"].double ?? 0),
                         user: a["username"].string ?? "", action: a["action"].int ?? -1, type: a["resourcetype"].int ?? -1,
                         object: a["resourcename"].string ?? "", ip: a["ip"].string ?? "")
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: Поиск по всему

struct TrigHit: Identifiable { let id: String; let name: String; let host: String }

struct SearchAllView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var q = Launch.screen == "search-all" ? "MBX" : ""
    @State private var hosts: [HostMini] = []
    @State private var problems: [Problem] = []
    @State private var triggers: [TrigHit] = []
    @State private var items: [(name: String, host: String, hostId: String, value: String)] = []
    @State private var busy = false
    @State private var allProblems: [Problem] = []

    private var incidents: [Incident] {
        IncidentStore.shared.items.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.problems.contains { $0.localizedCaseInsensitiveContains(q) } }
    }

    private var notes: [String] {
        TriggerNoteStore.shared.notes.values.filter { $0.localizedCaseInsensitiveContains(q) }.sorted()
    }

    var body: some View {
        NavigationStack {
            List {
                if q.count < 2 {
                    Text("Ищу по хостам, проблемам, триггерам, показателям, авариям и заметкам.").font(.footnote).foregroundStyle(.secondary)
                }
                if busy { ProgressView() }
                if !hosts.isEmpty {
                    Section("Хосты") {
                        ForEach(hosts) { h in NavigationLink(value: h) { Label(h.name, systemImage: "server.rack") } }
                    }
                }
                if !problems.isEmpty {
                    Section("Проблемы сейчас") {
                        ForEach(problems) { p in NavigationLink(value: p) { ProblemRow(p: p) } }
                    }
                }
                if !items.isEmpty {
                    Section("Показатели") {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                            NavigationLink(value: HostMini(id: it.hostId, name: it.host)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(it.name).font(.subheadline).lineLimit(2)
                                    HStack { Text(it.host); Spacer(); Text(it.value).monospacedDigit() }.font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if !triggers.isEmpty {
                    Section("Триггеры") {
                        ForEach(triggers) { t in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name).font(.subheadline)
                                Text(t.host).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !incidents.isEmpty && q.count >= 2 {
                    Section("Аварии") {
                        ForEach(incidents) { i in NavigationLink { IncidentDetailView(id: i.id) } label: { Label(i.title, systemImage: "flame") } }
                    }
                }
                if !notes.isEmpty && q.count >= 2 {
                    Section("Мои заметки к триггерам") {
                        ForEach(notes, id: \.self) { n in Text(n).font(.caption) }
                    }
                }
            }
            .navigationTitle("Поиск")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $q, placement: .navigationBarDrawer(displayMode: .always), prompt: "Хост, проблема, показатель…")
            .navigationDestination(for: HostMini.self) { HostExplorerView(host: $0) }
            .navigationDestination(for: Problem.self) { ProblemDetailView(problem: $0, all: allProblems) }
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } } }
            .task(id: q) { await search() }
        }
    }

    private func search() async {
        let s = q.trimmingCharacters(in: .whitespaces)
        guard s.count >= 2 else { hosts = []; problems = []; triggers = []; items = []; return }
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled else { return }
        busy = true
        defer { busy = false }
        if allProblems.isEmpty { allProblems = (try? await session.loadProblems()) ?? [] }
        problems = allProblems.filter { $0.name.localizedCaseInsensitiveContains(s) || $0.host.localizedCaseInsensitiveContains(s) }
        hosts = (try? await session.searchHosts(s)) ?? []
        let t = (try? await session.zabbixResult("trigger.get", [
            "search": .object(["description": .string(s)]), "searchWildcardsEnabled": .bool(true),
            "output": .array(["triggerid", "description"].map { .string($0) }), "selectHosts": .array([.string("name")]),
            "expandDescription": .bool(true), "limit": .number(20)
        ]))?.array ?? []
        triggers = t.compactMap { x in
            guard let id = x["triggerid"].string else { return nil }
            return TrigHit(id: id, name: x["description"].string ?? "", host: x["hosts"][0]["name"].string ?? "")
        }
        let it = (try? await session.zabbixResult("item.get", [
            "search": .object(["name": .string(s)]), "output": .array(["itemid", "name", "lastvalue", "units", "hostid"].map { .string($0) }),
            "selectHosts": .array([.string("name")]), "monitored": .bool(true), "limit": .number(30)
        ]))?.array ?? []
        items = it.compactMap { x in
            guard let n = x["name"].string, let hid = x["hostid"].string else { return nil }
            let v = x["lastvalue"].string ?? ""
            let unit = x["units"].string ?? ""
            let text = Double(v).map { formatValue($0, unit: unit == "%" ? "percent" : nil) + (unit == "%" || unit.isEmpty ? "" : " " + unit) } ?? v
            return (n, x["hosts"][0]["name"].string ?? "", hid, text)
        }
    }
}

// MARK: Прогнозы: тренд + суточный ритм

struct ForecastHit: Identifiable {
    var id: String { host + metric }
    let host: String
    let metric: String
    let threshold: Double
    let when: Date?
    let now: Double
    let history: [Pt]
    let forecast: [Pt]
}

enum Forecaster {
    /// Линейный тренд + средний профиль по часу суток; прогноз на 7 дней с шагом в час.
    static func run(_ s: Series) -> (forecast: [Pt], slopePerDay: Double)? {
        let pts = s.points.sorted { $0.t < $1.t }
        guard pts.count > 24, let t0 = pts.first?.t else { return nil }
        let xs = pts.map { $0.t.timeIntervalSince(t0) / 3600 }, ys = pts.map(\.v)
        let n = Double(xs.count), mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let sxx = zip(xs, xs).map { ($0 - mx) * ($1 - mx) }.reduce(0, +)
        guard sxx > 0 else { return nil }
        let b = zip(xs, ys).map { ($0 - mx) * ($1 - my) }.reduce(0, +) / sxx
        let a = my - b * mx
        var sum = [Double](repeating: 0, count: 24), cnt = [Double](repeating: 0, count: 24)
        let cal = Calendar.current
        for (i, p) in pts.enumerated() {
            let h = cal.component(.hour, from: p.t)
            sum[h] += ys[i] - (a + b * xs[i]); cnt[h] += 1
        }
        let season = (0..<24).map { cnt[$0] > 0 ? sum[$0] / cnt[$0] : 0 }
        let last = pts.last!.t
        var out: [Pt] = []
        for k in 1...(7 * 24) {
            let t = last.addingTimeInterval(Double(k) * 3600)
            let x = t.timeIntervalSince(t0) / 3600
            let v = a + b * x + season[cal.component(.hour, from: t)]
            out.append(Pt(id: k, t: t, v: min(100, max(0, v))))
        }
        return (out, b * 24)
    }
}

struct ForecastPanel: View {
    @EnvironmentObject var session: Session
    @State private var hits: [ForecastHit] = []
    @State private var loaded = false
    @State private var sel: String?

    var body: some View {
        PanelCard(title: "Прогноз на неделю", subtitle: "тренд + суточный ритм · 7 дней истории") {
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, minHeight: 60)
            } else if hits.isEmpty {
                Label("За неделю ни один сервер не дойдёт до порога CPU и памяти", systemImage: "checkmark.seal").font(.caption).foregroundStyle(Level.ok.color)
            } else {
                ForEach(hits) { h in
                    Button { withAnimation { sel = sel == h.id ? nil : h.id } } label: {
                        HStack {
                            Text(shortName(h.host)).font(.caption.weight(.semibold)).frame(width: 90, alignment: .leading).lineLimit(1)
                            Text(h.metric).font(.caption2).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                            Text("\(Int(h.now))% → \(Int(h.threshold))%").font(.caption.monospacedDigit())
                            Spacer()
                            Text(h.when.map { $0.formatted(.dateTime.weekday(.abbreviated).hour().locale(Locale(identifier: "ru_RU"))) } ?? "—")
                                .font(.caption.weight(.bold)).foregroundStyle(Level.bad.color)
                        }
                    }
                    .buttonStyle(.plain)
                    if sel == h.id { chart(h) }
                }
            }
        }
        .task { if !loaded { await load() } }
    }

    private func chart(_ h: ForecastHit) -> some View {
        Chart {
            ForEach(h.history) { p in LineMark(x: .value("t", p.t), y: .value("v", p.v), series: .value("s", "было")).foregroundStyle(Color.orange) }
            ForEach(h.forecast) { p in
                LineMark(x: .value("t", p.t), y: .value("v", p.v), series: .value("s", "прогноз"))
                    .foregroundStyle(Color.orange.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
            }
            RuleMark(y: .value("порог", h.threshold)).foregroundStyle(Level.bad.color.opacity(0.7))
            if let w = h.when { RuleMark(x: .value("когда", w)).foregroundStyle(Level.bad.color.opacity(0.5)) }
        }
        .chartYScale(domain: 0...100)
        .frame(height: 140)
    }

    private func load() async {
        defer { loaded = true }
        var out: [ForecastHit] = []
        for (metric, filter, key) in [("RAM", "Memory utilization", "mem"), ("CPU", "CPU utilization", "cpu")] {
            let ser = (try? await session.hostSeries(host: "/.*/", filter: filter, seconds: 7 * 86400, group: serverGroups, maxPoints: 168)) ?? []
            for s in ser {
                guard let f = Forecaster.run(s), let now = s.points.last?.v else { continue }
                let thr = HostThrStore.shared.thresholds(s.name, key).bad
                let when = f.forecast.first { $0.v >= thr }?.t
                if when != nil || (f.slopePerDay > 1 && now > thr - 15) {
                    out.append(ForecastHit(host: s.name, metric: metric, threshold: thr, when: when, now: now,
                                           history: Array(s.points.suffix(72)), forecast: f.forecast))
                }
            }
        }
        hits = out.sorted { ($0.when ?? .distantFuture) < ($1.when ?? .distantFuture) }.prefix(8).map { $0 }
    }
}

// MARK: Зависимости хостов (своя схема на телефоне)

final class DepStore: ObservableObject {
    static let shared = DepStore()
    /// хост → от какого хоста зависит (например, ПК филиала → «Mikrotik - Kazan»)
    @Published var parent: [String: String] { didSet { UserDefaults.standard.set(parent, forKey: "hostDeps") } }

    init() {
        parent = (UserDefaults.standard.dictionary(forKey: "hostDeps") as? [String: String])
            ?? (Launch.demo ? ["MBX3": "Synology DS423+", "Windows: FS": "Synology DS423+"] : [:])
    }

    /// Проблемы, чей хост зависит от хоста с активной проблемой: родитель → дети.
    func fold(_ ps: [Problem]) -> (visible: [Problem], children: [String: [Problem]]) {
        let down = Set(ps.map(\.host))
        var children: [String: [Problem]] = [:]
        var visible: [Problem] = []
        for p in ps {
            if let par = parent[p.host], down.contains(par), par != p.host { children[par, default: []].append(p) }
            else { visible.append(p) }
        }
        return (visible, children)
    }
}

struct HostDependencySection: View {
    let host: HostMini
    @ObservedObject private var store = DepStore.shared
    @State private var picking = false

    var body: some View {
        Section {
            if let p = store.parent[host.name] {
                HStack {
                    Label(p, systemImage: "arrow.turn.left.up")
                    Spacer()
                    Button("Убрать") { store.parent[host.name] = nil }.font(.caption)
                }
            }
            Button(store.parent[host.name] == nil ? "Указать, от чего зависит…" : "Сменить…") { picking = true }
        } header: { Text("Зависит от") } footer: {
            Text("Если у родителя (например, маршрутизатора филиала) есть проблема, проблемы этого хоста сворачиваются под ней в списке.")
        }
        .sheet(isPresented: $picking) {
            HostPicker(chosen: []) { h in if h.name != host.name { store.parent[host.name] = h.name } }
        }
    }
}

// MARK: До и после события

struct BeforeAfterView: View {
    @EnvironmentObject var session: Session
    let date: Date
    let title: String
    @State private var rows: [(host: String, metric: String, before: Double, after: Double)] = []
    @State private var avgBefore: [Pt] = []
    @State private var avgAfter: [Pt] = []
    @State private var loading = true

    var body: some View {
        List {
            Section {
                Text(title).font(.headline)
                Text("Сутки до \(ruDate(date)) и сутки после").font(.caption).foregroundStyle(.secondary)
                if !avgAfter.isEmpty {
                    Chart {
                        ForEach(avgBefore) { p in
                            LineMark(x: .value("t", p.t), y: .value("v", p.v), series: .value("s", "до"))
                                .foregroundStyle(Color.secondary).lineStyle(StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
                        }
                        ForEach(avgAfter) { p in
                            LineMark(x: .value("t", p.t), y: .value("v", p.v), series: .value("s", "после")).foregroundStyle(Color.orange)
                        }
                    }
                    .chartYScale(domain: 0...100)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisValueLabel(format: .dateTime.hour().minute().locale(Locale(identifier: "ru_RU")))
                        }
                    }
                    .frame(height: 160)
                    HStack(spacing: 14) {
                        Label("до (сдвинуто на сутки)", systemImage: "line.diagonal").foregroundStyle(.secondary)
                        Label("после", systemImage: "line.diagonal").foregroundStyle(.orange)
                    }
                    .font(.caption2)
                }
            } header: { Text("Средний CPU серверов") }
            if loading { ProgressView() }
            if !rows.isEmpty {
                Section("Сильнее всего изменилось") {
                    ForEach(Array(rows.prefix(15).enumerated()), id: \.offset) { _, r in
                        let d = r.after - r.before
                        HStack {
                            Text(shortName(r.host)).font(.subheadline).lineLimit(1)
                            Text(r.metric).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(r.before))% → \(Int(r.after))%").font(.caption.monospacedDigit())
                            Image(systemName: d > 0 ? "arrow.up.right" : "arrow.down.right")
                                .foregroundStyle(d > 3 ? Level.bad.color : (d < -3 ? Level.ok.color : Color.secondary))
                        }
                    }
                }
            }
        }
        .navigationTitle("До и после")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        defer { loading = false }
        let end = min(Date(), date.addingTimeInterval(86400))
        var out: [(String, String, Double, Double)] = []
        var cpuAll: [Series] = []
        for (metric, filter) in [("CPU", "CPU utilization"), ("RAM", "Memory utilization")] {
            let ser = (try? await session.hostSeries(host: "/.*/", filter: filter, seconds: end.timeIntervalSince(date) + 86400,
                                                     group: serverGroups, maxPoints: 200, to: end)) ?? []
            if metric == "CPU" { cpuAll = ser }
            for s in ser {
                let b = s.points.filter { $0.t < date }.map(\.v), a = s.points.filter { $0.t >= date }.map(\.v)
                guard !b.isEmpty, !a.isEmpty else { continue }
                out.append((s.name, metric, b.reduce(0, +) / Double(b.count), a.reduce(0, +) / Double(a.count)))
            }
        }
        rows = out.sorted { abs($0.3 - $0.2) > abs($1.3 - $1.2) }.map { (host: $0.0, metric: $0.1, before: $0.2, after: $0.3) }
        // средняя линия по всем хостам, «до» сдвинуто на сутки вперёд, чтобы лечь под «после»
        func avg(_ pick: (Pt) -> Bool, shift: Double) -> [Pt] {
            var buckets: [Int: [Double]] = [:]
            for s in cpuAll { for p in s.points where pick(p) { buckets[Int(p.t.timeIntervalSince1970 / 900), default: []].append(p.v) } }
            return buckets.keys.sorted().enumerated().map { i, k in
                Pt(id: i, t: Date(timeIntervalSince1970: Double(k) * 900 + shift), v: buckets[k]!.reduce(0, +) / Double(buckets[k]!.count))
            }
        }
        avgBefore = avg({ $0.t < date }, shift: 86400)
        avgAfter = avg({ $0.t >= date }, shift: 0)
    }
}

// MARK: Метрики приложения → Zabbix (history.push)

@MainActor
enum AppMetrics {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "pushMetrics") }
    static var host: String { UserDefaults.standard.string(forKey: "metricsHost") ?? "mobile-app" }
    private static var lat: [Int] = []
    private static var errors = 0
    private static var lastFlush = Date()

    static func latency(_ ms: Int) { lat.append(ms); flushIfDue() }
    static func error() { errors += 1; flushIfDue() }

    /// Сколько прошло от начала проблемы до подтверждения.
    static func ackDelay(_ since: Date) {
        push(["mobile.ack_delay": Date().timeIntervalSince(since)])
    }

    private static func flushIfDue() {
        guard Date().timeIntervalSince(lastFlush) > 300 else { return }
        lastFlush = Date()
        var v: [String: Double] = ["mobile.errors": Double(errors)]
        if !lat.isEmpty { v["mobile.latency"] = Double(lat.reduce(0, +)) / Double(lat.count) }
        lat = []; errors = 0
        push(v)
    }

    static func push(_ values: [String: Double]) {
        guard enabled, !Launch.demo, let c = ZabbixDirect.config else { return }
        let now = Date().timeIntervalSince1970.rounded()
        let arr: [JSON] = values.map { .object(["host": .string(host), "key": .string($0.key),
                                                "value": .string(String(format: "%.1f", $0.value)), "clock": .number(now)]) }
        Task.detached {
            var req = URLRequest(url: c.url, timeoutInterval: 15)
            req.httpMethod = "POST"
            req.setValue("application/json-rpc", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer " + c.token, forHTTPHeaderField: "Authorization")
            req.httpBody = try? JSONEncoder().encode(JSON.object(["jsonrpc": .string("2.0"), "method": .string("history.push"),
                                                                  "params": .array(arr), "id": .number(1)]))
            _ = try? await URLSession.shared.data(for: req)
        }
    }
}

// MARK: Ссылка на проблему: grafanaapp://problem/<eventid>

struct ProblemRef: Identifiable, Hashable { let id: String }

struct ProblemLinkView: View {
    @EnvironmentObject var session: Session
    let eventId: String
    var onClose: () -> Void
    @State private var problem: Problem?
    @State private var all: [Problem] = []
    @State private var notFound = false

    var body: some View {
        NavigationStack {
            Group {
                if let problem { ProblemDetailView(problem: problem, all: all) }
                else if notFound {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill").font(.largeTitle).foregroundStyle(Level.ok.color)
                        Text("Проблема \(eventId) уже решена или не найдена.").multilineTextAlignment(.center)
                    }
                    .padding(30)
                } else { ProgressView() }
            }
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { onClose() } } }
            .task {
                all = (try? await session.loadProblems()) ?? []
                problem = all.first { $0.id == eventId }
                notFound = problem == nil
            }
        }
    }
}

// MARK: Мгновенные уведомления через ntfy (настраивается на сервере Zabbix)

struct NtfySetupView: View {
    @AppStorage("ntfyTopic") private var topic = ""
    @AppStorage("ntfyServer") private var server = "https://ntfy.sh"

    var body: some View {
        Form {
            Section {
                Text("Apple не даёт бесплатному аккаунту присылать push в своё приложение. Обходной путь: Zabbix отправляет оповещение в сервис ntfy, а приложение ntfy из App Store показывает его мгновенно. Нажатие на уведомление открывает проблему здесь, в Grafana.")
                    .font(.footnote)
            }
            Section {
                TextField("Сервер ntfy", text: $server).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                HStack {
                    TextField("Тема", text: $topic).textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
                    Button("Новая") { topic = "zbx-" + UUID().uuidString.prefix(12).lowercased() }
                }
            } header: { Text("Тема") } footer: {
                Text("Тема — как пароль: кто её знает, тот видит оповещения. На публичном ntfy.sh тексты проблем проходят через чужой сервер; надёжнее поднять свой ntfy.")
            }
            Section("Шаги") {
                Label("Установите ntfy из App Store и подпишитесь на тему выше", systemImage: "1.circle")
                Label("В Zabbix: способ оповещения «ntfy» (вебхук) с этой темой — я могу создать его через API с вашего согласия", systemImage: "2.circle")
                Label("Ссылка в оповещении: grafanaapp://problem/{EVENT.ID}", systemImage: "3.circle")
                if !topic.isEmpty {
                    ShareLink(item: "\(server)/\(topic)") { Label("Поделиться адресом темы", systemImage: "square.and.arrow.up") }
                    Link(destination: URL(string: "https://apps.apple.com/app/ntfy/id1625396347")!) { Label("ntfy в App Store", systemImage: "arrow.down.app") }
                }
            }
        }
        .navigationTitle("Мгновенные уведомления")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if topic.isEmpty { topic = "zbx-" + UUID().uuidString.prefix(12).lowercased() } }
    }
}

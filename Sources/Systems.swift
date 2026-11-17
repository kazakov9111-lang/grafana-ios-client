import SwiftUI
import Charts

// MARK: Описание экранов «Системы»

enum Level: Int, Comparable {
    case none = 0, ok, warn, bad
    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

    var color: Color {
        switch self {
        case .bad: return Color(hex: "F2495C")
        case .warn: return Color(hex: "FF9830")
        case .ok: return Color(hex: "73BF69")
        case .none: return Color(hex: "8E8E93")
        }
    }
}

enum ColRule {
    case none
    case okIsOne
    case above(warn: Double, bad: Double)
    case below(warn: Double, bad: Double)
}

enum ColUnit { case percent, count, seconds, flag, days, hours, service }

struct Col: Identifiable {
    let id: String
    let title: String
    var names: [String] = []
    var search: String?
    var unit: ColUnit = .count
    var rule: ColRule = .none
    var chart = false

    func level(_ v: Double?) -> Level {
        guard let v else { return .none }
        switch rule {
        case .none: return .none
        case .okIsOne: return v >= 1 ? .ok : .bad
        case .above(let w, let b): return v >= b ? .bad : (v >= w ? .warn : .ok)
        case .below(let w, let b): return v <= b ? .bad : (v <= w ? .warn : .ok)
        }
    }

    func format(_ v: Double?) -> String {
        guard let v else { return "—" }
        switch unit {
        case .flag: return v >= 1 ? "OK" : "нет"
        case .percent: return String(format: v >= 100 || v == v.rounded() ? "%.0f%%" : "%.1f%%", v)
        case .count: return v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
        case .seconds: return v < 1 ? String(format: "%.0f мс", v * 1000) : String(format: "%.1f с", v)
        case .days: return "\(Int(v)) дн"
        case .hours: return v >= 48 ? "\(Int(v / 24)) дн" : "\(Int(v)) ч"
        case .service: return v == 0 ? "работает" : (v == 6 ? "стоп" : "код \(Int(v))")
        }
    }

    /// Фильтр показателя для запроса истории.
    var historyFilter: String {
        if let s = search { return "/" + NSRegularExpression.escapedPattern(for: s) + "/" }
        if names.count == 1 { return names[0] }
        return "/^(" + names.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")$/"
    }
}

struct SystemScreen: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let group: String
    let host: String
    let cols: [Col]
    var section = "Инфраструктура"
    var sortCol: String? = nil
    var sortDesc = false
}

private let pingCol = Col(id: "ping", title: "Связь", names: ["Zabbix agent ping"], unit: .flag, rule: .okIsOne)
private let cpuCol = Col(id: "cpu", title: "CPU", names: ["CPU utilization"], unit: .percent, rule: .above(warn: 80, bad: 90), chart: true)
private let memCol = Col(id: "mem", title: "RAM", names: ["Memory utilization"], unit: .percent, rule: .above(warn: 85, bad: 92), chart: true)
let serverGroups = "/^(Hypervisors|Linux servers|OMS_Servers|1C Server|Exchange|Domain Controllers|Zabbix servers)$/"

let systemScreens: [SystemScreen] = [
    SystemScreen(id: "servers", title: "Серверы", subtitle: "Загрузка, память, диски",
                 icon: "server.rack", group: serverGroups, host: "/.*/",
                 cols: [pingCol, cpuCol, memCol,
                        Col(id: "disk", title: "Диск", search: "Space: Used, in %", unit: .percent, rule: .above(warn: 85, bad: 92), chart: true)]),
    SystemScreen(id: "hyper", title: "Гипервизоры", subtitle: "Виртуальные машины и нагрузка",
                 icon: "cpu", group: "Hypervisors", host: "/.*/",
                 cols: [pingCol,
                        Col(id: "vmon", title: "ВМ вкл.", names: ["ВМ: запущено"], unit: .count),
                        Col(id: "vmall", title: "ВМ всего", names: ["ВМ: всего"], unit: .count),
                        cpuCol, memCol]),
    SystemScreen(id: "net", title: "Сеть и филиалы", subtitle: "Доступность и задержка Mikrotik",
                 icon: "network", group: "Mikrotik", host: "/.*/",
                 cols: [Col(id: "ping", title: "Связь", names: ["ICMP ping"], unit: .flag, rule: .okIsOne),
                        Col(id: "loss", title: "Потери", names: ["ICMP loss"], unit: .percent, rule: .above(warn: 5, bad: 30), chart: true),
                        Col(id: "rtt", title: "Задержка", names: ["ICMP response time"], unit: .seconds, rule: .above(warn: 0.15, bad: 0.4), chart: true)]),
    SystemScreen(id: "storage", title: "СХД и NAS", subtitle: "Массивы и свободное место",
                 icon: "externaldrive", group: "/.*/", host: "/^(MSA|P2000|Synology)/",
                 cols: [Col(id: "health", title: "Здоровье", names: ["System health"], unit: .count, rule: .above(warn: 1, bad: 2)),
                        Col(id: "free", title: "Свободно", names: ["Synology: место свободно %"], unit: .percent, rule: .below(warn: 25, bad: 15), chart: true)]),

    SystemScreen(id: "mail", title: "Почта Exchange", subtitle: "Очереди и серверы",
                 icon: "envelope", group: "/.*/", host: "/MBX/",
                 cols: [pingCol,
                        Col(id: "queue", title: "Очередь", names: ["Exchange Transport Queue Length: Delivery queue length (all queues)"],
                            unit: .count, rule: .above(warn: 20, bad: 100), chart: true),
                        Col(id: "poison", title: "Poison", names: ["Exchange Transport Queue Length: Poison queue length"],
                            unit: .count, rule: .above(warn: 1, bad: 1)),
                        cpuCol, memCol], section: "Сервисы"),
    SystemScreen(id: "ad", title: "Active Directory", subtitle: "Ошибки входа, пароль krbtgt, опасные учётки",
                 icon: "person.3", group: "Domain Controllers", host: "/.*/",
                 cols: [Col(id: "ldap", title: "LDAP", names: ["ADDS: LDAP Port is running"], unit: .flag, rule: .okIsOne),
                        Col(id: "kerb", title: "Kerberos", names: ["AD: Kerberos — разных учёток с ошибкой за 10 минут"], unit: .count, rule: .above(warn: 5, bad: 20), chart: true),
                        Col(id: "ntlm", title: "NTLM", names: ["AD: NTLM — разных учёток с ошибкой за 10 минут"], unit: .count, rule: .above(warn: 5, bad: 20), chart: true),
                        Col(id: "krb", title: "krbtgt", names: ["AD: возраст пароля krbtgt, дней"], unit: .days, rule: .above(warn: 180, bad: 365)),
                        Col(id: "flags", title: "Опасные", names: ["AD: учётки с опасными флагами — число"], unit: .count, rule: .above(warn: 1, bad: 1))],
                 section: "Сервисы"),
    SystemScreen(id: "ksc", title: "Касперский KSC", subtitle: "Службы сервера администрирования",
                 icon: "shield", group: "/.*/", host: "/KASPER/",
                 cols: [Col(id: "adm", title: "Сервер", search: "State of service \"kladminserver\"", unit: .service, rule: .above(warn: 1, bad: 1)),
                        Col(id: "agt", title: "Агент", search: "State of service \"klnagent\"", unit: .service, rule: .above(warn: 1, bad: 1)),
                        Col(id: "kes", title: "KES", search: "State of service \"AVP.KES", unit: .service, rule: .above(warn: 1, bad: 1)),
                        Col(id: "web", title: "Веб-консоль", search: "State of service \"KSCWebConsole\"", unit: .service, rule: .above(warn: 1, bad: 1))],
                 section: "Сервисы"),
    SystemScreen(id: "ssl", title: "SSL-сертификаты", subtitle: "Сколько дней осталось",
                 icon: "lock.shield", group: "SSL Sites", host: "/.*/",
                 cols: [Col(id: "days", title: "Осталось", names: ["Оставшийся срок действия SSL сертификата"], unit: .days, rule: .below(warn: 30, bad: 14))],
                 section: "Сервисы", sortCol: "days"),
    SystemScreen(id: "updates", title: "Обновления Windows", subtitle: "Не установлено обновлений безопасности",
                 icon: "arrow.down.app", group: serverGroups, host: "/.*/",
                 cols: [Col(id: "sec", title: "Не установлено", names: ["Windows: не установлено обновлений безопасности"], unit: .count, rule: .above(warn: 1, bad: 5)),
                        Col(id: "age", title: "Дней без обновл.", names: ["Windows: дней с последней установки обновлений"], unit: .days, rule: .above(warn: 60, bad: 90))],
                 section: "Сервисы", sortCol: "sec", sortDesc: true),

    SystemScreen(id: "veeam", title: "Бэкапы Veeam", subtitle: "Серверы резервного копирования",
                 icon: "arrow.triangle.2.circlepath", group: "/.*/", host: "/.*/",
                 cols: [Col(id: "svc", title: "Служба", names: ["Veeam: служба Veeam Backup Service"], unit: .flag, rule: .okIsOne),
                        Col(id: "failed", title: "Ошибки 24ч", names: ["Veeam: Backups finished with Failed (24h)"], unit: .count, rule: .above(warn: 1, bad: 1)),
                        Col(id: "warn", title: "Предупр.", names: ["Veeam: Backups finished with Warning (24h)"], unit: .count, rule: .above(warn: 1, bad: 99)),
                        Col(id: "ok", title: "Успешно", names: ["Veeam: Backups finished with Success (24h)"], unit: .count)],
                 section: "Бэкапы"),
    SystemScreen(id: "agents", title: "Veeam Agent", subtitle: "Бэкапы ПК и ноутбуков",
                 icon: "desktopcomputer", group: "/.*/", host: "/.*/",
                 cols: [Col(id: "hours", title: "С бэкапа", names: ["Veeam Agent: часов с последнего успешного"], unit: .hours, rule: .above(warn: 48, bad: 96)),
                        Col(id: "fail7", title: "Ошибки 7д", names: ["Veeam Agent: проблемных за 7 дней"], unit: .count, rule: .above(warn: 1, bad: 3)),
                        Col(id: "ok7", title: "Успешно 7д", names: ["Veeam Agent: успешных за 7 дней"], unit: .count)],
                 section: "Бэкапы", sortCol: "hours", sortDesc: true)
]

// MARK: Данные

struct HostRow: Identifiable, Hashable {
    let id: String
    let name: String
    let values: [String: Double]
    let level: Level
    var maintenance = false

    static func == (a: HostRow, b: HostRow) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

@MainActor
final class SystemsModel: ObservableObject {
    @Published var rows: [String: [HostRow]] = [:]
    @Published var problems: [Problem] = []
    @Published var loading = false
    @Published var error: String?
    @Published var updated: Date?

    func summary(_ id: String) -> (bad: Int, warn: Int, total: Int)? {
        guard let r = rows[id] else { return nil }
        return (r.filter { $0.level == .bad }.count, r.filter { $0.level == .warn }.count, r.count)
    }

    func load(_ screen: SystemScreen, session: Session) async {
        do {
            let hosts = try await session.matchedHosts(group: screen.group, host: screen.host)
            guard !hosts.isEmpty else { rows[screen.id] = []; return }
            let ids = JSON.array(hosts.map { .string($0.id) })
            var values: [String: [String: Double]] = [:]
            for col in screen.cols {
                var params: [String: JSON] = [
                    "hostids": ids,
                    "output": .array(["name", "lastvalue", "hostid"].map { .string($0) }),
                    "webitems": .bool(true)
                ]
                if let s = col.search { params["search"] = .object(["name": .string(s)]) }
                else { params["filter"] = .object(["name": .array(col.names.map { .string($0) })]) }
                let items = try await session.zabbix("item.get", params)
                var per: [String: [Double]] = [:]
                for it in items {
                    guard let h = it["hostid"].string, let v = Double(it["lastvalue"].string ?? "") else { continue }
                    per[h, default: []].append(v)
                }
                for (h, vs) in per {
                    // диски и похожие показатели — худшее значение
                    let agg: Double
                    switch col.rule {
                    case .below: agg = vs.min() ?? 0
                    default: agg = vs.max() ?? 0
                    }
                    values[h, default: [:]][col.id] = agg
                }
            }
            let built: [HostRow] = hosts.compactMap { h in
                guard let v = values[h.id], !v.isEmpty else { return nil }
                var lvl = Level.none
                for c in screen.cols { lvl = max(lvl, c.level(v[c.id])) }
                if h.maintenance { lvl = .none }
                return HostRow(id: h.id, name: h.name, values: v, level: lvl, maintenance: h.maintenance)
            }
            rows[screen.id] = built.sorted { a, b in
                if a.level != b.level { return a.level > b.level }
                if let sc = screen.sortCol {
                    let va = a.values[sc], vb = b.values[sc]
                    if va != vb {
                        switch (va, vb) {
                        case let (x?, y?): return screen.sortDesc ? x > y : x < y
                        case (_?, nil): return true
                        default: return false
                        }
                    }
                }
                return a.name < b.name
            }
        } catch {
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }

    func loadAll(session: Session) async {
        loading = true
        defer { loading = false }
        if let p = try? await session.loadProblems() { problems = p }
        for s in systemScreens { await load(s, session: session) }
        updated = Date()
    }
}

// MARK: Вкладка «Системы»

struct SystemsView: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var pins: Pins
    @StateObject private var model = SystemsModel()
    @State private var path: NavigationPath = {
        var p = NavigationPath()
        if let s = Launch.system { p.append(s) }
        if let s = Launch.screen, ["compare", "vcal"].contains(s) { p.append(s) }
        if let e = Launch.explorer, let h = Demo.hosts.first(where: { $0.id == e }) {
            p.append(HostMini(id: h.id, name: h.name))
        }
        return p
    }()
    @State private var search = Launch.search ?? ""
    @State private var found: [HostMini] = []
    @State private var searching = false
    private let timer = Timer.publish(every: 90, on: .main, in: .common).autoconnect()
    private let sectionOrder = ["Инфраструктура", "Сервисы", "Бэкапы"]

    private var isSearching: Bool { search.trimmingCharacters(in: .whitespaces).count >= 2 }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let e = model.error { Text(e).font(.footnote).foregroundStyle(.orange) }
                if isSearching {
                    Section("Найденные хосты") {
                        if found.isEmpty && !searching { Text("Ничего не найдено").foregroundStyle(.secondary) }
                        ForEach(found) { h in
                            NavigationLink(value: h) {
                                HStack {
                                    Image(systemName: pins.contains(h) ? "star.fill" : "server.rack")
                                        .foregroundStyle(pins.contains(h) ? Color.yellow : Color.secondary)
                                    Text(h.name)
                                    if h.maintenance { Image(systemName: "wrench.and.screwdriver").foregroundStyle(.orange).font(.caption) }
                                }
                            }
                        }
                    }
                } else {
                    ForEach(sectionOrder, id: \.self) { sec in
                        Section(sec) {
                            ForEach(systemScreens.filter { $0.section == sec }) { s in
                                NavigationLink(value: s.id) { card(s) }
                            }
                            if sec == "Бэкапы" {
                                NavigationLink(value: "vcal") { simpleCard("calendar", "Календарь бэкапов", "Результаты Veeam по дням", color: Level.ok.color) }
                            }
                            if sec == "Инфраструктура" {
                                NavigationLink(value: "map") { simpleCard("map", "Карта филиалов", "Доступность на карте России", color: mapColor) }
                                NavigationLink(value: "compare") { simpleCard("chart.xyaxis.line", "Сравнение хостов", "Несколько хостов на одном графике", color: Level.ok.color) }
                                NavigationLink(value: "disks") { simpleCard("chart.line.uptrend.xyaxis", "Прогноз дисков", "Когда закончится место", color: Level.ok.color) }
                            }
                        }
                    }
                    if let u = model.updated {
                        Text("Обновлено \(u.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay { if model.loading && model.rows.isEmpty && !isSearching { ProgressView() } }
            .navigationTitle("Системы")
            .searchable(text: $search, prompt: "Найти любой хост")
            .navigationDestination(for: String.self) { id in
                switch id {
                case "map": BranchMapView(model: model, path: $path)
                case "disks": DisksView()
                case "compare": CompareView()
                case "vcal": VeeamCalendarView()
                default:
                    if let s = systemScreens.first(where: { $0.id == id }) {
                        SystemDetailView(screen: s, model: model, path: $path)
                    }
                }
            }
            .navigationDestination(for: HostRow.self) { HostDetailView(row: $0, model: model) }
            .navigationDestination(for: HostMini.self) { HostExplorerView(host: $0) }
            .refreshable { await model.loadAll(session: session) }
            .task { await model.loadAll(session: session) }
            .task(id: search) {
                guard isSearching else { found = []; return }
                searching = true
                try? await Task.sleep(nanoseconds: 350_000_000)
                if Task.isCancelled { return }
                found = (try? await session.searchHosts(search.trimmingCharacters(in: .whitespaces))) ?? []
                searching = false
            }
            .onReceive(timer) { _ in if !isSearching { Task { await model.loadAll(session: session) } } }
        }
    }

    private var mapColor: Color {
        let rows = model.rows["net"] ?? []
        if rows.contains(where: { $0.level == .bad }) { return Level.bad.color }
        if rows.contains(where: { $0.level == .warn }) { return Level.warn.color }
        return rows.isEmpty ? .gray : Level.ok.color
    }

    private func simpleCard(_ icon: String, _ title: String, _ sub: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(color).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func card(_ s: SystemScreen) -> some View {
        let sum = model.summary(s.id)
        let color: Color = sum == nil ? .gray : (sum!.bad > 0 ? Level.bad.color : (sum!.warn > 0 ? Level.warn.color : Level.ok.color))
        return HStack(spacing: 12) {
            Image(systemName: s.icon).font(.title3).foregroundStyle(color).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).font(.headline)
                if let sum {
                    if sum.total == 0 {
                        Text("нет данных").font(.caption).foregroundStyle(.secondary)
                    } else if sum.bad == 0 && sum.warn == 0 {
                        Text("Всё в порядке · \(sum.total) шт.").font(.caption).foregroundStyle(Level.ok.color)
                    } else {
                        Text(problemText(sum) + " · из \(sum.total)").font(.caption).foregroundStyle(color)
                    }
                } else {
                    Text(s.subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func problemText(_ s: (bad: Int, warn: Int, total: Int)) -> String {
        var parts: [String] = []
        if s.bad > 0 { parts.append("проблем: \(s.bad)") }
        if s.warn > 0 { parts.append("внимание: \(s.warn)") }
        return parts.joined(separator: ", ")
    }
}

// MARK: Список хостов экрана

struct SystemDetailView: View {
    @EnvironmentObject var session: Session
    let screen: SystemScreen
    @ObservedObject var model: SystemsModel
    @Binding var path: NavigationPath
    @State private var opened = false
    @State private var sparks: [String: [Pt]] = [:]

    var body: some View {
        let rows = model.rows[screen.id] ?? []
        List {
            if rows.isEmpty && !model.loading {
                Text("Нет данных по этому разделу").foregroundStyle(.secondary)
            }
            if let c = headlineCol, rows.filter({ $0.values[c.id] != nil }).count >= 2 {
                Section(c.title) { headlineChart(c, rows) }
            }
            ForEach(rows) { r in
                NavigationLink(value: r) { hostRow(r) }
            }
        }
        .navigationTitle(screen.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load(screen, session: session) }
        .task { await loadSparks() }
        .onChange(of: rows.count) { _ in autoOpen(rows) }
        .onAppear { autoOpen(rows) }
    }

    private static let headlines = ["servers": "cpu", "hyper": "mem", "net": "rtt", "storage": "free", "mail": "queue",
                                     "ad": "kerb", "ssl": "days", "updates": "age", "agents": "hours"]

    private var headlineCol: Col? {
        guard let id = Self.headlines[screen.id] else { return nil }
        return screen.cols.first { $0.id == id }
    }

    private func headlineChart(_ c: Col, _ rows: [HostRow]) -> some View {
        var ascending = false
        if case .below = c.rule { ascending = true }
        let items = rows.compactMap { r in r.values[c.id].map { (name: r.name, v: $0) } }
            .sorted { ascending ? $0.v < $1.v : $0.v > $1.v }
            .prefix(8)
        let data = Array(items)
        return Chart(data, id: \.name) { d in
            BarMark(x: .value("v", d.v), y: .value("h", d.name), width: .fixed(14))
                .foregroundStyle(c.level(d.v) == .none ? Level.ok.color : c.level(d.v).color)
                .cornerRadius(4)
                .annotation(position: .trailing, spacing: 4) {
                    Text(c.format(d.v)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
        }
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks { _ in AxisValueLabel().font(.caption2) } }
        .chartXScale(domain: 0...((data.map(\.v).max() ?? 1) * 1.25 + 0.001))
        .frame(height: CGFloat(data.count) * 30 + 8)
        .padding(.vertical, 4)
    }

    private func loadSparks() async {
        guard let c = screen.cols.first(where: { $0.chart }) else { return }
        let ser = (try? await session.hostSeries(host: screen.host, filter: c.historyFilter, range: .h6, group: screen.group)) ?? []
        var out: [String: [Pt]] = [:]
        for x in ser where out[x.host.isEmpty ? x.name : x.host] == nil { out[x.host.isEmpty ? x.name : x.host] = x.points }
        sparks = out
    }

    private func autoOpen(_ rows: [HostRow]) {
        guard !opened, let i = Launch.host, let r = rows[safe: i] else { return }
        opened = true
        path.append(r)
    }

    private func hostRow(_ r: HostRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(r.level.color).frame(width: 10, height: 10)
                Text(r.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                if r.maintenance {
                    Label("обслуживание", systemImage: "wrench.and.screwdriver").font(.caption2).foregroundStyle(.orange)
                }
                Spacer(minLength: 4)
                if let pts = sparks[r.name], pts.count > 2 {
                    Sparkline(points: pts, color: r.level == .none ? Level.ok.color : r.level.color).frame(width: 72, height: 24)
                }
            }
            HStack(alignment: .top, spacing: 0) {
                ForEach(screen.cols) { c in
                    let v = r.values[c.id]
                    VStack(spacing: 2) {
                        Text(c.format(v))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(v == nil ? Color.secondary : c.level(v).color)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        if c.unit == .percent, let v {
                            BarGauge(fraction: v / 100, color: c.level(v) == .none ? Level.ok.color : c.level(v).color)
                                .frame(width: 44)
                        }
                        Text(c.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: Карточка хоста

struct HostDetailView: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var router: Router
    @EnvironmentObject var pins: Pins
    let row: HostRow
    @ObservedObject var model: SystemsModel
    @State private var range: TimeRange = .h6
    @State private var charts: [String: [Series]] = [:]

    private var screen: SystemScreen? {
        systemScreens.first { s in model.rows[s.id]?.contains(row) == true }
    }

    private var hostProblems: [Problem] {
        model.problems.filter { $0.host == row.name }
            .sorted { ($0.severity, $0.clock) > ($1.severity, $1.clock) }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Circle().fill(row.level.color).frame(width: 12, height: 12)
                    Text(row.name).font(.headline)
                }
                if let s = screen {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: min(s.cols.count, 4)), spacing: 8) {
                        ForEach(s.cols) { c in
                            let v = row.values[c.id]
                            VStack(spacing: 3) {
                                if c.unit == .percent, let v {
                                    let col = c.level(v) == .none ? Level.ok.color : c.level(v).color
                                    ZStack {
                                        RingGauge(fraction: v / 100, color: col, lineWidth: 6)
                                        Text(c.format(v)).font(.caption.weight(.bold).monospacedDigit())
                                            .minimumScaleFactor(0.6).lineLimit(1)
                                    }
                                    .frame(width: 62, height: 62)
                                } else {
                                    Text(c.format(v)).font(.title3.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(v == nil ? Color.secondary : c.level(v).color)
                                        .minimumScaleFactor(0.6).lineLimit(1)
                                        .frame(height: 62)
                                }
                                Text(c.title).font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                NavigationLink(value: HostMini(id: row.id, name: row.name, maintenance: row.maintenance)) {
                    Label("Все показатели хоста", systemImage: "list.bullet.rectangle")
                }
            }

            HostNoteSection(hostId: row.id)

            Section("Проблемы на хосте") {
                if hostProblems.isEmpty {
                    Label("Активных проблем нет", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Level.ok.color).font(.subheadline)
                }
                ForEach(hostProblems) { p in
                    NavigationLink { ProblemDetailView(problem: p, all: model.problems) } label: { ProblemRow(p: p) }
                }
                if !hostProblems.isEmpty {
                    Button { router.showProblems(host: row.name) } label: {
                        Label("Открыть во вкладке «Проблемы»", systemImage: "list.bullet")
                    }
                }
            }

            if let s = screen, s.cols.contains(where: { $0.chart }) {
                Section {
                    Picker("Период", selection: $range) {
                        ForEach(TimeRange.allCases) { Text($0.shortLabel).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    ForEach(s.cols.filter { $0.chart }) { c in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(c.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            if let ser = charts[c.id] {
                                TimeSeriesChart(series: ser, unit: unitName(c), thresholds: thresholds(c)).frame(height: 150)
                            } else {
                                ProgressView().frame(maxWidth: .infinity, minHeight: 150)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: { Text("История") }
            }
        }
        .navigationTitle(row.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                let h = HostMini(id: row.id, name: row.name, maintenance: row.maintenance)
                Button { pins.toggle(h) } label: { Image(systemName: pins.contains(h) ? "star.fill" : "star") }
            }
        }
        .task(id: range) { await loadCharts() }
    }

    private func thresholds(_ c: Col) -> [(value: Double, color: Color)] {
        switch c.rule {
        case .above(let w, let b), .below(let w, let b): return [(w, Level.warn.color), (b, Level.bad.color)]
        default: return []
        }
    }

    private func unitName(_ c: Col) -> String? {
        switch c.unit {
        case .percent: return "percent"
        case .seconds: return "s"
        default: return nil
        }
    }

    private func loadCharts() async {
        guard let s = screen else { return }
        for c in s.cols where c.chart {
            let ser = (try? await session.hostSeries(host: row.name, filter: c.historyFilter, range: range)) ?? []
            charts[c.id] = ser
        }
    }
}

// MARK: График

struct TimeSeriesChart: View {
    let series: [Series]
    var unit: String?
    var thresholds: [(value: Double, color: Color)] = []
    var showLegend = true
    var markers: [Date] = []
    @EnvironmentObject private var sync: ChartSync
    @Environment(\.fsHeight) private var fs
    @State private var dragA: CGFloat?
    @State private var dragB: CGFloat?
    private var sel: Date? { sync.crosshair }

    private func inZoom(_ t: Date) -> Bool { sync.zoom.map { $0.contains(t) } ?? true }

    private func nearest(_ s: Series, to d: Date) -> Pt? {
        s.points.min { abs($0.t.timeIntervalSince(d)) < abs($1.t.timeIntervalSince(d)) }
    }

    private func color(_ i: Int) -> Color { seriesPalette[i % seriesPalette.count] }

    var body: some View {
        let shown = Array(series.filter { !$0.points.isEmpty }.prefix(8))
        if shown.isEmpty {
            Text("Нет данных за период").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            let vals = shown.flatMap { $0.points.map(\.v) }
            let lo = unit == "percent" ? 0 : (vals.min() ?? 0)
            let hi = unit == "percent" ? 100 : (vals.max() ?? 1)
            let pad = max((hi - lo) * 0.12, 0.5)
            let domain = unit == "percent" ? 0.0...100.0 : max(0, lo - pad)...(hi + pad)
            let allT = shown.flatMap { $0.points.map { $0.t } }
            let fullRange = (allT.min() ?? Date())...(allT.max() ?? Date())
            VStack(alignment: .leading, spacing: 6) {
                if fs != nil, sync.zoom != nil {
                    Button { sync.zoom = nil } label: { Label("Сбросить масштаб", systemImage: "arrow.counterclockwise") }.font(.caption)
                }
                readout(shown)
                Chart {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { idx, s in
                        ForEach(s.points.filter { inZoom($0.t) }) { p in
                            if shown.count <= 2 {
                                AreaMark(x: .value("t", p.t), yStart: .value("0", domain.lowerBound), yEnd: .value("v", p.v),
                                         series: .value("a", s.name))
                                    .foregroundStyle(LinearGradient(colors: [color(idx).opacity(0.35), color(idx).opacity(0.02)],
                                                                    startPoint: .top, endPoint: .bottom))
                                    .interpolationMethod(.monotone)
                            }
                            LineMark(x: .value("t", p.t), y: .value("v", p.v), series: .value("l", s.name))
                                .foregroundStyle(color(idx))
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                                .interpolationMethod(.monotone)
                        }
                    }
                    ForEach(markers.filter { $0 >= fullRange.lowerBound && $0 <= fullRange.upperBound }, id: \.self) { d in
                        RuleMark(x: .value("событие", d))
                            .foregroundStyle(Level.bad.color.opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [2, 3]))
                    }
                    ForEach(Array(thresholds.enumerated()), id: \.offset) { _, t in
                        if domain.contains(t.value) {
                            RuleMark(y: .value("порог", t.value))
                                .foregroundStyle(t.color.opacity(0.75))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        }
                    }
                    if let sel, sel >= fullRange.lowerBound, sel <= fullRange.upperBound {
                        RuleMark(x: .value("sel", sel)).foregroundStyle(Color.white.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        ForEach(Array(shown.enumerated()), id: \.element.id) { idx, s in
                            if let p = nearest(s, to: sel) {
                                PointMark(x: .value("t", p.t), y: .value("v", p.v)).foregroundStyle(color(idx)).symbolSize(60)
                            }
                        }
                    }
                }
                .chartYScale(domain: domain)
                .chartXScale(domain: sync.zoom ?? fullRange)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.white.opacity(0.12))
                        AxisValueLabel(format: .dateTime.hour().minute().locale(Locale(identifier: "ru_RU")))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { v in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.white.opacity(0.12))
                        AxisValueLabel {
                            if let d = v.as(Double.self) { Text(formatValue(d, unit: unit)).font(.caption2) }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            Rectangle().fill(Color.clear).contentShape(Rectangle())
                                .gesture(SpatialTapGesture().onEnded { e in
                                    let x = e.location.x - geo[proxy.plotAreaFrame].origin.x
                                    if let d: Date = proxy.value(atX: x) { sync.crosshair = (sync.crosshair == nil ? d : nil) }
                                })
                                .modifier(ZoomGestures(enabled: fs != nil, proxy: proxy, geo: geo, full: fullRange,
                                                       sync: sync, a: $dragA, b: $dragB))
                            if let a = dragA, let b = dragB {
                                Rectangle().fill(Color.orange.opacity(0.2))
                                    .frame(width: abs(b - a), height: geo.size.height)
                                    .offset(x: min(a, b)).allowsHitTesting(false)
                            }
                        }
                    }
                }
                if shown.count == 1, let one = shown.first { SeriesStats(series: one, unit: unit) }
                if showLegend && shown.count > 1 && shown.count <= 6 {
                    HStack(spacing: 10) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { idx, s in
                            HStack(spacing: 4) {
                                Circle().fill(color(idx)).frame(width: 7, height: 7)
                                Text(s.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func readout(_ shown: [Series]) -> some View {
        if let sel {
            HStack(spacing: 10) {
                Text(sel.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                ForEach(Array(shown.enumerated()), id: \.element.id) { idx, s in
                    if let p = nearest(s, to: sel) {
                        Text(formatValue(p.v, unit: unit)).font(.caption.weight(.bold)).foregroundStyle(color(idx))
                    }
                }
                Spacer()
            }
        } else {
            Text(fs != nil ? "Проведите по графику, чтобы приблизить интервал; щипок меняет масштаб" : "Нажмите на график, чтобы увидеть значение")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

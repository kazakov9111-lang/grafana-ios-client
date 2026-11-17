import SwiftUI
import MapKit

// MARK: Хосты, показатели, история, прогноз (запросы)

struct HostMini: Identifiable, Hashable {
    let id: String
    let name: String
    var maintenance = false
}

struct ItemInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let value: String
    let units: String
    var numeric: Double? { Double(value) }
}

struct HistEvent: Identifiable {
    let id: String
    let name: String
    let host: String
    let severity: Int
    let start: Date
    let end: Date?
    let acked: Bool
    var duration: TimeInterval { (end ?? Date()).timeIntervalSince(start) }
}

struct DiskFC: Identifiable {
    let id: String
    let host: String
    let hostId: String
    let disk: String
    let used: Double
    let perWeek: Double?
    let daysLeft: Double?
}

extension Session {
    func searchHosts(_ q: String) async throws -> [HostMini] {
        let r = try await zabbix("host.get", [
            "output": .array(["hostid", "name", "maintenance_status"].map { .string($0) }),
            "search": .object(["name": .string(q)]),
            "sortfield": .array([.string("name")]),
            "limit": .number(60)
        ])
        return r.compactMap { h in
            guard let id = h["hostid"].string, let n = h["name"].string else { return nil }
            return HostMini(id: id, name: n, maintenance: h["maintenance_status"].string == "1")
        }
    }

    func hostItems(_ hostId: String) async throws -> [ItemInfo] {
        let r = try await zabbix("item.get", [
            "hostids": .array([.string(hostId)]),
            "output": .array(["itemid", "name", "lastvalue", "units"].map { .string($0) }),
            "webitems": .bool(true),
            "sortfield": .array([.string("name")]),
            "limit": .number(1500)
        ])
        return r.map { ItemInfo(id: $0["itemid"].string ?? UUID().uuidString, name: $0["name"].string ?? "",
                                value: $0["lastvalue"].string ?? "", units: $0["units"].string ?? "") }
    }

    func hostNames(forTriggers ids: [String]) async throws -> [String: String] {
        var out: [String: String] = [:]
        let uniq = Array(Set(ids))
        for chunk in stride(from: 0, to: uniq.count, by: 100).map({ Array(uniq[$0..<min($0 + 100, uniq.count)]) }) {
            let trig = try await zabbix("trigger.get", [
                "triggerids": .array(chunk.map { .string($0) }),
                "output": .array([.string("triggerid")]),
                "selectHosts": .array([.string("name")])
            ])
            for t in trig { if let id = t["triggerid"].string { out[id] = t["hosts"][0]["name"].string ?? "" } }
        }
        return out
    }

    /// История проблем за период (с временем закрытия).
    func problemHistory(days: Int) async throws -> [HistEvent] {
        let from = Int(Date().timeIntervalSince1970) - days * 86400
        let ev = try await zabbix("event.get", [
            "source": .number(0), "object": .number(0), "value": .number(1),
            "time_from": .number(Double(from)),
            "output": .array(["eventid", "name", "clock", "r_eventid", "severity", "objectid", "acknowledged"].map { .string($0) }),
            "sortfield": .array([.string("eventid")]), "sortorder": .string("DESC"),
            "limit": .number(1000)
        ])
        var closed: [String: Double] = [:]
        let rids = ev.compactMap { $0["r_eventid"].string }.filter { $0 != "0" && !$0.isEmpty }
        for chunk in stride(from: 0, to: rids.count, by: 200).map({ Array(rids[$0..<min($0 + 200, rids.count)]) }) {
            let r = try await zabbix("event.get", [
                "eventids": .array(chunk.map { .string($0) }),
                "output": .array(["eventid", "clock"].map { .string($0) })
            ])
            for e in r { if let id = e["eventid"].string, let c = e["clock"].double { closed[id] = c } }
        }
        let hosts = try await hostNames(forTriggers: ev.compactMap { $0["objectid"].string })
        return ev.map { e in
            let rid = e["r_eventid"].string ?? "0"
            return HistEvent(id: e["eventid"].string ?? UUID().uuidString,
                             name: e["name"].string ?? "",
                             host: hosts[e["objectid"].string ?? ""] ?? "",
                             severity: e["severity"].int ?? 3,
                             start: Date(timeIntervalSince1970: e["clock"].double ?? 0),
                             end: closed[rid].map { Date(timeIntervalSince1970: $0) },
                             acked: e["acknowledged"].string == "1")
        }
    }

    /// Прогноз заполнения дисков по часовым трендам за 14 дней.
    func diskForecasts() async throws -> [DiskFC] {
        let hosts = try await matchedHosts(group: systemScreens[0].group, host: "/.*/")
        guard !hosts.isEmpty else { return [] }
        var hostName: [String: String] = [:]
        for h in hosts { hostName[h.id] = h.name }
        let items = try await zabbix("item.get", [
            "hostids": .array(hosts.map { .string($0.id) }),
            "output": .array(["itemid", "name", "lastvalue", "hostid"].map { .string($0) }),
            "search": .object(["name": .string("Space: Used, in %")]),
            "webitems": .bool(true)
        ])
        let now = Date().timeIntervalSince1970
        var trends: [String: [(Double, Double)]] = [:]
        let ids = items.compactMap { $0["itemid"].string }
        for chunk in stride(from: 0, to: ids.count, by: 120).map({ Array(ids[$0..<min($0 + 120, ids.count)]) }) {
            let tr = try await zabbix("trend.get", [
                "itemids": .array(chunk.map { .string($0) }),
                "time_from": .number(now - 14 * 86400),
                "output": .array(["itemid", "clock", "value_avg"].map { .string($0) })
            ])
            for t in tr {
                guard let id = t["itemid"].string, let c = t["clock"].double, let v = t["value_avg"].double else { continue }
                trends[id, default: []].append((c / 86400, v))
            }
        }
        var out: [DiskFC] = []
        for it in items {
            guard let id = it["itemid"].string, let hid = it["hostid"].string,
                  let used = Double(it["lastvalue"].string ?? "") else { continue }
            var perDay: Double?
            if let pts = trends[id], pts.count >= 24 {
                let n = Double(pts.count)
                let mx = pts.map { $0.0 }.reduce(0, +) / n, my = pts.map { $0.1 }.reduce(0, +) / n
                let cov = pts.reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
                let vr = pts.reduce(0) { $0 + ($1.0 - mx) * ($1.0 - mx) }
                if vr > 0 { perDay = cov / vr }
            }
            var days: Double?
            if let s = perDay, s > 0.02, used < 100 { days = (100 - used) / s }
            let raw = it["name"].string ?? ""
            var disk = raw
            if let a = raw.firstIndex(of: "["), let b = raw.firstIndex(of: "]") { disk = String(raw[raw.index(after: a)..<b]) }
            out.append(DiskFC(id: id, host: hostName[hid] ?? "", hostId: hid, disk: disk, used: used,
                              perWeek: perDay.map { $0 * 7 }, daysLeft: days))
        }
        return out.filter { $0.used >= 60 || ($0.daysLeft ?? 9999) < 365 }
            .sorted {
                switch ($0.daysLeft, $1.daysLeft) {
                case let (a?, b?): return a < b
                case (_?, nil): return true
                case (nil, _?): return false
                default: return $0.used > $1.used
                }
            }
    }

    /// Подтверждение проблемы. Если в настройках задан токен Zabbix API — напрямую в Zabbix,
    /// иначе через прокси Grafana (там нужны права записи у пользователя источника данных).
    func acknowledge(eventId: String, message: String) async throws {
        let params: [String: JSON] = [
            "eventids": .array([.string(eventId)]),
            "action": .number(message.isEmpty ? 2 : 6),
            "message": .string(message)
        ]
        if let direct = ZabbixDirect.config {
            try await ZabbixDirect.call(direct, method: "event.acknowledge", params: params)
        } else {
            _ = try await zabbix("event.acknowledge", params)
        }
    }
}

/// Прямой доступ к Zabbix API по токену (для подтверждения проблем).
enum ZabbixDirect {
    struct Config { let url: URL; let token: String }

    static var config: Config? {
        guard let raw = UserDefaults.standard.string(forKey: "zbxURL")?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              let token = Keychain.load(account: "zbxToken"), !token.isEmpty else { return nil }
        var s = raw
        if !s.hasPrefix("http") { s = "https://" + s }
        if !s.contains("api_jsonrpc.php") { s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api_jsonrpc.php" }
        guard let u = URL(string: s) else { return nil }
        return Config(url: u, token: token)
    }

    static func call(_ c: Config, method: String, params: [String: JSON]) async throws {
        var req = URLRequest(url: c.url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json-rpc", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer " + c.token, forHTTPHeaderField: "Authorization")
        let body: JSON = .object(["jsonrpc": .string("2.0"), "method": .string(method),
                                  "params": .object(params), "id": .number(1)])
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 { throw APIError(message: "Zabbix: HTTP \(h.statusCode)") }
        let r = try JSONDecoder().decode(JSON.self, from: data)
        if !r["error"].isNull {
            let e = r["error"]
            throw APIError(message: "Zabbix отказал: " + [e["message"].string, e["data"].string].compactMap { $0 }.joined(separator: ": "))
        }
    }
}

// MARK: Избранные хосты

final class Pins: ObservableObject {
    @Published private(set) var items: [HostMini] = []

    init() {
        let raw = UserDefaults.standard.stringArray(forKey: "pins") ?? []
        items = raw.compactMap { s in
            let p = s.split(separator: "|", maxSplits: 1).map(String.init)
            return p.count == 2 ? HostMini(id: p[0], name: p[1]) : nil
        }
    }

    func contains(_ h: HostMini) -> Bool { items.contains { $0.id == h.id } }

    func toggle(_ h: HostMini) {
        if let i = items.firstIndex(where: { $0.id == h.id }) { items.remove(at: i) } else { items.append(h) }
        UserDefaults.standard.set(items.map { "\($0.id)|\($0.name)" }, forKey: "pins")
    }
}

// MARK: Любой хост: все показатели

struct HostExplorerView: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var pins: Pins
    let host: HostMini
    @State private var items: [ItemInfo] = []
    @State private var problems: [Problem] = []
    @State private var query = ""
    @State private var error: String?
    @State private var loading = true

    private var shown: [ItemInfo] {
        query.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if host.maintenance {
                Label("Хост на обслуживании", systemImage: "wrench.and.screwdriver").foregroundStyle(.orange)
            }
            if !problems.isEmpty {
                Section("Проблемы") {
                    ForEach(problems) { p in
                        NavigationLink { ProblemDetailView(problem: p, all: problems) } label: { ProblemRow(p: p) }
                    }
                }
            }
            HostNoteSection(hostId: host.id)
            HostActionsSection(host: host)
            if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
            Section("Показатели (\(shown.count))") {
                ForEach(shown.prefix(400)) { it in
                    if it.numeric != nil {
                        NavigationLink { ItemChartView(host: host.name, item: it) } label: { itemRow(it) }
                    } else {
                        itemRow(it)
                    }
                }
            }
        }
        .overlay { if loading && items.isEmpty { ProgressView() } }
        .navigationTitle(host.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Найти показатель")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { pins.toggle(host) } label: {
                    Image(systemName: pins.contains(host) ? "star.fill" : "star")
                }
            }
        }
        .task {
            do {
                items = try await session.hostItems(host.id)
                problems = (try await session.loadProblems()).filter { $0.host == host.name }
            } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
            loading = false
        }
    }

    private func itemRow(_ it: ItemInfo) -> some View {
        HStack(alignment: .top) {
            Text(it.name).font(.footnote).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(display(it)).font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(it.numeric == nil ? Color.secondary : Color.primary)
                .multilineTextAlignment(.trailing).lineLimit(2).frame(maxWidth: 140, alignment: .trailing)
        }
    }

    private func display(_ it: ItemInfo) -> String {
        if let v = it.numeric {
            let unit = it.units == "%" ? "percent" : (it.units == "s" ? "s" : nil)
            let t = formatValue(v, unit: unit)
            return (unit == nil && !it.units.isEmpty) ? "\(t) \(it.units)" : t
        }
        return it.value.isEmpty ? "—" : it.value
    }
}

struct ItemChartView: View {
    @EnvironmentObject var session: Session
    let host: String
    let item: ItemInfo
    @State private var range: TimeRange = .h24
    @State private var series: [Series]?

    var body: some View {
        List {
            Section {
                Text(item.name).font(.subheadline)
                Picker("Период", selection: $range) {
                    ForEach(TimeRange.allCases) { Text($0.shortLabel).tag($0) }
                }
                .pickerStyle(.segmented)
                if let s = series {
                    TimeSeriesChart(series: s, unit: item.units == "%" ? "percent" : (item.units == "s" ? "s" : nil))
                        .frame(height: 220)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 220)
                }
            }
        }
        .navigationTitle(host)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: range) {
            series = nil
            series = (try? await session.hostSeries(host: host, filter: item.name, range: range)) ?? []
        }
    }
}

// MARK: История проблем

struct ProblemHistoryView: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var router: Router
    @State private var days = 7
    @State private var minSeverity = 3
    @State private var query = ""
    @State private var events: [HistEvent] = []
    @State private var loading = true
    @State private var error: String?

    private var shown: [HistEvent] {
        events.filter { e in
            e.severity >= minSeverity &&
            (query.isEmpty || e.name.localizedCaseInsensitiveContains(query) || e.host.localizedCaseInsensitiveContains(query))
        }
    }

    private var topHosts: [(name: String, count: Int)] {
        Dictionary(grouping: shown.filter { !$0.host.isEmpty }, by: { $0.host }).map { ($0.key, $0.value.count) }
            .filter { $0.1 >= 3 }.sorted { $0.1 > $1.1 }.prefix(5).map { $0 }
    }

    private var groups: [(day: Date, items: [HistEvent])] {
        let cal = Calendar.current
        let d = Dictionary(grouping: shown) { cal.startOfDay(for: $0.start) }
        return d.keys.sorted(by: >).map { ($0, d[$0]!.sorted { $0.start > $1.start }) }
    }

    private var repeaters: [(name: String, count: Int)] {
        Dictionary(grouping: shown, by: { $0.name }).map { ($0.key, $0.value.count) }
            .filter { $0.1 >= 3 }.sorted { $0.1 > $1.1 }.prefix(5).map { $0 }
    }

    var body: some View {
        List {
            Section {
                Picker("Период", selection: $days) {
                    Text("24 часа").tag(1); Text("7 дней").tag(7); Text("30 дней").tag(30); Text("90 дней").tag(90)
                }
                .pickerStyle(.segmented)
                Picker("Важность", selection: $minSeverity) {
                    Text("Предупр.+").tag(2); Text("Средняя+").tag(3); Text("Высокая+").tag(4)
                }
                .pickerStyle(.segmented)
                HStack {
                    stat("\(shown.count)", "всего")
                    stat("\(shown.filter { $0.end == nil }.count)", "ещё идут")
                    stat(avgText, "ср. длительность")
                }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
            if !repeaters.isEmpty {
                Section("Повторяются чаще всего") {
                    ForEach(repeaters, id: \.name) { r in
                        HStack {
                            Text(r.name).font(.footnote).lineLimit(2)
                            Spacer()
                            Text("\(r.count)×").font(.footnote.weight(.bold)).foregroundStyle(.orange)
                        }
                    }
                }
            }
            if !topHosts.isEmpty {
                Section("Чаще всего проблемы у хостов") {
                    ForEach(topHosts, id: \.name) { h in
                        HStack {
                            Text(h.name).font(.footnote).lineLimit(1)
                            Spacer()
                            Text("\(h.count)×").font(.footnote.weight(.bold)).foregroundStyle(.orange)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { query = h.name }
                    }
                }
            }
            ForEach(groups, id: \.day) { g in
                Section(dayTitle(g.day)) {
                    ForEach(g.items) { e in row(e) }
                }
            }
        }
        .overlay { if loading && events.isEmpty { ProgressView() } }
        .navigationTitle("История проблем")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Поиск по названию или хосту")
        .task(id: days) {
            loading = true
            do { events = try await session.problemHistory(days: days); error = nil }
            catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
            loading = false
        }
    }

    private var avgText: String {
        let closed = shown.compactMap { $0.end == nil ? nil : $0.duration }
        guard !closed.isEmpty else { return "—" }
        return duration(seconds: closed.reduce(0, +) / Double(closed.count))
    }

    private func stat(_ v: String, _ t: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.title3.weight(.bold)).minimumScaleFactor(0.6).lineLimit(1)
            Text(t).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func dayTitle(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM, EEE"
        return Calendar.current.isDateInToday(d) ? "Сегодня" : (Calendar.current.isDateInYesterday(d) ? "Вчера" : f.string(from: d))
    }

    private func row(_ e: HistEvent) -> some View {
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        return HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(sevColor(e.severity)).frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(e.name).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if !e.host.isEmpty { Text(e.host).lineLimit(1) }
                    Text("· " + tf.string(from: e.start) + (e.end.map { " → " + tf.string(from: $0) } ?? ""))
                    if let _ = e.end { Text("· " + duration(seconds: e.duration)) }
                    else { Text("· идёт " + duration(seconds: e.duration)).foregroundStyle(Level.bad.color) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { if !e.host.isEmpty { router.showProblems(host: e.host) } }
    }
}

// MARK: Прогноз дисков

struct DisksView: View {
    @EnvironmentObject var session: Session
    @State private var rows: [DiskFC] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
            Section {
                Text("Прогноз по линейному тренду за 14 дней. Показаны диски, заполненные больше чем на 60%, и те, что заполнятся в течение года.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(rows) { r in
                NavigationLink { HostExplorerView(host: HostMini(id: r.hostId, name: r.host)) } label: { row(r) }
            }
        }
        .overlay { if loading && rows.isEmpty { ProgressView() } }
        .navigationTitle("Прогноз дисков")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func color(_ r: DiskFC) -> Color {
        if let d = r.daysLeft { return d < 14 ? Level.bad.color : (d < 60 ? Level.warn.color : Level.ok.color) }
        return r.used >= 92 ? Level.bad.color : (r.used >= 85 ? Level.warn.color : Level.ok.color)
    }

    private func row(_ r: DiskFC) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(r.host) · \(r.disk)").font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                Text(String(format: "%.0f%%", r.used)).font(.subheadline.weight(.bold)).foregroundStyle(color(r))
            }
            ProgressView(value: min(r.used, 100), total: 100).tint(color(r))
            HStack {
                if let d = r.daysLeft {
                    Text("заполнится через \(Int(d)) дн.").foregroundStyle(color(r))
                } else {
                    Text("рост не обнаружен").foregroundStyle(.secondary)
                }
                Spacer()
                if let w = r.perWeek { Text(String(format: "%+.1f%% / нед", w)).foregroundStyle(.secondary) }
            }
            .font(.caption)
        }
        .padding(.vertical, 3)
    }

    private func load() async {
        loading = true
        do { rows = try await session.diskForecasts(); error = nil }
        catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
        loading = false
    }
}

// MARK: Карта филиалов


struct BranchPoint: Identifiable {
    let id: String
    let city: String
    let coord: CLLocationCoordinate2D
    let row: HostRow?
    var override: Level? = nil
    var overrideNote: String? = nil
}

/// Настоящая карта (MapKit) с цветными метками филиалов.
struct BranchMapRepresentable: UIViewRepresentable {
    let points: [BranchPoint]
    var onOpen: (String) -> Void

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: BranchMapRepresentable
        var signature = ""
        init(_ p: BranchMapRepresentable) { parent = p }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let a = annotation as? BranchAnnotation else { return nil }
            let v = (mapView.dequeueReusableAnnotationView(withIdentifier: "b") as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: a, reuseIdentifier: "b")
            v.annotation = a
            v.markerTintColor = UIColor(a.color)
            v.glyphImage = UIImage(systemName: a.level == .bad ? "xmark" : (a.level == .warn ? "exclamationmark" : "wifi"))
            v.displayPriority = a.level == .ok || a.level == .none ? .defaultLow : .required
            v.titleVisibility = .adaptive
            v.subtitleVisibility = .adaptive
            if let g = a.glyph, a.level != .bad { v.glyphImage = nil; v.glyphText = g } else { v.glyphText = nil }
            v.layer.sublayers?.filter { $0.name == "pulse" }.forEach { $0.removeFromSuperlayer() }
            if a.level == .bad { addPulse(to: v, color: UIColor(a.color)) }
            v.canShowCallout = a.hostId != nil
            if a.hostId != nil { v.rightCalloutAccessoryView = UIButton(type: .detailDisclosure) }
            return v
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
            if let a = view.annotation as? BranchAnnotation, let id = a.hostId { parent.onOpen(id) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let m = MKMapView()
        m.delegate = context.coordinator
        m.overrideUserInterfaceStyle = .dark
        m.mapType = .mutedStandard
        m.pointOfInterestFilter = .excludingAll
        m.showsCompass = false
        var rect = MKMapRect.null
        for b in Branches.list {
            let p = MKMapPoint(CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon))
            rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0.01, height: 0.01))
        }
        if rect.isNull { rect = MKMapRect(x: 0, y: 0, width: 1, height: 1) }
        m.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 50, left: 56, bottom: 40, right: 50), animated: false)
        return m
    }

    func updateUIView(_ m: MKMapView, context: Context) {
        context.coordinator.parent = self
        let sig = points.map { "\($0.id)\(($0.override ?? $0.row?.level)?.rawValue ?? -1)\($0.overrideNote ?? "")" }.joined()
        guard sig != context.coordinator.signature else { return }
        context.coordinator.signature = sig
        m.removeAnnotations(m.annotations)
        m.addAnnotations(points.map { p in
            let a = BranchAnnotation(title: p.city, coordinate: p.coord, level: p.override ?? p.row?.level ?? .none,
                             subtitle: p.overrideNote ?? p.row.map { r in
                                 r.values["ping"] == 0 ? "нет связи" : (r.values["rtt"].map { $0 < 1 ? String(format: "задержка %.0f мс", $0 * 1000) : "" } ?? "")
                             }, hostId: p.row?.id)
            if p.override == nil, let r = p.row, r.values["ping"] != 0, let rtt = r.values["rtt"], rtt < 1 {
                a.glyph = String(format: "%.0f", rtt * 1000)
            }
            return a
        })
    }
}

final class BranchAnnotation: NSObject, MKAnnotation {
    let title: String?
    let subtitle: String?
    let coordinate: CLLocationCoordinate2D
    let level: Level
    let hostId: String?
    var glyph: String?
    var color: Color { level == .none ? Color.gray : level.color }

    init(title: String, coordinate: CLLocationCoordinate2D, level: Level, subtitle: String?, hostId: String?) {
        self.title = title; self.coordinate = coordinate; self.level = level; self.subtitle = subtitle; self.hostId = hostId
    }
}

struct BranchMapView: View {
    @EnvironmentObject var session: Session
    @ObservedObject var model: SystemsModel
    @Binding var path: NavigationPath
    @ObservedObject private var store = BranchStore.shared
    @State private var replay = Launch.screen == "replay"
    @State private var hoursAgo: Double = Launch.screen == "replay" ? 9 : 0
    @State private var pings: [Series] = []
    @State private var loadingReplay = false

    private var replayTime: Date { Date().addingTimeInterval(-hoursAgo * 3600) }

    /// Состояние филиала в выбранный момент по истории ICMP ping.
    private func pastLevel(_ host: String) -> Level? {
        guard let s = pings.first(where: { $0.name == host || $0.host == host }), !s.points.isEmpty else { return nil }
        let t = replayTime
        guard let p = s.points.min(by: { abs($0.t.timeIntervalSince(t)) < abs($1.t.timeIntervalSince(t)) }),
              abs(p.t.timeIntervalSince(t)) < 1800 else { return Level.none }
        return p.v < 0.5 ? .bad : .ok
    }

    private var points: [BranchPoint] {
        let rows = model.rows["net"] ?? []
        return store.items.filter { $0.hasCoords }.map { b in
            var p = BranchPoint(id: b.host, city: b.city,
                                coord: CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon),
                                row: rows.first { $0.name == b.host })
            if replay, hoursAgo > 0, let l = pastLevel(b.host) {
                p.override = l
                p.overrideNote = l == .bad ? "в \(replayTime.formatted(date: .omitted, time: .shortened)) — нет связи" : "в \(replayTime.formatted(date: .omitted, time: .shortened)) — на связи"
            }
            return p
        }
    }

    private var downHours: [Int] {
        // часы суток, когда хоть один филиал был без связи — подсказка на шкале
        var out = Set<Int>()
        for s in pings { for p in s.points where p.v < 0.5 { out.insert(Int(Date().timeIntervalSince(p.t) / 3600)) } }
        return out.sorted()
    }

    private var replaySection: some View {
        Section {
            Toggle(isOn: $replay) { Label("Сутки на карте", systemImage: "clock.arrow.2.circlepath") }
            if replay {
                if loadingReplay { ProgressView() }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(hoursAgo == 0 ? "сейчас" : "\(replayTime.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(Locale(identifier: "ru_RU"))))")
                            .font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(.orange)
                        Spacer()
                        let down = points.filter { $0.override == .bad }.count
                        if hoursAgo > 0 { Text(down == 0 ? "все на связи" : "без связи: \(down)").font(.caption).foregroundStyle(down == 0 ? Color.secondary : Level.bad.color) }
                    }
                    Slider(value: $hoursAgo, in: 0...24, step: 0.25)
                        .environment(\.layoutDirection, .rightToLeft)
                    GeometryReader { g in
                        ForEach(downHours, id: \.self) { h in
                            Rectangle().fill(Level.bad.color.opacity(0.8))
                                .frame(width: max(2, g.size.width / 24 - 1), height: 4)
                                .offset(x: g.size.width - CGFloat(h + 1) * g.size.width / 24)
                        }
                    }
                    .frame(height: 4)
                    HStack { Text("24 ч назад"); Spacer(); Text("сейчас") }.font(.caption2).foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text(replay ? "Двигайте ползунок: метки показывают, кто был на связи в тот момент. Красные отрезки — когда были обрывы." : "Цифра в метке — задержка до филиала в мс.")
        }
        .task(id: replay) {
            guard replay, pings.isEmpty else { return }
            loadingReplay = true
            pings = (try? await session.hostSeries(host: "/.*/", filter: "ICMP ping", seconds: 86400, group: "Mikrotik", maxPoints: 300)) ?? []
            loadingReplay = false
        }
    }

    var body: some View {
        List {
            if store.items.isEmpty {
                Section {
                    Text("Список филиалов пуст. Откройте Настройки → Филиалы на карте и добавьте их вручную или одной кнопкой из Zabbix.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                BranchMapRepresentable(points: points) { id in
                    if let r = (model.rows["net"] ?? []).first(where: { $0.id == id }) { path.append(r) }
                }
                .frame(height: 380)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } footer: {
                Text("Нажмите на метку, затем на «i», чтобы открыть филиал.")
            }
            replaySection
            Section("Филиалы") {
                ForEach(points.sorted { ($0.row?.level.rawValue ?? 0, $1.city) > ($1.row?.level.rawValue ?? 0, $0.city) }) { p in
                    let color = p.row?.level.color ?? Level.none.color
                    if let r = p.row {
                        NavigationLink(value: r) { line(p, color, r) }
                    } else {
                        HStack { Circle().fill(color).frame(width: 10, height: 10); Text(p.city); Spacer(); Text("нет данных").foregroundStyle(.secondary) }
                            .font(.subheadline)
                    }
                }
            }
        }
        .navigationTitle("Карта филиалов")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func line(_ p: BranchPoint, _ color: Color, _ r: HostRow) -> some View {
        HStack {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(p.city).font(.subheadline)
            Spacer()
            Text(r.values["ping"] == 0 ? "нет связи" : (r.values["rtt"].map { $0 < 1 ? String(format: "%.0f мс", $0 * 1000) : "—" } ?? "—"))
                .font(.caption).foregroundStyle(r.level == .bad ? Level.bad.color : Color.secondary)
        }
    }
}

// MARK: Подтверждение проблемы

struct AckSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let problem: Problem
    var onDone: () -> Void
    @State private var message = ""
    @State private var busy = false
    @State private var error: String?
    @State private var confirm = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Проблема") { Text(problem.name).font(.subheadline) }
                Section("Комментарий (необязательно)") {
                    TextField("Например: взял в работу", text: $message, axis: .vertical).lineLimit(2...5)
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
                Section {
                    Button { confirm = true } label: {
                        HStack { Spacer(); if busy { ProgressView() } else { Text("Подтвердить").bold() }; Spacer() }
                    }
                    .disabled(busy)
                } footer: { Text("Действие запишется в Zabbix от имени учётной записи, под которой подключена Grafana.") }
            }
            .navigationTitle("Подтверждение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Отмена") { dismiss() } } }
            .confirmationDialog("Подтвердить эту проблему в Zabbix?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Да, подтвердить") {
                    busy = true; error = nil
                    Task {
                        do {
                            try await session.acknowledge(eventId: problem.id, message: message)
                            Annotations.shared.add(key: "panels", date: Date(), text: "Подтверждено: " + String(problem.name.prefix(40)))
                            onDone(); dismiss()
                        } catch { self.error = error.localizedDescription }
                        busy = false
                    }
                }
                Button("Отмена", role: .cancel) {}
            }
        }
    }
}

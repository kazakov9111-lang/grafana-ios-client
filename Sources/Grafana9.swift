import SwiftUI
import Charts
import AppIntents
import UserNotifications

// v2.8: отложить / закрыть / сменить важность, «как решали в прошлый раз», инструкция к триггеру,
// мини-графики в списке, группы одновременных проблем, кэш без связи, передача смены,
// уведомления о новых высоких, список плановых работ, сводка голосом.

// MARK: Запросы

struct PastAck: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let user: String
    let message: String
}

struct PastEvent: Identifiable, Hashable {
    let id: String
    let start: Date
    let end: Date?
    let acks: [PastAck]
}

struct TriggerInfo {
    var manualClose = false
    var url = ""
    var urlName = ""
}

struct ZMaintenance: Identifiable, Hashable {
    let id: String
    let name: String
    let since: Date
    let till: Date
    let hosts: [String]
    let note: String
    var mine: Bool { name.hasPrefix("Мобильное приложение:") }
}

/// Понятное объяснение отказа Zabbix на запись.
func explainZabbixWrite(_ e: Error) -> String {
    let m = e.localizedDescription
    if m.contains("No permissions to call") || m.contains("only available to Admin") {
        return "Zabbix разрешает это только пользователям типа «Администратор», а токен приложения — обычный «Пользователь». Сделать можно в веб-интерфейсе Zabbix под админом или выдать пользователю приложения роль администратора.\n\n" + m
    }
    if m.contains("cannot be closed manually") || m.contains("manual close") {
        return "У этого триггера в Zabbix запрещено ручное закрытие.\n\n" + m
    }
    if m.lowercased().contains("no permissions") {
        return "У пользователя Zabbix нет прав на это действие (нужны права записи на группу хоста).\n\n" + m
    }
    return m
}

extension Session {
    /// Любой метод Zabbix с произвольными параметрами (например, массив id для *.delete).
    func zabbixAny(_ method: String, _ params: JSON) async throws -> JSON {
        if !demo, let c = ZabbixDirect.config {
            var req = URLRequest(url: c.url, timeoutInterval: 30)
            req.httpMethod = "POST"
            req.setValue("application/json-rpc", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer " + c.token, forHTTPHeaderField: "Authorization")
            let body: JSON = .object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params, "id": .number(1)])
            req.httpBody = try JSONEncoder().encode(body)
            let (data, _) = try await URLSession.shared.data(for: req)
            let r = try JSONDecoder().decode(JSON.self, from: data)
            if !r["error"].isNull {
                let e = r["error"]
                throw APIError(message: "Zabbix отказал: " + [e["message"].string, e["data"].string].compactMap { $0 }.joined(separator: ": "))
            }
            return r["result"]
        }
        guard let ds = await zabbixDS() else { throw APIError(message: "Источник данных Zabbix не найден") }
        let body: JSON = .object(["datasourceId": .number(Double(ds.id)), "method": .string(method), "params": params])
        let r = try await request("/api/datasources/uid/\(ds.uid)/resources/zabbix-api", method: "POST", body: body)
        if !r["error"].isNull {
            let e = r["error"]
            throw APIError(message: "Zabbix отказал: " + [e["message"].string, e["data"].string].compactMap { $0 }.joined(separator: ": "))
        }
        return r["result"]
    }

    /// event.acknowledge с любым набором действий (битовая маска Zabbix 7).
    func eventAction(_ ids: [String], action: Int, message: String = "", extra: [String: JSON] = [:]) async throws {
        var p: [String: JSON] = ["eventids": .array(ids.map { .string($0) }), "action": .number(Double(action | (message.isEmpty ? 0 : 4)))]
        if !message.isEmpty { p["message"] = .string(message) }
        for (k, v) in extra { p[k] = v }
        _ = try await zabbixResult("event.acknowledge", p)
    }

    func suppress(_ p: Problem, until: Date) async throws {
        try await eventAction([p.id], action: 32, message: "Отложено до \(ruDate(until))",
                              extra: ["suppress_until": .number(until.timeIntervalSince1970.rounded())])
    }

    func closeProblem(_ p: Problem) async throws {
        try await eventAction([p.id], action: 1, message: "Закрыто с телефона")
    }

    func changeSeverity(_ p: Problem, to sev: Int) async throws {
        try await eventAction([p.id], action: 8, message: "Важность: \(sevName(p.severity)) → \(sevName(sev))",
                              extra: ["severity": .number(Double(sev))])
    }

    func triggerInfo(_ triggerId: String) async throws -> TriggerInfo {
        let r = try await zabbixResult("trigger.get", [
            "triggerids": .array([.string(triggerId)]),
            "output": .array(["manual_close", "url", "url_name"].map { .string($0) })
        ])
        let t = r.array.first ?? .null
        return TriggerInfo(manualClose: t["manual_close"].string == "1", url: t["url"].string ?? "", urlName: t["url_name"].string ?? "")
    }

    func pastOccurrences(_ p: Problem) async throws -> [PastEvent] {
        let from = Date().addingTimeInterval(-180 * 86400).timeIntervalSince1970.rounded()
        let ev = try await zabbixResult("event.get", [
            "objectids": .array([.string(p.triggerId)]),
            "source": .number(0), "object": .number(0), "value": .number(1),
            "time_from": .number(from),
            "output": .array(["eventid", "clock", "r_eventid"].map { .string($0) }),
            "selectAcknowledges": .array(["clock", "message", "userid"].map { .string($0) }),
            "sortfield": .array([.string("clock")]), "sortorder": .string("DESC"),
            "limit": .number(30)
        ]).array.filter { $0["eventid"].string != p.id }
        let rids = ev.compactMap { $0["r_eventid"].string }.filter { $0 != "0" && !$0.isEmpty }
        var closed: [String: Double] = [:]
        if !rids.isEmpty {
            let r = try await zabbixResult("event.get", ["eventids": .array(rids.map { .string($0) }),
                                                         "output": .array(["eventid", "clock"].map { .string($0) })])
            for e in r.array { if let id = e["eventid"].string, let c = e["clock"].double { closed[id] = c } }
        }
        // имена авторов: обычному пользователю Zabbix отдаёт только себя — остальных показываем без имени
        let uids = Array(Set(ev.flatMap { $0["acknowledges"].array.compactMap { $0["userid"].string } }))
        var names: [String: String] = [:]
        if !uids.isEmpty, let us = try? await zabbixResult("user.get", ["userids": .array(uids.map { .string($0) }),
                                                                         "output": .array(["userid", "username", "name", "surname"].map { .string($0) })]) {
            for u in us.array {
                let full = [u["name"].string, u["surname"].string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                if let id = u["userid"].string { names[id] = full.isEmpty ? (u["username"].string ?? "") : full }
            }
        }
        return ev.map { e in
            let acks = e["acknowledges"].array.compactMap { a -> PastAck? in
                let msg = (a["message"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                // служебные отметки Telegram-бота («tgmsg:…») — не решения
                guard !msg.isEmpty, !msg.hasPrefix("tgmsg:") else { return nil }
                return PastAck(date: Date(timeIntervalSince1970: a["clock"].double ?? 0),
                               user: names[a["userid"].string ?? ""] ?? "", message: msg)
            }
            return PastEvent(id: e["eventid"].string ?? UUID().uuidString,
                             start: Date(timeIntervalSince1970: e["clock"].double ?? 0),
                             end: closed[e["r_eventid"].string ?? ""].map { Date(timeIntervalSince1970: $0) },
                             acks: acks.sorted { $0.date < $1.date })
        }
    }

    /// Последние 6 часов метрики, из-за которой сработал триггер: triggerId → значения.
    func problemSparks(_ ps: [Problem]) async -> [String: [Double]] {
        let tids = Array(Set(ps.prefix(40).map(\.triggerId))).filter { !$0.isEmpty }
        guard !tids.isEmpty,
              let trig = try? await zabbixResult("trigger.get", [
                "triggerids": .array(tids.map { .string($0) }),
                "output": .array([.string("triggerid")]),
                "selectItems": .array(["itemid", "value_type"].map { .string($0) })
              ]) else { return [:] }
        var itemOf: [String: String] = [:]          // itemid → triggerid
        var byType: [String: [String]] = [:]       // value_type → itemids
        for t in trig.array {
            guard let tid = t["triggerid"].string,
                  let it = t["items"].array.first(where: { ["0", "3"].contains($0["value_type"].string ?? "") }),
                  let iid = it["itemid"].string else { continue }
            itemOf[iid] = tid
            byType[it["value_type"].string ?? "0", default: []].append(iid)
        }
        var out: [String: [(Double, Double)]] = [:]
        let from = Date().addingTimeInterval(-6 * 3600).timeIntervalSince1970.rounded()
        for (type, ids) in byType {
            guard let h = try? await zabbixResult("history.get", [
                "history": .number(Double(type) ?? 0), "itemids": .array(ids.map { .string($0) }),
                "time_from": .number(from), "output": .array(["itemid", "clock", "value"].map { .string($0) }),
                "sortfield": .array([.string("clock")]), "sortorder": .string("ASC"), "limit": .number(20000)
            ]) else { continue }
            for v in h.array {
                guard let iid = v["itemid"].string, let tid = itemOf[iid],
                      let c = v["clock"].double, let x = Double(v["value"].string ?? "") else { continue }
                out[tid, default: []].append((c, x))
            }
        }
        return out.mapValues { pts in
            let s = pts.sorted { $0.0 < $1.0 }.map(\.1)
            guard s.count > 40 else { return s }
            let step = Double(s.count) / 40
            return (0..<40).map { s[min(s.count - 1, Int(Double($0) * step))] }
        }
    }

    func activeMaintenances() async throws -> [ZMaintenance] {
        let r = try await zabbixResult("maintenance.get", [
            "output": .array(["maintenanceid", "name", "active_since", "active_till", "description"].map { .string($0) }),
            "selectHosts": .array([.string("name")])
        ])
        let now = Date()
        return r.array.compactMap { m -> ZMaintenance? in
            guard let id = m["maintenanceid"].string else { return nil }
            let till = Date(timeIntervalSince1970: m["active_till"].double ?? 0)
            guard till > now else { return nil }
            return ZMaintenance(id: id, name: m["name"].string ?? "", since: Date(timeIntervalSince1970: m["active_since"].double ?? 0),
                                till: till, hosts: m["hosts"].array.compactMap { $0["name"].string },
                                note: m["description"].string ?? "")
        }
        .sorted { $0.till < $1.till }
    }

    func deleteMaintenance(_ id: String) async throws {
        _ = try await zabbixAny("maintenance.delete", .array([.string(id)]))
    }
}

// MARK: Действия с проблемой

struct ProblemActionsSection: View {
    @EnvironmentObject var session: Session
    let problem: Problem
    @State private var info: TriggerInfo?
    @State private var pending: Pending?
    @State private var result: String?
    @State private var error: String?
    @State private var busy = false

    enum Pending: Identifiable {
        case suppress(Date, String), close, severity(Int)
        var id: String {
            switch self {
            case .suppress(let d, _): return "s\(d.timeIntervalSince1970)"
            case .close: return "c"
            case .severity(let s): return "v\(s)"
            }
        }
        var title: String {
            switch self {
            case .suppress(_, let label): return "Отложить проблему \(label)? Она пропадёт из списка и не будет уведомлять."
            case .close: return "Закрыть проблему в Zabbix вручную?"
            case .severity(let s): return "Сменить важность на «\(sevName(s))»?"
            }
        }
    }

    private static func nextMorning(weekday: Int? = nil) -> Date {
        let cal = Calendar.current
        var c = DateComponents(); c.hour = 9; c.minute = 0
        if let weekday { c.weekday = weekday }
        return cal.nextDate(after: Date(), matching: c, matchingPolicy: .nextTime) ?? Date().addingTimeInterval(86400)
    }

    var body: some View {
        Section {
            Menu {
                Button("На 1 час") { pending = .suppress(Date().addingTimeInterval(3600), "на 1 час") }
                Button("На 4 часа") { pending = .suppress(Date().addingTimeInterval(4 * 3600), "на 4 часа") }
                Button("До 9:00 утра") { pending = .suppress(Self.nextMorning(), "до 9:00") }
                Button("До понедельника 9:00") { pending = .suppress(Self.nextMorning(weekday: 2), "до понедельника") }
            } label: { Label("Отложить…", systemImage: "moon.zzz") }
            Menu {
                ForEach([5, 4, 3], id: \.self) { s in
                    if s != problem.severity { Button(sevName(s)) { pending = .severity(s) } }
                }
            } label: { Label("Сменить важность…", systemImage: "arrow.up.arrow.down") }
            if info?.manualClose == true {
                Button(role: .destructive) { pending = .close } label: { Label("Закрыть проблему", systemImage: "xmark.circle") }
            }
            if busy { ProgressView() }
            if let result { Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.footnote) }
            if let error { Text(error).foregroundStyle(.orange).font(.footnote) }
        } header: { Text("Действия в Zabbix") } footer: {
            Text(info?.manualClose == false ? "Закрыть вручную нельзя: в триггере не разрешено ручное закрытие." : "")
        }
        .confirmationDialog(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { p in
            Button("Да") { run(p) }
            Button("Отмена", role: .cancel) {}
        }
        .task { info = try? await session.triggerInfo(problem.triggerId) }
    }

    private func run(_ p: Pending) {
        busy = true; error = nil; result = nil
        Task {
            guard await FaceGate.ok("Изменить проблему в Zabbix") else { busy = false; return }
            do {
                switch p {
                case .suppress(let d, let label): try await session.suppress(problem, until: d); result = "Отложено \(label)"
                case .close: try await session.closeProblem(problem); result = "Проблема закрыта"
                case .severity(let s): try await session.changeSeverity(problem, to: s); result = "Важность: \(sevName(s))"
                }
                Haptics.success()
            } catch { self.error = explainZabbixWrite(error); Haptics.error() }
            busy = false
        }
    }
}

// MARK: Инструкция к триггеру (ссылка из Zabbix + своя заметка)

final class TriggerNoteStore: ObservableObject {
    static let shared = TriggerNoteStore()
    @Published var notes: [String: String] { didSet { UserDefaults.standard.set(notes, forKey: "triggerNotes") } }
    init() {
        notes = (UserDefaults.standard.dictionary(forKey: "triggerNotes") as? [String: String])
            ?? (Launch.demo ? ["100": "Проверить место на томе F: в DSM → Хранилище. Старые снимки удалять по регламенту, не трогать папку Veeam."] : [:])
    }
}

struct TriggerHelpSection: View {
    @EnvironmentObject var session: Session
    let problem: Problem
    @ObservedObject private var store = TriggerNoteStore.shared
    @State private var info: TriggerInfo?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            if let u = info?.url, !u.isEmpty, let url = URL(string: u) {
                Button { openURL(url) } label: {
                    Label(info?.urlName.isEmpty == false ? info!.urlName : "Инструкция из Zabbix", systemImage: "book")
                }
            }
            TextField("Своя заметка: что делать при этой проблеме", text: Binding(
                get: { store.notes[problem.triggerId] ?? "" },
                set: { store.notes[problem.triggerId] = $0.isEmpty ? nil : $0 }), axis: .vertical)
                .lineLimit(1...6)
        } header: { Text("Инструкция") } footer: {
            Text("Заметка привязана к триггеру: появится каждый раз, когда он сработает. Хранится только на этом телефоне.")
        }
        .task { info = try? await session.triggerInfo(problem.triggerId) }
    }
}

// MARK: Как решали в прошлый раз

struct PastOccurrencesSection: View {
    @EnvironmentObject var session: Session
    let problem: Problem
    @State private var items: [PastEvent]?
    @State private var all = false

    var body: some View {
        Section {
            if let items {
                if items.isEmpty {
                    Text("За 180 дней этот триггер больше не срабатывал.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    let withAcks = items.filter { !$0.acks.isEmpty }
                    let avg = items.compactMap { e in e.end.map { $0.timeIntervalSince(e.start) } }
                    Text("Срабатывал \(items.count) раз" + (avg.isEmpty ? "" : ", в среднем длился \(duration(seconds: avg.reduce(0, +) / Double(avg.count)))"))
                        .font(.footnote.weight(.semibold))
                    ForEach((all ? items : Array(items.prefix(5)))) { e in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(ruDate(e.start)).font(.caption.monospacedDigit())
                                Spacer()
                                Text(e.end.map { duration(seconds: $0.timeIntervalSince(e.start)) } ?? "не закрыта")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(e.acks) { a in
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "text.bubble").font(.caption2).foregroundStyle(.orange)
                                    Text(a.message).font(.caption)
                                    Spacer(minLength: 0)
                                    Text(a.user).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if items.count > 5 && !all { Button("Показать все (\(items.count))") { all = true }.font(.caption) }
                    if withAcks.isEmpty { Text("Комментариев при подтверждении не оставляли.").font(.caption2).foregroundStyle(.secondary) }
                }
            } else {
                ProgressView()
            }
        } header: { Text("Как решали в прошлый раз") }
        .task { items = (try? await session.pastOccurrences(problem)) ?? [] }
    }
}

// MARK: Мини-графики в списке проблем

@MainActor
final class ProblemSparkStore: ObservableObject {
    static let shared = ProblemSparkStore()
    @Published var data: [String: [Double]] = [:]
    private var loadedAt: Date?

    func refresh(_ session: Session, _ ps: [Problem]) async {
        if let l = loadedAt, Date().timeIntervalSince(l) < 240, ps.allSatisfy({ data[$0.triggerId] != nil }) { return }
        loadedAt = Date()
        let d = await session.problemSparks(ps)
        if !d.isEmpty { data.merge(d) { $1 } }
    }
}

struct ProblemSpark: View {
    let values: [Double]
    let color: Color

    var body: some View {
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                LineMark(x: .value("i", i), y: .value("v", v))
                    .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.4)).interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .chartYScale(domain: (lo - max((hi - lo) * 0.15, 0.01))...(hi + max((hi - lo) * 0.15, 0.01)))
        .frame(width: 54, height: 22)
    }
}

// MARK: Одновременные проблемы

/// Проблемы, начавшиеся в пределах 3 минут друг от друга, — одна группа.
func problemClusters(_ ps: [Problem]) -> [[Problem]] {
    let sorted = ps.sorted { $0.clock < $1.clock }
    var out: [[Problem]] = []
    for p in sorted {
        if let last = out.last?.last, p.clock.timeIntervalSince(last.clock) <= 180 { out[out.count - 1].append(p) }
        else { out.append([p]) }
    }
    return out.sorted { a, b in (a.count > 1 ? 1 : 0, a.first?.clock ?? Date()) > (b.count > 1 ? 1 : 0, b.first?.clock ?? Date()) }
}

// MARK: Кэш проблем без связи

enum ProblemCache {
    static func save(_ ps: [Problem]) {
        if let d = try? JSONEncoder().encode(ps) {
            UserDefaults.standard.set(d, forKey: "problemCache")
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "problemCacheAt")
        }
    }

    static func load() -> (problems: [Problem], at: Date)? {
        guard let d = UserDefaults.standard.data(forKey: "problemCache"),
              let ps = try? JSONDecoder().decode([Problem].self, from: d) else { return nil }
        return (ps, Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "problemCacheAt")))
    }
}

// MARK: Передача смены

struct ShiftReportView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var hours = 12
    @State private var text = ""
    @State private var loading = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Смена", selection: $hours) { Text("8 ч").tag(8); Text("12 ч").tag(12); Text("24 ч").tag(24) }
                        .pickerStyle(.segmented)
                }
                Section {
                    if loading { ProgressView() } else {
                        Text(text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    }
                } footer: { Text("Кнопка «Отправить» откроет меню «Поделиться» — выберите Telegram и нужный чат.") }
            }
            .navigationTitle("Передача смены")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: text) { Label("Отправить", systemImage: "paperplane") }.disabled(loading)
                }
            }
            .task(id: hours) { await build() }
        }
    }

    private func build() async {
        loading = true
        defer { loading = false }
        let since = Date().addingTimeInterval(-Double(hours) * 3600)
        let now = (try? await session.loadProblems()) ?? []
        let hist = ((try? await session.problemHistory(days: hours > 24 ? 2 : 1)) ?? []).filter { $0.start >= since }
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "dd.MM HH:mm"
        let hm = DateFormatter(); hm.dateFormat = "HH:mm"
        var s = "Передача смены \(f.string(from: since)) — \(f.string(from: Date()))\n"
        let closed = hist.filter { $0.end != nil }
        s += "\nЗа смену: проблем \(hist.count), закрыто \(closed.count), открыто сейчас \(now.count).\n"
        let crit = now.filter { $0.severity >= 4 }.sorted { ($0.severity, $1.clock) > ($1.severity, $0.clock) }
        if !crit.isEmpty {
            s += "\nОткрыто (высокие и выше):\n"
            for p in crit.prefix(15) {
                let who = ClaimStore.shared.claims[p.id] != nil ? " — взял в работу" : ""
                s += "• \(p.host.isEmpty ? "" : p.host + ": ")\(p.name), \(duration(seconds: Date().timeIntervalSince(p.clock)))\(p.acked ? ", подтверждена" : "")\(who)\n"
            }
        }
        let rest = now.count - crit.count
        if rest > 0 { s += "И ещё средних: \(rest).\n" }
        let fixed = closed.filter { $0.severity >= 4 }
        if !fixed.isEmpty {
            s += "\nРешено за смену:\n"
            for e in fixed.prefix(10) { s += "• \(hm.string(from: e.start)) \(e.host.isEmpty ? "" : e.host + ": ")\(e.name) (\(duration(seconds: e.duration)))\n" }
        }
        let inc = IncidentStore.shared.items.filter { $0.closed == nil || ($0.closed ?? .distantPast) >= since }
        if !inc.isEmpty {
            s += "\nАварии:\n"
            for i in inc { s += "• \(i.title) — \(i.closed == nil ? "идёт \(duration(seconds: i.elapsed))" : "закрыта") \n" }
        }
        let maint = (try? await session.activeMaintenances()) ?? []
        if !maint.isEmpty {
            s += "\nПлановые работы:\n"
            for m in maint.prefix(8) { s += "• \(m.hosts.joined(separator: ", ")) до \(f.string(from: m.till))\n" }
        }
        text = s
    }
}

// MARK: Плановые работы

struct MaintenanceListView: View {
    @State private var calMsg: String?
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var items: [ZMaintenance] = []
    @State private var loading = true
    @State private var error: String?
    @State private var ending: ZMaintenance?

    var body: some View {
        NavigationStack {
            List {
                if loading { ProgressView() }
                if !loading && items.isEmpty && error == nil {
                    Text("Сейчас плановых работ нет.").foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
                if let calMsg { Text(calMsg).font(.footnote).foregroundStyle(.secondary) }
                ForEach(items) { m in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: m.since <= Date() ? "wrench.and.screwdriver.fill" : "calendar.badge.clock")
                                .foregroundStyle(m.since <= Date() ? Color.orange : Color.secondary)
                            Text(m.hosts.isEmpty ? m.name : m.hosts.joined(separator: ", ")).font(.subheadline.weight(.semibold)).lineLimit(2)
                        }
                        Text(m.since <= Date() ? "идут, до \(ruDate(m.till)) (ещё \(duration(seconds: m.till.timeIntervalSinceNow)))"
                                               : "с \(ruDate(m.since)) до \(ruDate(m.till))")
                            .font(.caption).foregroundStyle(.secondary)
                        if !m.note.isEmpty { Text(m.note).font(.caption) }
                        HStack {
                            if m.mine && m.since <= Date() {
                                Button("Завершить досрочно") { ending = m }.font(.caption).buttonStyle(.bordered).tint(.orange)
                            }
                            if m.till > Date() {
                                Button { Task { calMsg = await CalendarExport.add(m) } } label: { Label("В Календарь", systemImage: "calendar.badge.plus") }
                                    .font(.caption).buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle("Плановые работы")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } } }
            .refreshable { await load() }
            .task { await load() }
            .confirmationDialog("Завершить обслуживание сейчас? Проблемы хоста снова будут уведомлять.",
                                isPresented: Binding(get: { ending != nil }, set: { if !$0 { ending = nil } }),
                                titleVisibility: .visible, presenting: ending) { m in
                Button("Завершить", role: .destructive) {
                    Task {
                        guard await FaceGate.ok("Завершить обслуживание в Zabbix") else { return }
                        do { try await session.deleteMaintenance(m.id); Haptics.success(); await load() }
                        catch { self.error = explainZabbixWrite(error); Haptics.error() }
                    }
                }
                Button("Отмена", role: .cancel) {}
            }
        }
    }

    private func load() async {
        loading = true
        do { items = try await session.activeMaintenances(); error = nil } catch { self.error = explainZabbixWrite(error) }
        loading = false
    }
}

// MARK: Уведомления о новых высоких проблемах (без push, через фоновое обновление)

enum Notifier {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "notifyNew") as? Bool ?? true }

    /// Запомнить, что уже видели (при открытии приложения), чтобы не уведомлять о старом.
    static func remember(_ ps: [Problem]) {
        UserDefaults.standard.set(ps.map(\.id), forKey: "notifiedEvents")
    }

    static func notifyNew(_ ps: [Problem]) {
        let known = UserDefaults.standard.stringArray(forKey: "notifiedEvents")
        defer { remember(ps) }
        guard enabled, let known else { return }
        let fresh = ps.filter { $0.severity >= 4 && !$0.acked && !known.contains($0.id) }
        for p in fresh.prefix(5) {
            let c = UNMutableNotificationContent()
            c.title = "\(sevName(p.severity)): \(p.host.isEmpty ? "Zabbix" : p.host)"
            c.body = p.name
            c.sound = .default
            c.threadIdentifier = "problems"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "p\(p.id)", content: c, trigger: nil))
        }
        if fresh.count > 5 {
            let c = UNMutableNotificationContent()
            c.title = "Ещё \(fresh.count - 5) новых проблем"
            c.body = "Откройте приложение, чтобы посмотреть"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "more\(Date().timeIntervalSince1970)", content: c, trigger: nil))
        }
    }
}

// MARK: Сводка голосом (Siri, кнопка действия)

struct SummaryIntent: AppIntent {
    static var title: LocalizedStringResource = "Сводка мониторинга"
    static var description = IntentDescription("Зачитывает число проблем, самую серьёзную и филиалы без связи. Можно повесить на кнопку действия.")

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let s = await readySession() else {
            return .result(dialog: IntentDialog(stringLiteral: "Приложение Grafana не подключено. Откройте его и войдите."))
        }
        let p = try await s.loadProblems()
        if p.isEmpty { return .result(dialog: IntentDialog(stringLiteral: "Всё спокойно: активных проблем нет.")) }
        let high = p.filter { $0.severity >= 4 }
        let down = p.filter { $0.name.contains("ICMP") }.map { branchName($0.host) }
        var t = "Активных проблем \(p.count)"
        t += high.isEmpty ? ", высоких нет." : ", из них высоких \(high.count)."
        if let w = p.max(by: { ($0.severity, $1.clock) < ($1.severity, $0.clock) }) {
            t += " Самая серьёзная: \(w.name)" + (w.host.isEmpty ? "." : " на \(w.host).")
        }
        t += down.isEmpty ? " Все филиалы на связи." : " Без связи: \(Set(down).sorted().joined(separator: ", "))."
        let fresh = p.filter { Date().timeIntervalSince($0.clock) < 3600 }.count
        if fresh > 0 { t += " За последний час новых: \(fresh)." }
        return .result(dialog: IntentDialog(stringLiteral: t))
    }
}

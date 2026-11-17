import SwiftUI

// Бэкенд Zabbix-плагина Grafana не умеет «не-метрические» запросы (проблемы, текст),
// поэтому их делаем через прокси Zabbix API, как это делает веб-интерфейс.

struct Problem: Identifiable, Hashable, Codable {
    let id: String
    let triggerId: String
    let name: String
    let severity: Int
    let clock: Date
    let acked: Bool
    let host: String
}

extension Session {
    func zabbixDS() async -> (uid: String, id: Int)? {
        let list = await allDatasources()
        guard let d = list.first(where: { ($0["type"].string ?? "").contains("zabbix") }),
              let uid = d["uid"].string, let id = d["id"].int else { return nil }
        return (uid, id)
    }

    func zabbix(_ method: String, _ params: [String: JSON]) async throws -> [JSON] {
        guard let ds = await zabbixDS() else { throw APIError(message: "Источник данных Zabbix не найден") }
        let body: JSON = .object([
            "datasourceId": .number(Double(ds.id)),
            "method": .string(method),
            "params": .object(params)
        ])
        let r = try await request("/api/datasources/uid/\(ds.uid)/resources/zabbix-api", method: "POST", body: body)
        if !r["error"].isNull {
            let e = r["error"]
            let msg = [e["message"].string, e["data"].string].compactMap { $0 }.joined(separator: ": ")
            throw APIError(message: "Zabbix отказал: " + (msg.isEmpty ? "неизвестная ошибка" : msg))
        }
        return r["result"].array
    }

    /// Текущие проблемы Zabbix: средняя важность и выше.
    func loadProblems() async throws -> [Problem] {
        let probs = try await zabbix("problem.get", [
            "output": .array(["eventid", "name", "severity", "clock", "acknowledged", "objectid"].map { .string($0) }),
            "severities": .array([3, 4, 5].map { .number(Double($0)) }),
            "recent": .bool(false),
            "suppressed": .bool(false),
            "sortfield": .array([.string("eventid")]),
            "sortorder": .string("DESC"),
            "limit": .number(500)
        ])
        // имена хостов лежат у триггеров
        var hostByTrigger: [String: String] = [:]
        let ids = Array(Set(probs.compactMap { $0["objectid"].string }))
        for chunk in stride(from: 0, to: ids.count, by: 100).map({ Array(ids[$0..<min($0 + 100, ids.count)]) }) {
            let trig = try await zabbix("trigger.get", [
                "triggerids": .array(chunk.map { .string($0) }),
                "output": .array([.string("triggerid")]),
                "selectHosts": .array([.string("name")])
            ])
            for t in trig {
                if let id = t["triggerid"].string { hostByTrigger[id] = t["hosts"][0]["name"].string ?? "" }
            }
        }
        return probs.map { p in
            Problem(id: p["eventid"].string ?? UUID().uuidString,
                    triggerId: p["objectid"].string ?? "",
                    name: p["name"].string ?? "",
                    severity: p["severity"].int ?? 3,
                    clock: Date(timeIntervalSince1970: p["clock"].double ?? 0),
                    acked: p["acknowledged"].string == "1",
                    host: hostByTrigger[p["objectid"].string ?? ""] ?? "")
        }
    }

    /// Хосты, подходящие под фильтры группы и имени.
    func matchedHosts(group gf: String, host hf: String) async throws -> [HostMini] {
        if zbxGroups == nil {
            zbxGroups = try await zabbix("hostgroup.get", ["output": .array(["groupid", "name"].map { .string($0) })])
        }
        let groups = (zbxGroups ?? []).filter { zbxMatch(gf, $0["name"].string ?? "") }
        guard !groups.isEmpty else { return [] }
        let hosts = try await zabbix("host.get", [
            "groupids": .array(groups.map { $0["groupid"] }),
            "output": .array(["hostid", "name", "maintenance_status"].map { .string($0) })
        ])
        var seen = Set<String>()
        var out: [HostMini] = []
        for h in hosts {
            guard let id = h["hostid"].string, let name = h["name"].string,
                  zbxMatch(hf, name), seen.insert(id).inserted else { continue }
            out.append(HostMini(id: id, name: name, maintenance: h["maintenance_status"].string == "1"))
        }
        return out
    }

    /// История показателя одного хоста (через бэкенд Zabbix-плагина Grafana).
    func hostSeries(host: String, filter: String, range: TimeRange, group: String = "/.*/") async throws -> [Series] {
        try await hostSeries(host: host, filter: filter, seconds: range.seconds, group: group, maxPoints: 200)
    }

    func hostSeries(host: String, filter: String, seconds: Double, group: String = "/.*/", maxPoints: Int = 200, to: Date = Date()) async throws -> [Series] {
        guard let ds = await zabbixDS() else { return [] }
        let nowMs = to.timeIntervalSince1970 * 1000
        let target: JSON = .object([
            "refId": .string("A"), "queryType": .string("0"),
            "group": .object(["filter": .string(group)]),
            "host": .object(["filter": .string(host)]),
            "item": .object(["filter": .string(filter)]),
            "application": .object(["filter": .string("")]),
            "itemTag": .object(["filter": .string("")]),
            "functions": .array([]), "options": .object([:]),
            "datasource": .object(["uid": .string(ds.uid), "type": .string("alexanderzobnin-zabbix-datasource")]),
            "intervalMs": .number(Double(max(1000, Int(seconds * 1000 / Double(maxPoints))))),
            "maxDataPoints": .number(Double(maxPoints))
        ])
        let body: JSON = .object([
            "queries": .array([target]),
            "from": .string(String(Int(nowMs - seconds * 1000))),
            "to": .string(String(Int(nowMs)))
        ])
        await gate.acquire()
        do {
            let resp = try await request("/api/ds/query", method: "POST", body: body)
            await gate.release()
            return DashboardModel.parse(resp, wantTable: false).series
        } catch {
            await gate.release()
            throw error
        }
    }

    /// Подробности триггера: описание, комментарий, связанные показатели.
    func loadProblemDetail(_ p: Problem) async throws -> ProblemDetail {
        let r = try await zabbix("trigger.get", [
            "triggerids": .array([.string(p.triggerId)]),
            "output": .array(["description", "comments", "url"].map { .string($0) }),
            "selectItems": .array(["name", "lastvalue", "units"].map { .string($0) }),
            "expandDescription": .bool(true)
        ])
        let t = r.first ?? .null
        let items: [(String, String)] = t["items"].array.map { it in
            let v = it["lastvalue"].string ?? ""
            let text = Double(v).map { formatValue($0, unit: it["units"].string == "%" ? "percent" : nil) } ?? v
            return (it["name"].string ?? "", text)
        }
        return ProblemDetail(comments: t["comments"].string ?? "", url: t["url"].string ?? "", items: items)
    }

    /// Текстовый запрос панели (queryType 2): последние значения элементов данных.
    func textSeries(target t: JSON, ref: String) async throws -> [Series] {
        let gf = t["group"]["filter"].string ?? ""
        let hf = t["host"]["filter"].string ?? ""
        let itf = t["item"]["filter"].string ?? ""

        if zbxGroups == nil {
            zbxGroups = try await zabbix("hostgroup.get", ["output": .array(["groupid", "name"].map { .string($0) })])
        }
        let groups = (zbxGroups ?? []).filter { zbxMatch(gf, $0["name"].string ?? "") }
        guard !groups.isEmpty else { return [] }
        let hosts = try await zabbix("host.get", [
            "groupids": .array(groups.map { $0["groupid"] }),
            "output": .array(["hostid", "name"].map { .string($0) })
        ]).filter { zbxMatch(hf, $0["name"].string ?? "") }
        guard !hosts.isEmpty else { return [] }
        var hostName: [String: String] = [:]
        for h in hosts { if let id = h["hostid"].string { hostName[id] = h["name"].string ?? "" } }

        let items = try await zabbix("item.get", [
            "hostids": .array(hosts.map { $0["hostid"] }),
            "output": .array(["itemid", "name", "lastvalue", "units", "hostid"].map { .string($0) }),
            "webitems": .bool(true),
            "limit": .number(2000)
        ]).filter { zbxMatch(itf, $0["name"].string ?? "") }

        let multi = Set(items.compactMap { $0["name"].string }).count > 1
        return items.enumerated().map { i, it in
            let host = hostName[it["hostid"].string ?? ""] ?? ""
            let name = multi ? "\(host): \(it["name"].string ?? "")" : host
            let v = it["lastvalue"].string ?? ""
            return Series(id: i, name: name, points: [], text: v, unit: it["units"].string, ref: ref)
        }
    }
}

/// Фильтры Zabbix-плагина: пусто — любое, /regex/ — регулярное выражение, иначе точное имя.
func zbxMatch(_ filter: String, _ value: String) -> Bool {
    let f = filter.trimmingCharacters(in: .whitespaces)
    if f.isEmpty { return true }
    if f.hasPrefix("/"), let end = f.lastIndex(of: "/"), end > f.startIndex {
        let body = String(f[f.index(after: f.startIndex)..<end])
        let flags = f[f.index(after: end)...]
        let opts: NSRegularExpression.Options = flags.contains("i") ? [.caseInsensitive] : []
        if let re = try? NSRegularExpression(pattern: body, options: opts) {
            return re.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }
    }
    return f == value
}

struct ProblemDetail {
    var comments: String
    var url: String
    var items: [(String, String)]
}

// MARK: Навигация между вкладками

final class Router: ObservableObject {
    @Published var tab = Launch.tab
    @Published var problemSearch = ""

    func showProblems(host: String) {
        problemSearch = host
        tab = 1
    }
}

func sevColor(_ s: Int) -> Color {
    switch s {
    case 5: return Color(hex: "E02F44")
    case 4: return Color(hex: "F2495C")
    default: return Color(hex: "FF9830")
    }
}

func sevName(_ s: Int) -> String {
    switch s {
    case 5: return "Чрезвычайная"
    case 4: return "Высокая"
    default: return "Средняя"
    }
}

// MARK: Вкладка «Проблемы»

struct ProblemsView: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var router: Router
    @State private var problems: [Problem] = []
    @AppStorage("minSeverity") private var minSeverity = 3
    @State private var quickAck: Problem?
    @State private var ackTarget: Problem?
    @State private var ackError: String?
    @State private var error: String?
    @State private var loading = true
    @State private var updated: Date?
    @State private var path: [Problem] = []
    @State private var showHistory = Launch.history
    @State private var selecting = Launch.screen == "bulk"
    @State private var selected: Set<String> = []
    @State private var bulkConfirm = false
    @State private var bulkBusy = false
    @State private var showIncidents = Launch.screen == "incidents"
    @State private var openIncident: UUID?
    @State private var confetti = Launch.screen == "confetti"
    @State private var seenCritical: Set<String>?
    @AppStorage("groupProblems") private var grouped = Launch.screen == "grouped"
    @AppStorage("foldDeps") private var foldDeps = true
    @State private var showShift = Launch.screen == "shift"
    @State private var showMorning = Launch.screen == "morning"
    @State private var showDuty = Launch.screen == "duty-roster"
    @State private var rootCause: ProblemGroup?
    @State private var showMaint = Launch.screen == "maint"
    @State private var cachedAt: Date?
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    @ViewBuilder private func row(_ p: Problem) -> some View {
        if selecting {
            Button {
                if selected.contains(p.id) { selected.remove(p.id) } else { selected.insert(p.id) }
                Haptics.tap()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selected.contains(p.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(selected.contains(p.id) ? Color.orange : Color.secondary)
                        .contentTransition(.symbolEffect(.replace))
                    ProblemRow(p: p)
                }
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: p) { ProblemRow(p: p) }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !p.acked {
                        Button { quickAck = p } label: { Label("Принять", systemImage: "checkmark.circle.fill") }.tint(.green)
                        Button { ackTarget = p } label: { Label("Коммент.", systemImage: "text.bubble.fill") }.tint(.blue)
                    }
                }
        }
    }

    private var bulkBar: some View {
        HStack(spacing: 10) {
            Button { bulkConfirm = true } label: {
                Label(bulkBusy ? "Подтверждаю…" : "Подтвердить \(selected.count)", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.green)
            .disabled(selected.isEmpty || bulkBusy)
            Button {
                let i = IncidentStore.shared.create(from: problems.filter { selected.contains($0.id) })
                selected = []; selecting = false
                openIncident = i.id; showIncidents = true
                Haptics.success()
            } label: {
                Label("В аварию", systemImage: "flame.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).tint(.orange)
            .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var shown: [Problem] {
        let q = router.problemSearch.trimmingCharacters(in: .whitespaces)
        return problems
            .filter { $0.severity >= minSeverity }
            .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || $0.host.localizedCaseInsensitiveContains(q) }
            .sorted { ($0.severity, $0.clock) > ($1.severity, $1.clock) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Picker("Важность", selection: $minSeverity) {
                        Text("Средняя+").tag(3)
                        Text("Высокая+").tag(4)
                        Text("Чрезвыч.").tag(5)
                    }
                    .pickerStyle(.segmented)
                    HStack(spacing: 14) {
                        ForEach([5, 4, 3], id: \.self) { s in
                            let n = problems.filter { $0.severity == s }.count
                            HStack(spacing: 4) {
                                Circle().fill(sevColor(s)).frame(width: 9, height: 9)
                                Text("\(n)").font(.subheadline.weight(.semibold))
                            }
                        }
                        Spacer()
                        if let u = updated {
                            Text(u, style: .time).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.orange).font(.footnote) }
                if shown.isEmpty && !loading && error == nil {
                    Label("Проблем нет", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        .symbolEffect(.bounce, value: shown.isEmpty)
                }
                QueueBanner()
                if let c = cachedAt {
                    Label("Нет связи — показаны данные от \(c.formatted(.dateTime.day().month().hour().minute().locale(Locale(identifier: "ru_RU"))))",
                          systemImage: "wifi.slash")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if grouped {
                    ForEach(problemClusters(shown), id: \.first!.id) { g in
                        if g.count > 1 {
                            Section {
                                ForEach(g) { p in row(p) }
                            } header: {
                                HStack {
                                    Label("Одновременно · \(g.first!.clock.formatted(date: .omitted, time: .shortened)) · \(g.count)",
                                          systemImage: "link")
                                    Spacer()
                                    Button("Почему?") { rootCause = ProblemGroup(id: g.first!.id, problems: g) }.font(.caption.weight(.semibold))
                                }
                            }
                        } else {
                            ForEach(g) { p in row(p) }
                        }
                    }
                } else if foldDeps {
                    let f = DepStore.shared.fold(shown)
                    ForEach(f.visible) { p in
                        row(p)
                        if let kids = f.children[p.host], p.id == f.visible.first(where: { $0.host == p.host })?.id {
                            DisclosureGroup("+\(kids.count) на зависимых хостах") {
                                ForEach(kids) { k in row(k) }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ForEach(shown) { p in row(p) }
                }
            }
            .safeAreaInset(edge: .bottom) { if selecting { bulkBar } }
            .overlay { if confetti { ConfettiView(seconds: Launch.screen == "confetti" ? 600 : 3.5) { confetti = false } } }
            .confirmationDialog("Подтвердить \(selected.count) проблем(ы) в Zabbix?", isPresented: $bulkConfirm, titleVisibility: .visible) {
                Button("Да, подтвердить все") {
                    bulkBusy = true
                    Task {
                        guard await FaceGate.ok("Подтвердить \(selected.count) проблем(ы)") else { bulkBusy = false; return }
                        do {
                            try await session.acknowledgeMany(Array(selected), message: "")
                            Haptics.success(); selected = []; selecting = false
                            await load()
                        } catch { Haptics.error(); ackError = error.localizedDescription }
                        bulkBusy = false
                    }
                }
                Button("Отмена", role: .cancel) {}
            }
            .confirmationDialog("Подтвердить проблему?", isPresented: Binding(get: { quickAck != nil }, set: { if !$0 { quickAck = nil } }),
                                titleVisibility: .visible, presenting: quickAck) { p in
                Button("Да, подтвердить") {
                    Task {
                        do {
                            try await session.acknowledge(eventId: p.id, message: "")
                            AppMetrics.ackDelay(p.clock)
                            Haptics.success(); await load()
                        } catch {
                            if ActionQueue.isOffline(error) {
                                ActionQueue.shared.add(QueuedAction(eventId: p.id, action: 6, title: p.name)); Haptics.tap()
                            } else { Haptics.error(); ackError = error.localizedDescription }
                        }
                    }
                }
                Button("Отмена", role: .cancel) {}
            } message: { p in Text(p.name) }
            .sheet(item: $ackTarget) { p in
                AckSheet(problem: p) { Haptics.success(); Task { await load() } }
            }
            .alert("Не удалось подтвердить", isPresented: Binding(get: { ackError != nil }, set: { if !$0 { ackError = nil } })) {
                Button("OK") {}
            } message: { Text(ackError ?? "") }
            .overlay { if loading && problems.isEmpty { ProgressView() } }
            .navigationTitle("Проблемы")
            .navigationDestination(for: Problem.self) { p in
                ProblemDetailView(problem: p, all: problems)
            }
            .searchable(text: $router.problemSearch, prompt: "Хост или текст проблемы")
            .navigationDestination(isPresented: $showHistory) { ProblemHistoryView() }
            .navigationDestination(isPresented: $showIncidents) { incidentsDest }
            .onChange(of: showIncidents) { v in if !v { openIncident = nil } }
            .sheet(isPresented: $showShift) { ShiftReportView() }
            .sheet(isPresented: $showMorning) { MorningView() }
            .sheet(isPresented: $showDuty) { DutyRosterView() }
            .sheet(item: $rootCause) { g in RootCauseView(problems: g.problems) }
            .sheet(isPresented: $showMaint) { MaintenanceListView() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selecting ? "Готово" : "Выбрать") {
                        withAnimation { selecting.toggle(); if !selecting { selected = [] } }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { openIncident = nil; showIncidents = true } label: { Label("Аварии", systemImage: "flame") }
                        Button { showMorning = true } label: { Label("Утренняя сводка", systemImage: "sunrise") }
                        Button { showDuty = true } label: { Label("График дежурств", systemImage: "calendar.badge.clock") }
                        Button { showShift = true } label: { Label("Передача смены", systemImage: "person.2.badge.gearshape") }
                        Button { showMaint = true } label: { Label("Плановые работы", systemImage: "wrench.and.screwdriver") }
                        Toggle(isOn: $grouped) { Label("Группировать одновременные", systemImage: "link") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .onReceive(timer) { _ in Task { await load() } }
        }
    }

    @ViewBuilder private var incidentsDest: some View {
        if let id = openIncident { IncidentDetailView(id: id) } else { IncidentsView() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        await ActionQueue.shared.flush(session)
        do {
            let before = problems.count
            let fresh = try await session.loadProblems()
            let crit = Set(fresh.filter { $0.severity >= 5 }.map(\.id))
            if let seen = seenCritical, !crit.subtracting(seen).isEmpty { Haptics.critical() }
            seenCritical = crit
            if updated != nil && before > 0 && fresh.isEmpty { confetti = true; Haptics.success() }
            withAnimation(.snappy) { problems = fresh }
            updated = Date()
            error = nil
            LiveStatus.update(problems: fresh)
            cachedAt = nil
            ProblemCache.save(fresh)
            Notifier.remember(fresh)
            Task { await ProblemSparkStore.shared.refresh(session, fresh) }
            if let i = Launch.problem, path.isEmpty, let p = shown[safe: i] { path = [p] }
            if Launch.screen == "bulk", selected.isEmpty { selected = Set(shown.prefix(2).map(\.id)) }
        } catch {
            if !(error is CancellationError) {
                self.error = error.localizedDescription
                if problems.isEmpty, let c = ProblemCache.load() { problems = c.problems; cachedAt = c.at }
            }
        }
    }
}

struct ProblemRow: View {
    let p: Problem
    @ObservedObject private var sparks = ProblemSparkStore.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(sevColor(p.severity)).frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(p.name).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if !p.host.isEmpty { Text(p.host).lineLimit(1) }
                    Text("· " + sevName(p.severity))
                    Text("· " + duration(seconds: Date().timeIntervalSince(p.clock)))
                    if p.acked { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    if ClaimStore.shared.claims[p.id] != nil { Image(systemName: "person.fill.checkmark").foregroundStyle(.orange) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            if let v = sparks.data[p.triggerId], v.count > 2 {
                Spacer(minLength: 4)
                ProblemSpark(values: v, color: sevColor(p.severity)).padding(.top, 4)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: Карточка проблемы

struct ProblemDetailView: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var router: Router
    let problem: Problem
    let all: [Problem]
    @State private var detail: ProblemDetail?
    @State private var error: String?
    @State private var acked: Bool
    @State private var showAck = false

    init(problem: Problem, all: [Problem]) {
        self.problem = problem
        self.all = all
        _acked = State(initialValue: problem.acked)
    }

    private var sameHost: [Problem] {
        all.filter { $0.host == problem.host && $0.id != problem.id }
    }

    private var shareText: String {
        "\(sevName(problem.severity)): \(problem.name)\nХост: \(problem.host.isEmpty ? "—" : problem.host)\nС \(ruDate(problem.clock)) (\(duration(seconds: Date().timeIntervalSince(problem.clock))))"
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    Text(sevName(problem.severity).uppercased())
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(sevColor(problem.severity), in: Capsule())
                    if acked { Label("Подтверждена", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
                }
                Text(problem.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                LabeledContent("Хост", value: problem.host.isEmpty ? "—" : problem.host)
                LabeledContent("Началась", value: ruDate(problem.clock))
                LabeledContent("Длится", value: duration(seconds: Date().timeIntervalSince(problem.clock)))
            }
            if !acked {
                Section {
                    Button { showAck = true } label: { Label("Подтвердить проблему…", systemImage: "checkmark.circle") }
                }
            }
            ClaimSection(problem: problem)
            ProblemActionsSection(problem: problem)
            if !problem.host.isEmpty { ProblemContextSection(problem: problem) }
            if let c = detail?.comments, !c.isEmpty {
                Section("Что делать") { Text(c).font(.subheadline) }
            }
            RunbookSection(problem: problem)
            TriggerHelpSection(problem: problem)
            PastOccurrencesSection(problem: problem)
            if let items = detail?.items, !items.isEmpty {
                Section("Показатели триггера") {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                        LabeledContent(it.0, value: it.1).font(.subheadline)
                    }
                }
            }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(.orange) } }
            if !problem.host.isEmpty {
                Section {
                    Button {
                        router.showProblems(host: problem.host)
                    } label: {
                        Label("Все проблемы хоста (\(sameHost.count + 1))", systemImage: "list.bullet")
                    }
                }
            }
            if !sameHost.isEmpty {
                Section("Другие проблемы на этом хосте") {
                    ForEach(sameHost) { ProblemRow(p: $0) }
                }
            }
        }
        .navigationTitle("Проблема")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareLink(item: shareText) { Label("Текстом", systemImage: "text.alignleft") }
                    Button { shareProblemImage(problem) } label: { Label("Карточкой (картинка)", systemImage: "photo") }
                } label: { Image(systemName: "square.and.arrow.up") }
            }
        }
        .sheet(isPresented: $showAck) {
            AckSheet(problem: problem) { acked = true }
        }
        .task {
            do { detail = try await session.loadProblemDetail(problem) }
            catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
        }
    }
}

func ruDate(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "ru_RU")
    f.dateFormat = "d MMM yyyy, HH:mm"
    return f.string(from: d)
}

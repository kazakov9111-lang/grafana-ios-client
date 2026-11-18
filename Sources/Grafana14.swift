import SwiftUI
import Charts
import UserNotifications

// v3.1: фильтры и пресеты проблем, исключённые группы, «просмотрено», свайпы,
// панель действий и хронология проблемы, интерактивные графики, переменные и панели
// дашбордов Grafana, нативные дашборды Zabbix.

// MARK: Фильтры проблем

enum ProblemChip: String, CaseIterable, Identifiable {
    case all, high, unacked, mine, unseen
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Все"
        case .high: return "Высокие"
        case .unacked: return "Неподтверждённые"
        case .mine: return "Мои"
        case .unseen: return "Новые"
        }
    }
}

struct FilterPreset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var chip: String
    var tag: String?
    var minSeverity: Int
}

final class ProblemFilters: ObservableObject {
    static let shared = ProblemFilters()

    @Published var chip: String { didSet { UserDefaults.standard.set(chip, forKey: "pfChip") } }
    @Published var tag: String? { didSet { UserDefaults.standard.set(tag, forKey: "pfTag") } }
    @Published var presets: [FilterPreset] { didSet { save("pfPresets", presets) } }
    @Published var excluded: Set<String> { didSet { UserDefaults.standard.set(Array(excluded), forKey: "excludedGroups") } }
    @Published var seen: Set<String> { didSet { UserDefaults.standard.set(Array(seen), forKey: "seenEvents") } }

    init() {
        let d = UserDefaults.standard
        chip = d.string(forKey: "pfChip") ?? "all"
        tag = d.string(forKey: "pfTag")
        excluded = Set(d.stringArray(forKey: "excludedGroups") ?? (Launch.demo ? ["Workstations"] : []))
        seen = Set(d.stringArray(forKey: "seenEvents") ?? [])
        if let data = d.data(forKey: "pfPresets"), let v = try? JSONDecoder().decode([FilterPreset].self, from: data) {
            presets = v
        } else {
            presets = Launch.demo ? [FilterPreset(name: "Ночное дежурство", chip: "unacked", tag: nil, minSeverity: 4),
                                     FilterPreset(name: "Только почта", chip: "all", tag: "service:mail", minSeverity: 3)] : []
        }
        if Launch.demo, Launch.screen == "chips" { chip = "unacked"; tag = nil }
    }

    private func save<T: Encodable>(_ key: String, _ v: T) {
        if let data = try? JSONEncoder().encode(v) { UserDefaults.standard.set(data, forKey: key) }
    }

    // статичные версии — для фонового обновления, бейджа и уведомлений
    static var excludedGroups: Set<String> { Set(UserDefaults.standard.stringArray(forKey: "excludedGroups") ?? []) }
    static var seenIds: Set<String> { Set(UserDefaults.standard.stringArray(forKey: "seenEvents") ?? []) }

    static func isExcluded(_ p: Problem, _ ex: Set<String> = excludedGroups) -> Bool {
        guard !ex.isEmpty, let g = p.groups, !g.isEmpty else { return false }
        // исключаем, только если ВСЕ группы хоста исключены — иначе легко потерять важное
        return g.allSatisfy { ex.contains($0) }
    }

    static func visible(_ ps: [Problem]) -> [Problem] {
        let ex = excludedGroups
        return ex.isEmpty ? ps : ps.filter { !isExcluded($0, ex) }
    }

    func matches(_ p: Problem, chip c: String? = nil) -> Bool {
        switch c ?? chip {
        case "high": if p.severity < 4 { return false }
        case "unacked": if p.acked { return false }
        case "mine": if ClaimStore.shared.claims[p.id] == nil { return false }
        case "unseen": if seen.contains(p.id) { return false }
        default: break
        }
        return true
    }

    func apply(_ ps: [Problem]) -> [Problem] {
        ps.filter { p in
            if Self.isExcluded(p, excluded) { return false }
            if !matches(p) { return false }
            if let tag, !(p.tags ?? []).contains(tag) { return false }
            return true
        }
    }

    /// Первый запуск — всё текущее считаем просмотренным; дальше чистим закрытые.
    func sync(_ ps: [Problem]) {
        let ids = Set(ps.map(\.id))
        if UserDefaults.standard.object(forKey: "seenEvents") == nil {
            seen = Launch.demo ? Set(ps.sorted { $0.clock > $1.clock }.dropFirst(2).map(\.id)) : ids
        } else {
            let kept = seen.intersection(ids)
            if kept.count != seen.count { seen = kept }
        }
    }

    func markSeen(_ id: String) { if !seen.contains(id) { seen.insert(id) } }
    func toggleSeen(_ id: String) { if seen.contains(id) { seen.remove(id) } else { seen.insert(id) } }
}

struct ProblemChipsBar: View {
    @ObservedObject private var f = ProblemFilters.shared
    @AppStorage("minSeverity") private var minSeverity = 3
    let problems: [Problem]
    @State private var naming = false
    @State private var newName = ""

    private var tags: [String] {
        var c: [String: Int] = [:]
        for p in problems { for t in p.tags ?? [] { c[t, default: 0] += 1 } }
        return c.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(8).map(\.key)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ProblemChip.allCases) { c in
                    let n = problems.filter { !ProblemFilters.isExcluded($0, f.excluded) && $0.severity >= minSeverity && f.matches($0, chip: c.rawValue) }.count
                    chip(c.title + (c == .all ? "" : " \(n)"), on: f.chip == c.rawValue) {
                        withAnimation(.snappy) { f.chip = c.rawValue }
                    }
                }
                if !tags.isEmpty { Divider().frame(height: 18) }
                ForEach(tags, id: \.self) { t in
                    chip("#" + t, on: f.tag == t, tint: .blue) { withAnimation(.snappy) { f.tag = f.tag == t ? nil : t } }
                }
                Menu {
                    ForEach(f.presets) { p in
                        Button {
                            withAnimation(.snappy) { f.chip = p.chip; f.tag = p.tag; minSeverity = p.minSeverity }
                        } label: { Label(p.name, systemImage: "line.3.horizontal.decrease.circle") }
                    }
                    Button { newName = ""; naming = true } label: { Label("Сохранить текущий фильтр…", systemImage: "plus") }
                    if !f.presets.isEmpty {
                        Menu("Удалить пресет") {
                            ForEach(f.presets) { p in Button(p.name, role: .destructive) { f.presets.removeAll { $0.id == p.id } } }
                        }
                    }
                    if f.chip != "all" || f.tag != nil {
                        Button("Сбросить фильтр") { withAnimation { f.chip = "all"; f.tag = nil } }
                    }
                } label: {
                    Image(systemName: "bookmark.circle").font(.title3)
                }
            }
            .padding(.vertical, 2)
        }
        .alert("Название пресета", isPresented: $naming) {
            TextField("Например, «Ночью»", text: $newName)
            Button("Сохранить") {
                let n = newName.trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty else { return }
                f.presets.append(FilterPreset(name: n, chip: f.chip, tag: f.tag, minSeverity: minSeverity))
                Haptics.success()
            }
            Button("Отмена", role: .cancel) {}
        } message: { Text("Сохранятся чип, тег и минимальная важность.") }
    }

    private func chip(_ title: String, on: Bool, tint: Color = .orange, action: @escaping () -> Void) -> some View {
        Button(action: { action(); Haptics.tap() }) {
            Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(on ? tint.opacity(0.85) : Color.secondary.opacity(0.15), in: Capsule())
                .foregroundStyle(on ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: Исключённые группы

struct ExcludedGroupsView: View {
    @EnvironmentObject var session: Session
    @ObservedObject private var f = ProblemFilters.shared
    @State private var groups: [String] = []
    @State private var q = ""

    var body: some View {
        List {
            Section {
                ForEach(groups.filter { q.isEmpty || $0.localizedCaseInsensitiveContains(q) }, id: \.self) { g in
                    Toggle(isOn: Binding(get: { f.excluded.contains(g) },
                                         set: { if $0 { f.excluded.insert(g) } else { f.excluded.remove(g) } })) {
                        Text(g)
                    }
                }
                if groups.isEmpty { ProgressView() }
            } footer: {
                Text("Проблемы хостов, у которых ВСЕ группы отмечены, не показываются в списке, не приходят уведомлениями и не входят в число на иконке. Например, рабочие станции или тестовый стенд.")
            }
        }
        .searchable(text: $q, prompt: "Группа")
        .navigationTitle("Исключённые группы")
        .task {
            let r = (try? await session.zabbixResult("hostgroup.get", ["output": .array([.string("name")]), "with_hosts": .bool(true)]))?.array ?? []
            groups = r.compactMap { $0["name"].string }.sorted()
        }
    }
}

// MARK: Свайпы

enum SwipeAct: String, CaseIterable, Identifiable {
    case none, ack, comment, snooze, seen
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Ничего"
        case .ack: return "Подтвердить"
        case .comment: return "Комментарий"
        case .snooze: return "Отложить на час"
        case .seen: return "Просмотрено"
        }
    }
}

struct SwipeSettingsView: View {
    @AppStorage("swipeLeft") private var left = "ack"
    @AppStorage("swipeLeft2") private var left2 = "comment"
    @AppStorage("swipeRight") private var right = "seen"
    @AppStorage("badgeMode") private var badgeMode = "unacked"

    var body: some View {
        Form {
            Section("Свайп влево (справа налево)") {
                Picker("Первое действие", selection: $left) { ForEach(SwipeAct.allCases) { Text($0.title).tag($0.rawValue) } }
                Picker("Второе действие", selection: $left2) { ForEach(SwipeAct.allCases) { Text($0.title).tag($0.rawValue) } }
            }
            Section("Свайп вправо (слева направо)") {
                Picker("Действие", selection: $right) { ForEach(SwipeAct.allCases) { Text($0.title).tag($0.rawValue) } }
            }
            Section {
                Picker("Число на иконке", selection: $badgeMode) {
                    Text("Неподтверждённые").tag("unacked")
                    Text("Непросмотренные").tag("unseen")
                }
            } footer: {
                Text("«Просмотрено» — личная отметка на этом телефоне, в Zabbix ничего не меняется. Синяя точка в списке — проблема, которую вы ещё не открывали.")
            }
        }
        .navigationTitle("Свайпы и значок")
    }
}

// MARK: Панель действий внизу карточки проблемы

struct ProblemActionBar: View {
    @EnvironmentObject var session: Session
    let problem: Problem
    let acked: Bool
    let onAck: () -> Void
    @State private var confirmClose = false
    @State private var note: String?
    @State private var busy = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onAck) {
                VStack(spacing: 2) { Image(systemName: "checkmark.circle.fill"); Text(acked ? "Принята" : "Подтвердить").font(.caption2) }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.green).disabled(acked || busy)
            Menu {
                Button("На 1 час") { snooze(3600, "на 1 час") }
                Button("На 4 часа") { snooze(4 * 3600, "на 4 часа") }
                Button("До завтра 9:00") {
                    var c = DateComponents(); c.hour = 9
                    let d = Calendar.current.nextDate(after: Date(), matching: c, matchingPolicy: .nextTime) ?? Date().addingTimeInterval(86400)
                    snooze(d.timeIntervalSinceNow, "до утра")
                }
            } label: {
                VStack(spacing: 2) { Image(systemName: "moon.zzz.fill"); Text("Отложить").font(.caption2) }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).tint(.indigo).disabled(busy)
            Button(role: .destructive) { confirmClose = true } label: {
                VStack(spacing: 2) { Image(systemName: "xmark.octagon.fill"); Text("Закрыть").font(.caption2) }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).tint(.red).disabled(busy)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            if let note {
                Text(note).font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule()).offset(y: -34)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .confirmationDialog("Закрыть проблему в Zabbix вручную?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Закрыть", role: .destructive) {
                run("Закрыта") { try await session.closeProblem(problem) }
            }
            Button("Отмена", role: .cancel) {}
        } message: { Text("Сработает, только если в триггере разрешено ручное закрытие.") }
    }

    private func snooze(_ sec: TimeInterval, _ label: String) {
        run("Отложено \(label)") { try await session.suppress(problem, until: Date().addingTimeInterval(sec)) }
    }

    private func run(_ ok: String, _ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            guard await FaceGate.ok(ok) else { return }
            do { try await work(); Haptics.success(); show(ok) }
            catch { Haptics.error(); show(error.localizedDescription) }
        }
    }

    private func show(_ s: String) {
        withAnimation { note = s }
        Task { try? await Task.sleep(nanoseconds: 2_500_000_000); withAnimation { note = nil } }
    }
}

// MARK: Хронология: кто что сделал и кому ушли уведомления

struct PTimelineEntry: Identifiable {
    let id: String
    let date: Date
    let icon: String
    let color: Color
    let title: String
    let detail: String
}

struct ProblemTimelineSection: View {
    @EnvironmentObject var session: Session
    let problem: Problem
    @State private var entries: [PTimelineEntry] = []
    @State private var sent = 0
    @State private var failed = 0
    @State private var note: String?
    @State private var loaded = false

    var body: some View {
        Section {
            if !loaded { ProgressView() }
            ForEach(entries) { e in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: e.icon).font(.caption.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 24, height: 24).background(e.color, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.title).font(.subheadline)
                        if !e.detail.isEmpty { Text(e.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                    Spacer(minLength: 4)
                    Text(e.date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: "ru_RU"))))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        } header: {
            HStack {
                Text("Хронология")
                Spacer()
                if sent + failed > 0 {
                    Text("уведомлений \(sent)" + (failed > 0 ? " · ошибок \(failed)" : "")).foregroundStyle(failed > 0 ? Color.red : Color.secondary)
                }
            }
        }
        .task { await load() }
    }

    static func ackText(_ action: Int, _ a: JSON) -> (String, String, Color) {
        var parts: [String] = []
        if action & 2 != 0 { parts.append("подтвердил") }
        if action & 16 != 0 { parts.append("снял подтверждение") }
        if action & 8 != 0 {
            parts.append("сменил важность " + sevName(a["old_severity"].int ?? 0) + " → " + sevName(a["new_severity"].int ?? 0))
        }
        if action & 32 != 0 {
            let u = a["suppress_until"].double ?? 0
            parts.append(u > 0 ? "отложил до " + ruDate(Date(timeIntervalSince1970: u)) : "отложил бессрочно")
        }
        if action & 64 != 0 { parts.append("вернул из отложенных") }
        if action & 1 != 0 { parts.append("закрыл") }
        if action & 4 != 0 && parts.isEmpty { parts.append("написал") }
        let icon = action & 1 != 0 ? "xmark" : action & 32 != 0 ? "moon.zzz.fill" : action & 2 != 0 ? "checkmark" : action & 8 != 0 ? "arrow.up.arrow.down" : "text.bubble.fill"
        let color: Color = action & 1 != 0 ? .red : action & 32 != 0 ? .indigo : action & 2 != 0 ? .green : .blue
        return (parts.joined(separator: ", "), icon, color)
    }

    private func load() async {
        defer { loaded = true }
        var out: [PTimelineEntry] = [PTimelineEntry(id: "start", date: problem.clock, icon: "bolt.fill", color: sevColor(problem.severity),
                                                  title: "Проблема началась", detail: sevName(problem.severity))]
        if Launch.demo {
            let t = problem.clock
            out += [
                PTimelineEntry(id: "a1", date: t.addingTimeInterval(40), icon: "paperplane.fill", color: .green, title: "Telegram → дежурный чат", detail: "Доставлено"),
                PTimelineEntry(id: "a2", date: t.addingTimeInterval(45), icon: "exclamationmark.triangle.fill", color: .red, title: "Email → ivanov@example.com",
                              detail: "Ошибка: Connection timed out (SMTP 10.0.0.25:25), повторов 3"),
                PTimelineEntry(id: "k1", date: t.addingTimeInterval(900), icon: "checkmark", color: .green, title: "Иван Петров подтвердил", detail: "Смотрю, похоже на провайдера"),
                PTimelineEntry(id: "k2", date: t.addingTimeInterval(1500), icon: "arrow.up.arrow.down", color: .blue,
                              title: "Ольга Смирнова сменила важность Средняя → Высокая", detail: "")
            ]
            sent = 1; failed = 1
            entries = out.sorted { $0.date < $1.date }
            return
        }
        var uids = Set<String>()
        var acks: [JSON] = []
        if let ev = try? await session.zabbixResult("event.get", [
            "eventids": .array([.string(problem.id)]),
            "output": .array([.string("eventid")]),
            "selectAcknowledges": .string("extend")
        ]) {
            acks = ev[0]["acknowledges"].array
            for a in acks { if let u = a["userid"].string { uids.insert(u) } }
        }
        var alerts: [JSON] = []
        do {
            alerts = try await session.zabbixResult("alert.get", [
                "eventids": .array([.string(problem.id)]),
                "output": .array(["alertid", "clock", "sendto", "status", "error", "retries", "alerttype", "userid", "mediatypeid"].map { .string($0) }),
                "selectMediatypes": .array([.string("name")]),
                "sortfield": .array([.string("clock")]), "sortorder": .string("ASC"), "limit": .number(100)
            ]).array
            for a in alerts { if let u = a["userid"].string, u != "0" { uids.insert(u) } }
        } catch {
            note = "Журнал уведомлений недоступен этой учётке Zabbix."
        }
        var names: [String: String] = [:]
        if !uids.isEmpty, let us = try? await session.zabbixResult("user.get", ["userids": .array(uids.map { .string($0) }),
                                                                                "output": .array(["userid", "username", "name", "surname"].map { .string($0) })]) {
            for u in us.array {
                let full = [u["name"].string, u["surname"].string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                if let id = u["userid"].string { names[id] = full.isEmpty ? (u["username"].string ?? "") : full }
            }
        }
        for (i, a) in acks.enumerated() {
            let msg = (a["message"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if msg.hasPrefix("tgmsg:") { continue }
            let (what, icon, color) = Self.ackText(a["action"].int ?? 0, a)
            let who = names[a["userid"].string ?? ""] ?? ""
            out.append(PTimelineEntry(id: "k\(i)", date: Date(timeIntervalSince1970: a["clock"].double ?? 0), icon: icon, color: color,
                                     title: (who.isEmpty ? "Кто-то" : who) + " " + what, detail: msg))
        }
        var s = 0, f = 0
        for a in alerts where a["alerttype"].int != 1 {   // 1 — удалённая команда
            let st = a["status"].int ?? 0
            let media = a["mediatypes"][0]["name"].string ?? "Уведомление"
            let to = a["sendto"].string ?? ""
            let user = names[a["userid"].string ?? ""] ?? ""
            let err = a["error"].string ?? ""
            if st == 1 { s += 1 } else if st == 2 { f += 1 }
            out.append(PTimelineEntry(id: "a" + (a["alertid"].string ?? UUID().uuidString), date: Date(timeIntervalSince1970: a["clock"].double ?? 0),
                                     icon: st == 2 ? "exclamationmark.triangle.fill" : st == 1 ? "paperplane.fill" : "hourglass",
                                     color: st == 2 ? .red : st == 1 ? .green : .orange,
                                     title: media + " → " + (user.isEmpty ? to : user + (to.isEmpty ? "" : " (\(to))")),
                                     detail: st == 2 ? "Ошибка: " + err + ((a["retries"].int ?? 0) > 0 ? ", повторов \(a["retries"].int ?? 0)" : "")
                                         : st == 1 ? "Доставлено" : "В очереди"))
        }
        sent = s; failed = f
        entries = out.sorted { $0.date < $1.date }
    }
}

// MARK: Интерактивный график: перекрестие и выделение периода

struct InteractiveChart: View {
    let series: [Series]
    var unit: String?
    var height: CGFloat = 170
    var onZoom: ((ClosedRange<Date>) -> Void)?
    @State private var sel: Date?
    @State private var range: ClosedRange<Date>?
    @State private var lastRange: ClosedRange<Date>?

    private struct Reading: Identifiable { let id: Int; let name: String; let v: Double }

    private func readings(at t: Date) -> [Reading] {
        series.prefix(8).compactMap { s in
            guard let p = s.points.min(by: { abs($0.t.timeIntervalSince(t)) < abs($1.t.timeIntervalSince(t)) }) else { return nil }
            return Reading(id: s.id, name: s.name, v: p.v)
        }
    }

    var body: some View {
        let shown = Array(series.prefix(8))
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let sel {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(sel.formatted(.dateTime.day().month().hour().minute().locale(Locale(identifier: "ru_RU"))))
                            .font(.caption2.weight(.bold))
                        ForEach(readings(at: sel).prefix(5)) { r in
                            HStack(spacing: 4) {
                                Text(shortName(r.name)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(formatValue(r.v, unit: unit)).monospacedDigit().fontWeight(.semibold)
                            }
                            .font(.caption2)
                        }
                    }
                } else if let r = range {
                    Text("Период: " + r.lowerBound.formatted(date: .omitted, time: .shortened) + " – " + r.upperBound.formatted(date: .omitted, time: .shortened))
                        .font(.caption2.weight(.bold)).foregroundStyle(.orange)
                } else {
                    Text("Палец — значения всех рядов · два пальца — выделить период").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 16, alignment: .leading)
            Chart {
                ForEach(shown) { ser in
                    ForEach(ser.points) { p in
                        LineMark(x: .value("t", p.t), y: .value("v", p.v), series: .value("s", ser.name))
                            .foregroundStyle(by: .value("ряд", ser.name))
                            .interpolationMethod(.monotone)
                    }
                }
                if let sel {
                    RuleMark(x: .value("t", sel)).foregroundStyle(Color.secondary.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                if let r = range {
                    RectangleMark(xStart: .value("a", r.lowerBound), xEnd: .value("b", r.upperBound))
                        .foregroundStyle(Color.orange.opacity(0.18))
                }
            }
            .chartXSelection(value: $sel)
            .chartXSelection(range: $range)
            .chartLegend(shown.count > 1 ? .visible : .hidden)
            .chartLegend(position: .bottom)
            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(formatValue(d, unit: unit)) } } } }
            .frame(height: height)
            .onChange(of: range) { r in
                if let r { lastRange = r; return }
                if let l = lastRange, l.upperBound.timeIntervalSince(l.lowerBound) > 120 { Haptics.tap(); onZoom?(l) }
                lastRange = nil
            }
        }
    }
}

struct RangeChips: View {
    @Binding var hours: Double
    var body: some View {
        Picker("Период", selection: $hours) {
            Text("1 ч").tag(1.0); Text("6 ч").tag(6.0); Text("24 ч").tag(24.0); Text("7 д").tag(168.0)
        }
        .pickerStyle(.segmented)
    }
}

// MARK: Переменные дашборда Grafana

struct DashVar: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let label: String
    var options: [String]
    let multi: Bool
    let includeAll: Bool
    var selected: [String]

    var value: String {
        if selected.isEmpty || selected.contains("$__all") { return "/.*/" }
        return selected.count == 1 ? selected[0] : "/^(" + selected.joined(separator: "|") + ")$/"
    }
    var display: String {
        if selected.isEmpty || selected.contains("$__all") { return "Все" }
        return selected.count == 1 ? selected[0] : "\(selected.count) выбрано"
    }
}

extension DashTemplating {
    static func defs(_ dash: JSON) -> [DashVar] {
        dash["templating"]["list"].array.compactMap { v in
            guard let n = v["name"].string else { return nil }
            let type = v["type"].string ?? "query"
            if ["constant", "datasource", "adhoc"].contains(type) || v["hide"].int == 2 { return nil }
            var opts = v["options"].array.compactMap { $0["value"].string ?? $0["text"].string }.filter { $0 != "$__all" }
            if opts.isEmpty, type == "custom", let q = v["query"].string {
                opts = q.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
            let cur = v["current"]["value"]
            var sel: [String] = cur.array.compactMap(\.string)
            if sel.isEmpty, let s = cur.string { sel = [s] }
            return DashVar(name: n, label: v["label"].string ?? n, options: opts,
                           multi: v["multi"].bool ?? false, includeAll: v["includeAll"].bool ?? true, selected: sel)
        }
    }

    /// Варианты для query-переменной Zabbix: «{*}» — группы, «{группа}{*}» — хосты.
    static func zabbixOptions(_ v: JSON, session: Session, vars: [String: String]) async -> [String] {
        var parts: [String] = []
        var kind = ""
        let q = v["query"]
        if let qt = q["queryType"].string {
            kind = qt
            parts = [q["group"].string ?? "*", q["host"].string ?? "*"]
        } else if let s = q.string ?? q["query"].string {
            parts = s.components(separatedBy: "}{").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "{}")) }
            kind = parts.count == 1 ? "group" : parts.count == 2 ? "host" : ""
        }
        func resolve(_ s: String) -> String {
            var r = s
            for (k, val) in vars { r = r.replacingOccurrences(of: "$" + k, with: val) }
            return r
        }
        func match(_ name: String, _ pat: String) -> Bool {
            let p = resolve(pat)
            if p == "*" || p == "/.*/" || p.isEmpty { return true }
            if p.hasPrefix("/"), p.hasSuffix("/"), p.count > 2 {
                return name.range(of: String(p.dropFirst().dropLast()), options: .regularExpression) != nil
            }
            return name == p
        }
        switch kind {
        case "group", "1":
            let r = (try? await session.zabbixResult("hostgroup.get", ["output": .array([.string("name")]), "with_monitored_items": .bool(true)]))?.array ?? []
            return r.compactMap { $0["name"].string }.filter { match($0, parts.first ?? "*") }.sorted()
        case "host", "2":
            let r = (try? await session.zabbixResult("host.get", ["output": .array([.string("name")]), "monitored_hosts": .bool(true),
                                                                  "selectHostGroups": .array([.string("name")])]))?.array ?? []
            return r.filter { h in
                let gs = h["hostgroups"].array.compactMap { $0["name"].string }
                return gs.contains { match($0, parts.first ?? "*") } || parts.first == "*"
            }.compactMap { $0["name"].string }.filter { match($0, parts.count > 1 ? parts[1] : "*") }.sorted()
        default:
            return []
        }
    }
}

struct DashVarBar: View {
    @Binding var defs: [DashVar]

    var body: some View {
        if !defs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(defs.indices, id: \.self) { i in
                        Menu {
                            if defs[i].includeAll || defs[i].options.isEmpty {
                                Button { defs[i].selected = ["$__all"] } label: { check("Все", defs[i].display == "Все") }
                            }
                            ForEach(defs[i].options.prefix(200), id: \.self) { o in
                                Button {
                                    var d = defs[i]
                                    if d.multi {
                                        d.selected.removeAll { $0 == "$__all" }
                                        if d.selected.contains(o) { d.selected.removeAll { $0 == o } } else { d.selected.append(o) }
                                    } else { d.selected = [o] }
                                    defs[i] = d
                                } label: { check(o, defs[i].selected.contains(o)) }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(defs[i].label).foregroundStyle(.secondary)
                                Text(defs[i].display).fontWeight(.semibold).lineLimit(1)
                                Image(systemName: "chevron.down").font(.caption2)
                            }
                            .font(.caption)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                        .menuActionDismissBehavior(defs[i].multi ? .disabled : .automatic)
                    }
                }
            }
        }
    }

    @ViewBuilder private func check(_ t: String, _ on: Bool) -> some View {
        if on { Label(t, systemImage: "checkmark") } else { Text(t) }
    }
}

// MARK: Новые типы панелей Grafana

struct GaugePanelBody: View {
    let series: [Series]
    let unit: String?
    var body: some View {
        let maxV = unit == "percent" ? 100 : max(1, (series.compactMap { $0.points.last?.v }.max() ?? 1) * 1.25)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 10) {
            ForEach(series.prefix(12)) { s in
                let v = s.points.last?.v ?? 0
                VStack(spacing: 4) {
                    Gauge(value: min(v, maxV), in: 0...maxV) {
                        EmptyView()
                    } currentValueLabel: {
                        Text(formatValue(v, unit: unit)).font(.caption2.weight(.bold)).minimumScaleFactor(0.5)
                    }
                    .gaugeStyle(.accessoryCircular)
                    .tint(Gradient(colors: [.green, .yellow, .orange, .red]))
                    .scaleEffect(1.25).frame(height: 70)
                    Text(shortName(s.name)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

struct BarGaugePanelBody: View {
    let series: [Series]
    let unit: String?
    private struct B: Identifiable { let id: Int; let name: String; let v: Double }
    var body: some View {
        let bars = series.prefix(15).map { B(id: $0.id, name: shortName($0.name), v: $0.points.last?.v ?? 0) }.sorted { $0.v > $1.v }
        let maxV = unit == "percent" ? 100 : max(1, (bars.map(\.v).max() ?? 1))
        Chart(bars) { b in
            BarMark(x: .value("v", b.v), y: .value("ряд", b.name))
                .foregroundStyle(heatColor(b.v / maxV * 100, lo: 40, hi: 95))
                .annotation(position: .trailing) { Text(formatValue(b.v, unit: unit)).font(.caption2.monospacedDigit()) }
        }
        .chartXScale(domain: 0...(maxV * 1.15))
        .chartXAxis(.hidden)
        .frame(height: CGFloat(bars.count) * 24 + 10)
    }
}

struct PiePanelBody: View {
    let series: [Series]
    let unit: String?
    private struct S: Identifiable { let id: Int; let name: String; let v: Double }
    var body: some View {
        let parts = series.prefix(10).map { S(id: $0.id, name: shortName($0.name), v: max(0, $0.points.last?.v ?? 0)) }.filter { $0.v > 0 }
        Chart(parts) { p in
            SectorMark(angle: .value("v", p.v), innerRadius: .ratio(0.55), angularInset: 1.5)
                .foregroundStyle(by: .value("ряд", p.name))
        }
        .chartLegend(position: .trailing)
        .frame(height: 170)
    }
}

struct HeatmapPanelBody: View {
    let series: [Series]
    private struct C: Identifiable { let id: Int; let row: String; let start: Date; let end: Date; let v: Double }
    var body: some View {
        let rows = Array(series.prefix(10))
        let all = rows.flatMap { $0.points.map(\.v) }
        let lo = all.min() ?? 0, hi = max((all.max() ?? 1), lo + 0.0001)
        let cells: [C] = rows.enumerated().flatMap { r, s -> [C] in
            let pts = s.points
            guard pts.count > 1 else { return [] }
            let step = max(1, pts.count / 40)
            return stride(from: 0, to: pts.count - 1, by: step).map { i in
                let seg = pts[i..<min(pts.count, i + step)]
                let v = seg.map(\.v).reduce(0, +) / Double(seg.count)
                return C(id: r * 10_000 + i, row: shortName(s.name), start: pts[i].t, end: pts[min(pts.count - 1, i + step)].t, v: v)
            }
        }
        Chart(cells) { c in
            RectangleMark(xStart: .value("с", c.start), xEnd: .value("по", c.end), y: .value("ряд", c.row))
                .foregroundStyle(heatColor((c.v - lo) / (hi - lo) * 100, lo: 0, hi: 100))
        }
        .frame(height: CGFloat(rows.count) * 22 + 30)
    }
}

struct StateTimelinePanelBody: View {
    let series: [Series]
    private struct C: Identifiable { let id: Int; let row: String; let start: Date; let end: Date; let v: Double }
    var body: some View {
        let rows = Array(series.prefix(10))
        let distinct = Set(rows.flatMap { $0.points.map(\.v) })
        let binary = distinct.isSubset(of: [0, 1])
        let all = rows.flatMap { $0.points.map(\.v) }
        let lo = all.min() ?? 0, hi = max(all.max() ?? 1, lo + 0.0001)
        let cells: [C] = rows.enumerated().flatMap { r, s -> [C] in
            var out: [C] = []
            var i = 0
            let p = s.points
            while i < p.count {
                var j = i
                while j + 1 < p.count && p[j + 1].v == p[i].v { j += 1 }
                let end = j + 1 < p.count ? p[j + 1].t : p[j].t.addingTimeInterval(60)
                out.append(C(id: r * 100_000 + i, row: shortName(s.name), start: p[i].t, end: end, v: p[i].v))
                i = j + 1
            }
            return out
        }
        Chart(cells) { c in
            BarMark(xStart: .value("с", c.start), xEnd: .value("по", c.end), y: .value("ряд", c.row), height: .fixed(16))
                .foregroundStyle(binary ? (c.v >= 1 ? Color.green : Color.red) : heatColor((c.v - lo) / (hi - lo) * 100, lo: 0, hi: 100))
        }
        .frame(height: CGFloat(rows.count) * 22 + 30)
    }
}

struct LogsPanelBody: View {
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.prefix(40).enumerated()), id: \.offset) { _, l in
                Text(l).font(.caption2.monospaced()).lineLimit(3)
                    .foregroundStyle(l.localizedCaseInsensitiveContains("error") || l.localizedCaseInsensitiveContains("ошиб") ? Color.red : Color.primary)
                Divider()
            }
            if lines.isEmpty { Text("Нет строк за период").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

// MARK: История элементов Zabbix в виде рядов

extension Session {
    func itemSeries(_ itemids: [String], hours: Double, to: Date = Date()) async -> [Series] {
        guard !itemids.isEmpty,
              let items = try? await zabbixResult("item.get", [
                "itemids": .array(itemids.prefix(8).map { .string($0) }),
                "output": .array(["itemid", "name", "value_type", "units", "hostid"].map { .string($0) }),
                "selectHosts": .array([.string("name")])
              ]) else { return [] }
        let from = to.addingTimeInterval(-hours * 3600).timeIntervalSince1970.rounded()
        var out: [Series] = []
        for (i, it) in items.array.enumerated() {
            guard let id = it["itemid"].string else { continue }
            let vt = it["value_type"].int ?? 0
            guard vt == 0 || vt == 3 else { continue }
            let useTrend = hours > 48
            let r = try? await zabbixResult(useTrend ? "trend.get" : "history.get", useTrend ? [
                "itemids": .array([.string(id)]), "time_from": .number(from), "time_till": .number(to.timeIntervalSince1970.rounded()),
                "output": .array(["clock", "value_avg"].map { .string($0) })
            ] : [
                "itemids": .array([.string(id)]), "history": .number(Double(vt)), "time_from": .number(from),
                "time_till": .number(to.timeIntervalSince1970.rounded()),
                "sortfield": .string("clock"), "sortorder": .string("ASC"), "output": .string("extend"), "limit": .number(3000)
            ])
            let raw = (r?.array ?? []).compactMap { h -> (Date, Double)? in
                guard let c = h["clock"].double, let v = (useTrend ? h["value_avg"] : h["value"]).double else { return nil }
                return (Date(timeIntervalSince1970: c), v)
            }.sorted { $0.0 < $1.0 }
            let step = max(1, raw.count / 300)
            let pts = stride(from: 0, to: raw.count, by: step).enumerated().map { j, k in Pt(id: j, t: raw[k].0, v: raw[k].1) }
            let host = it["hosts"][0]["name"].string ?? ""
            out.append(Series(id: i, name: (host.isEmpty ? "" : host + ": ") + (it["name"].string ?? id), points: pts, text: nil, unit: it["units"].string))
        }
        return out
    }
}

// MARK: Нативные дашборды Zabbix

struct ZDashRef: Identifiable, Hashable { let id: String; let name: String }

struct ZWidget: Identifiable {
    let id: String
    let type: String
    let name: String
    let x: Int
    let y: Int
    let fields: [String: [String]]

    func values(_ prefix: String) -> [String] {
        fields.filter { $0.key == prefix || $0.key.hasPrefix(prefix + ".") }.sorted { $0.key < $1.key }.flatMap(\.value)
    }
    func values(containing s: String) -> [String] {
        fields.filter { $0.key.contains(s) }.sorted { $0.key < $1.key }.flatMap(\.value)
    }
}

struct ZabbixDashListView: View {
    @EnvironmentObject var session: Session
    @State private var list: [ZDashRef] = []
    @State private var loading = true
    @State private var q = ""

    var body: some View {
        List {
            if loading { ProgressView() }
            if !loading && list.isEmpty { Text("Дашбордов нет или нет прав на них").font(.footnote).foregroundStyle(.secondary) }
            ForEach(list.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }) { d in
                NavigationLink { ZabbixDashView(ref: d) } label: { Label(d.name, systemImage: "rectangle.3.group") }
            }
        }
        .searchable(text: $q, prompt: "Название")
        .navigationTitle("Дашборды Zabbix")
        .task {
            defer { loading = false }
            if Launch.demo { list = ZDemo.dashes; return }
            let r = (try? await session.zabbixResult("dashboard.get", ["output": .array([.string("dashboardid"), .string("name")])]))?.array ?? []
            list = r.compactMap { d in
                guard let id = d["dashboardid"].string else { return nil }
                return ZDashRef(id: id, name: d["name"].string ?? id)
            }.sorted { $0.name < $1.name }
        }
    }
}

struct ZabbixDashView: View {
    @EnvironmentObject var session: Session
    let ref: ZDashRef
    @State private var pages: [(String, [ZWidget])] = []
    @State private var page = Launch.value("--zpage").flatMap(Int.init) ?? 0
    @State private var hours = 6.0
    @State private var zoom: ClosedRange<Date>?
    @State private var problems: [Problem] = []
    @State private var hosts: [HostMini] = []
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if pages.count > 1 {
                    Picker("Страница", selection: $page) {
                        ForEach(pages.indices, id: \.self) { i in Text(pages[i].0.isEmpty ? "Стр. \(i + 1)" : pages[i].0).tag(i) }
                    }
                    .pickerStyle(.segmented)
                }
                RangeChips(hours: $hours)
                if let z = zoom {
                    Button { zoom = nil } label: {
                        Label("Сбросить масштаб (" + z.lowerBound.formatted(date: .omitted, time: .shortened) + "–" + z.upperBound.formatted(date: .omitted, time: .shortened) + ")",
                              systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .font(.caption)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
                if pages.isEmpty && error == nil { ProgressView().padding(40) }
                if let ws = pages[safe: page]?.1 {
                    ForEach(ws) { w in
                        ZWidgetView(widget: w, problems: problems, hosts: hosts, hours: hours, zoom: zoom) { zoom = $0 }
                            .id("\(w.id)-\(hours)-\(zoom?.lowerBound.timeIntervalSince1970 ?? 0)")
                    }
                }
            }
            .padding(12)
        }
        .navigationTitle(ref.name)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: hours) { _ in zoom = nil }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        problems = ProblemFilters.visible((try? await session.loadProblems()) ?? [])
        let hr = (try? await session.zabbixResult("host.get", ["output": .array([.string("hostid"), .string("name")]), "monitored_hosts": .bool(true)]))?.array ?? []
        hosts = hr.compactMap { h in h["hostid"].string.map { HostMini(id: $0, name: h["name"].string ?? $0) } }
        if Launch.demo { pages = ZDemo.pages(hosts); return }
        do {
            let r = try await session.zabbixResult("dashboard.get", [
                "dashboardids": .array([.string(ref.id)]), "output": .string("extend"), "selectPages": .string("extend")
            ])
            pages = r[0]["pages"].array.map { pg in
                let ws = pg["widgets"].array.map { w -> ZWidget in
                    var f: [String: [String]] = [:]
                    for x in w["fields"].array { if let n = x["name"].string { f[n, default: []].append(x["value"].string ?? "") } }
                    return ZWidget(id: w["widgetid"].string ?? UUID().uuidString, type: w["type"].string ?? "", name: w["name"].string ?? "",
                                   x: w["x"].int ?? 0, y: w["y"].int ?? 0, fields: f)
                }.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
                return (pg["name"].string ?? "", ws)
            }
            if pages.isEmpty { error = "В дашборде нет страниц" }
        } catch { self.error = error.localizedDescription }
    }
}

struct ZWidgetView: View {
    @EnvironmentObject var session: Session
    let widget: ZWidget
    let problems: [Problem]
    let hosts: [HostMini]
    let hours: Double
    let zoom: ClosedRange<Date>?
    let onZoom: (ClosedRange<Date>) -> Void
    @State private var series: [Series]?
    @State private var single: (String, String)?
    @State private var rows: [(String, String)]?

    private static let titles: [String: String] = [
        "svggraph": "График", "graph": "График (классический)", "problems": "Проблемы", "problemsbysv": "Проблемы по важности",
        "tophosts": "Топ хостов", "honeycomb": "Соты", "clock": "Часы", "item": "Значение", "itemhistory": "История значений",
        "hostavail": "Доступность хостов", "systeminfo": "Система", "geomap": "Геокарта", "map": "Карта", "url": "Ссылка",
        "plaintext": "Текст", "gauge": "Шкала", "piechart": "Круговая", "trigover": "Обзор триггеров", "web": "Веб-мониторинг",
        "toptriggers": "Топ триггеров", "problemhosts": "Проблемы по хостам", "slareport": "Отчёт SLA", "actionlog": "Журнал действий",
        "itemnavigator": "Элементы", "hostnavigator": "Хосты", "dataover": "Обзор данных"
    ]

    var body: some View {
        PanelCard(title: widget.name.isEmpty ? (Self.titles[widget.type] ?? widget.type) : widget.name, subtitle: Self.titles[widget.type] ?? widget.type) {
            content.frame(minHeight: 50)
        }
        .task { await load() }
    }

    @ViewBuilder private var content: some View {
        switch widget.type {
        case "svggraph", "graph", "graphprototype", "itemhistory":
            if let s = series {
                if s.isEmpty { Text("Нет числовых данных за период").font(.caption).foregroundStyle(.secondary) }
                else { InteractiveChart(series: s, unit: s.first?.unit, height: 160, onZoom: onZoom) }
            } else { ProgressView().frame(maxWidth: .infinity) }
        case "item", "gauge":
            if let single {
                VStack(spacing: 2) {
                    Text(single.1).font(.system(size: 38, weight: .bold).monospacedDigit()).foregroundStyle(.orange).minimumScaleFactor(0.4).lineLimit(1)
                    Text(single.0).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity)
            } else { ProgressView().frame(maxWidth: .infinity) }
        case "problemsbysv", "trigover":
            HStack(spacing: 6) {
                ForEach([5, 4, 3, 2], id: \.self) { s in
                    let n = problems.filter { $0.severity == s }.count
                    VStack(spacing: 2) {
                        Text("\(n)").font(.title2.weight(.bold).monospacedDigit())
                        Text(sevName(s)).font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(n > 0 ? sevColor(s).opacity(0.85) : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        case "problems":
            VStack(alignment: .leading, spacing: 6) {
                ForEach(problems.sorted { ($0.severity, $0.clock) > ($1.severity, $1.clock) }.prefix(8)) { ProblemRow(p: $0) }
                if problems.isEmpty { Label("Проблем нет", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
            }
        case "tophosts", "hostavail", "problemhosts", "hostnavigator":
            let top = topHosts
            VStack(spacing: 4) {
                ForEach(top) { h in
                    HStack {
                        Circle().fill(sevColor(h.sev)).frame(width: 8, height: 8)
                        Text(h.id).font(.subheadline).lineLimit(1)
                        Spacer()
                        Text("\(h.n)").font(.subheadline.weight(.bold).monospacedDigit())
                    }
                }
                if top.isEmpty { Text("Все хосты без проблем").font(.caption).foregroundStyle(.secondary) }
            }
        case "honeycomb", "geomap", "map":
            HoneycombGrid(hosts: hosts, levels: hostLevels(problems))
        case "clock":
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(ctx.date.formatted(date: .omitted, time: .standard)).font(.system(size: 40, weight: .light).monospacedDigit())
                    .frame(maxWidth: .infinity)
            }
        case "plaintext", "itemnavigator", "dataover", "systeminfo", "web", "slareport", "actionlog":
            if let rows { rowsView(rows) } else { ProgressView().frame(maxWidth: .infinity) }
        case "piechart":
            if let rows {
                let vals = rows.compactMap { r in Double(r.1).map { (r.0, $0) } }.filter { $0.1 > 0 }
                if vals.isEmpty { Text("Нет числовых значений").font(.caption).foregroundStyle(.secondary) }
                else {
                    Chart(vals.indices, id: \.self) { i in
                        SectorMark(angle: .value("Значение", vals[i].1), innerRadius: .ratio(0.55), angularInset: 1.5)
                            .foregroundStyle(by: .value("Элемент", vals[i].0))
                    }
                    .frame(height: 190)
                }
            } else { ProgressView().frame(maxWidth: .infinity) }
        case "toptriggers":
            let g = Dictionary(grouping: problems, by: \.name)
                .map { (name: $0.key, n: $0.value.count, sev: $0.value.map(\.severity).max() ?? 3) }
                .sorted { $0.n == $1.n ? $0.name < $1.name : $0.n > $1.n }
            VStack(spacing: 4) {
                ForEach(g.prefix(8), id: \.name) { t in
                    HStack {
                        Circle().fill(sevColor(t.sev)).frame(width: 8, height: 8)
                        Text(t.name).font(.caption).lineLimit(1)
                        Spacer()
                        Text("\(t.n)").font(.caption.weight(.bold).monospacedDigit())
                    }
                }
                if g.isEmpty { Text("Активных триггеров нет").font(.caption).foregroundStyle(.secondary) }
            }
        case "url":
            if let u = widget.values(containing: "url").first, let url = URL(string: u) {
                Link(destination: url) { Label("Открыть ссылку", systemImage: "safari") }
            } else { Text("Ссылка не задана").font(.caption).foregroundStyle(.secondary) }
        default:
            Text("Этот виджет («\(widget.type)») пока не рисуется в приложении — откройте дашборд в браузере.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private struct TopHost: Identifiable { let id: String; let n: Int; let sev: Int }

    private func rowsView(_ r: [(String, String)]) -> some View {
        VStack(spacing: 5) {
            ForEach(r.indices, id: \.self) { i in
                HStack(alignment: .firstTextBaseline) {
                    Text(r[i].0).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 8)
                    Text(r[i].1).font(.subheadline.weight(.semibold).monospacedDigit()).lineLimit(1)
                }
            }
            if r.isEmpty { Text("Нет данных").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var topHosts: [TopHost] {
        let g = Dictionary(grouping: problems.filter { !$0.host.isEmpty }, by: \.host)
        let all = g.map { TopHost(id: $0.key, n: $0.value.count, sev: $0.value.map(\.severity).max() ?? 3) }
        return Array(all.sorted { $0.n == $1.n ? $0.id < $1.id : $0.n > $1.n }.prefix(10))
    }

    private func load() async {
        switch widget.type {
        case "svggraph", "graph", "graphprototype", "itemhistory":
            var ids = widget.values(containing: "itemid")
            if ids.isEmpty {
                // режим «шаблоны хостов и элементов»: ds.0.hosts.0 / ds.0.items.0
                let hp = widget.values(containing: "hosts").first ?? "*"
                let ip = widget.values(containing: "items").first ?? ""
                if !ip.isEmpty {
                    var p: [String: JSON] = ["output": .array([.string("itemid")]), "search": .object(["name": .string(ip)]),
                                             "searchWildcardsEnabled": .bool(true), "monitored": .bool(true), "limit": .number(8)]
                    if hp != "*" {
                        let hs = (try? await session.zabbixResult("host.get", ["output": .array([.string("hostid")]), "search": .object(["name": .string(hp)]),
                                                                               "searchWildcardsEnabled": .bool(true)]))?.array ?? []
                        p["hostids"] = .array(hs.map { $0["hostid"] }.filter { !$0.isNull })
                    }
                    ids = ((try? await session.zabbixResult("item.get", p))?.array ?? []).compactMap { $0["itemid"].string }
                }
            }
            if let z = zoom {
                series = await session.itemSeries(ids, hours: z.upperBound.timeIntervalSince(z.lowerBound) / 3600, to: z.upperBound)
            } else {
                series = await session.itemSeries(ids, hours: hours)
            }
        case "item", "gauge":
            guard let id = widget.values(containing: "itemid").first,
                  let r = try? await session.zabbixResult("item.get", ["itemids": .array([.string(id)]),
                                                                       "output": .array(["name", "lastvalue", "units"].map { .string($0) })]) else {
                single = ("Элемент не найден", "—"); return
            }
            let v = r[0]["lastvalue"].double
            single = (r[0]["name"].string ?? "", v.map { formatValue($0, unit: r[0]["units"].string) } ?? (r[0]["lastvalue"].string ?? "—"))
        case "plaintext", "piechart", "itemnavigator", "dataover":
            let ids = widget.values(containing: "itemid")
            var p: [String: JSON] = ["output": .array(["name", "lastvalue", "units"].map { .string($0) }), "limit": .number(20)]
            if !ids.isEmpty { p["itemids"] = .array(ids.map { .string($0) }) }
            else if let ip = widget.values(containing: "items").first {
                p["search"] = .object(["name": .string(ip)]); p["searchWildcardsEnabled"] = .bool(true); p["monitored"] = .bool(true)
            } else { rows = []; return }
            let r = (try? await session.zabbixResult("item.get", p))?.array ?? []
            let raw = widget.type == "piechart"
            rows = r.map { i in
                let v = i["lastvalue"].double
                return (i["name"].string ?? "", raw ? (i["lastvalue"].string ?? "") : (v.map { formatValue($0, unit: i["units"].string) } ?? (i["lastvalue"].string ?? "—")))
            }
        case "systeminfo":
            let v = (try? await session.zabbixResult("apiinfo.version", [:]))?.string
            rows = [("Версия Zabbix", v ?? "—"), ("Хостов под наблюдением", "\(hosts.count)"),
                    ("Активных проблем", "\(problems.count)"), ("Неподтверждённых", "\(problems.filter { !$0.acked }.count)")]
        case "web":
            let r = (try? await session.zabbixResult("item.get", ["output": .array(["name", "lastvalue"].map { .string($0) }),
                                                                  "search": .object(["key_": .string("web.test.fail")]), "monitored": .bool(true)]))?.array ?? []
            let bad = r.filter { ($0["lastvalue"].double ?? 0) > 0 }.count
            rows = [("Веб-сценариев", "\(r.count)"), ("С ошибкой", "\(bad)"), ("Работают", "\(r.count - bad)")]
        case "slareport":
            var p: [String: JSON] = ["output": .array(["name", "slo"].map { .string($0) })]
            let ids = widget.values(containing: "slaid")
            if !ids.isEmpty { p["slaids"] = .array(ids.map { .string($0) }) }
            let r = (try? await session.zabbixResult("sla.get", p))?.array ?? []
            rows = r.map { ($0["name"].string ?? "", "цель " + ($0["slo"].string ?? "?") + "%") }
        case "actionlog":
            let r = (try? await session.zabbixResult("alert.get", ["output": .array(["clock", "subject", "status"].map { .string($0) }),
                                                                   "sortfield": .string("clock"), "sortorder": .string("DESC"), "limit": .number(8)]))?.array ?? []
            rows = r.map { a in
                let d = Date(timeIntervalSince1970: a["clock"].double ?? 0)
                let subj = a["subject"].string ?? ""
                return (subj.isEmpty ? "Уведомление" : subj, (a["status"].int == 2 ? "не дошло · " : "") + d.formatted(date: .omitted, time: .shortened))
            }
        default:
            break
        }
    }
}

struct HoneycombGrid: View {
    let hosts: [HostMini]
    let levels: [String: Level]
    var body: some View {
        let sorted = hosts.sorted { rank(levels[$0.name]) == rank(levels[$1.name]) ? $0.name < $1.name : rank(levels[$0.name]) > rank(levels[$1.name]) }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 4)], spacing: 4) {
            ForEach(sorted.prefix(120)) { h in
                let l = levels[h.name] ?? .ok
                Image(systemName: "hexagon.fill").resizable().scaledToFit()
                    .foregroundStyle(l == .ok ? Color.green.opacity(0.55) : l.color)
                    .overlay(Text(shortName(h.name)).font(.system(size: 7, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                        .multilineTextAlignment(.center).padding(3))
            }
        }
    }
    private func rank(_ l: Level?) -> Int { l == .bad ? 2 : l == .warn ? 1 : 0 }
}

enum ZDemo {
    static let dashes = [ZDashRef(id: "1", name: "Global view"), ZDashRef(id: "2", name: "Филиалы"), ZDashRef(id: "3", name: "Exchange")]

    static func pages(_ hosts: [HostMini]) -> [(String, [ZWidget])] {
        let ids = hosts.prefix(3).map { "\($0.id)0" }
        return [("Обзор", [
            ZWidget(id: "w1", type: "problemsbysv", name: "", x: 0, y: 0, fields: [:]),
            ZWidget(id: "w2", type: "svggraph", name: "Задержка до филиалов", x: 0, y: 1,
                    fields: Dictionary(uniqueKeysWithValues: ids.enumerated().map { ("ds.0.itemids.\($0.offset)", [$0.element]) })),
            ZWidget(id: "w3", type: "honeycomb", name: "Хосты", x: 0, y: 2, fields: [:]),
            ZWidget(id: "w4", type: "tophosts", name: "Больше всего проблем", x: 0, y: 3, fields: [:]),
            ZWidget(id: "w5", type: "item", name: "", x: 0, y: 4, fields: ["itemid.0": [ids.first ?? "10"]])
        ]), ("Проблемы", [ZWidget(id: "w6", type: "problems", name: "", x: 0, y: 0, fields: [:])]),
        ("Ещё", [
            ZWidget(id: "w7", type: "systeminfo", name: "", x: 0, y: 0, fields: [:]),
            ZWidget(id: "w8", type: "toptriggers", name: "", x: 0, y: 1, fields: [:]),
            ZWidget(id: "w9", type: "piechart", name: "Задержка по филиалам", x: 0, y: 2,
                    fields: Dictionary(uniqueKeysWithValues: ids.enumerated().map { ("ds.0.itemids.\($0.offset)", [$0.element]) })),
            ZWidget(id: "w10", type: "plaintext", name: "Последние значения", x: 0, y: 3,
                    fields: Dictionary(uniqueKeysWithValues: ids.enumerated().map { ("itemids.\($0.offset)", [$0.element]) })),
            ZWidget(id: "w11", type: "url", name: "Документация", x: 0, y: 4, fields: ["url": ["https://www.zabbix.com/documentation"]])
        ])]
    }
}

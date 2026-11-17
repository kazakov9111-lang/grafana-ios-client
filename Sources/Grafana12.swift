import SwiftUI
import Charts
import UserNotifications

// v3.0 (дежурство и данные): срок подписи, действия из уведомлений, очередь без связи,
// утренняя сводка, тихие часы, ранбуки, график дежурств, «почему всё упало»,
// «истекает и устаревает», алерты Grafana, нативные дашборды Grafana, карты Zabbix.

// MARK: Срок подписи (бесплатный Apple ID — 7 дней)

enum SignInfo {
    static let expiry: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let d = try? Data(contentsOf: url), let s = String(data: d, encoding: .isoLatin1),
              let a = s.range(of: "<?xml"), let b = s.range(of: "</plist>") else { return nil }
        let xml = String(s[a.lowerBound..<b.upperBound])
        guard let pl = try? PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any] else { return nil }
        return pl["ExpirationDate"] as? Date
    }()

    static var shownExpiry: Date? { Launch.demo ? Date().addingTimeInterval(1.6 * 86400) : expiry }

    static var daysLeft: Double? { shownExpiry.map { $0.timeIntervalSinceNow / 86400 } }

    /// Напоминание за сутки до окончания подписи.
    static func scheduleReminder() {
        guard let e = expiry else { return }
        let at = e.addingTimeInterval(-86400)
        guard at > Date() else { return }
        let c = UNMutableNotificationContent()
        c.title = "Grafana перестанет открываться завтра"
        c.body = "Подпись приложения истекает \(ruDate(e)). Переустановите IPA через Sideloadly — настройки сохранятся."
        c.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "sign-expiry", content: c,
                                                                     trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }
}

struct SignBanner: View {
    var body: some View {
        if let d = SignInfo.daysLeft, d < 3 {
            HStack(spacing: 10) {
                Image(systemName: "signature").font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d < 1 ? "Подпись истекает сегодня" : "Подпись истекает через \(Int(d.rounded(.up))) дн.").font(.subheadline.weight(.semibold))
                    Text("Переустановите Grafana.ipa через Sideloadly — данные и настройки сохранятся.").font(.caption)
                }
                Spacer()
            }
            .padding(12)
            .foregroundStyle(.black)
            .background(RoundedRectangle(cornerRadius: 14).fill(d < 1 ? Level.bad.color : Color.orange))
        }
    }
}

// MARK: Очередь действий без связи

struct QueuedAction: Codable, Identifiable {
    var id = UUID()
    let eventId: String
    let action: Int
    var message = ""
    var until: Double?
    let title: String
    var created = Date()
}

final class ActionQueue: ObservableObject {
    static let shared = ActionQueue()
    @Published var items: [QueuedAction] { didSet { if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: "actionQueue") } } }

    init() {
        if let d = UserDefaults.standard.data(forKey: "actionQueue"), let v = try? JSONDecoder().decode([QueuedAction].self, from: d) { items = v }
        else { items = Launch.screen == "queue" ? [QueuedAction(eventId: "1", action: 6, title: "Mikrotik - Kaliningrad: нет ответа на ICMP ping")] : [] }
    }

    static func isOffline(_ e: Error) -> Bool {
        guard let u = e as? URLError else { return false }
        return [.notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dataNotAllowed].contains(u.code)
    }

    func add(_ a: QueuedAction) { items.append(a) }

    @MainActor func flush(_ session: Session) async {
        guard !items.isEmpty, !Launch.demo else { return }
        for a in items {
            var extra: [String: JSON] = [:]
            if let u = a.until { extra["suppress_until"] = .number(u) }
            do {
                try await session.eventAction([a.eventId], action: a.action, message: a.message, extra: extra)
                items.removeAll { $0.id == a.id }
            } catch {
                if Self.isOffline(error) { return }
                items.removeAll { $0.id == a.id }   // проблема уже закрыта или нет прав — повторять бессмысленно
            }
        }
    }
}

struct QueueBanner: View {
    @ObservedObject private var q = ActionQueue.shared

    var body: some View {
        if !q.items.isEmpty {
            Label("Ждут отправки в Zabbix: \(q.items.count) — отправлю, когда появится связь", systemImage: "tray.and.arrow.up")
                .font(.footnote).foregroundStyle(.orange)
        }
    }
}

// MARK: Действия прямо из уведомления

enum NotifActions {
    static func register() {
        let ack = UNNotificationAction(identifier: "ack", title: "Подтвердить", options: [.authenticationRequired])
        let snooze = UNNotificationAction(identifier: "snooze", title: "Отложить на час", options: [.authenticationRequired])
        let open = UNNotificationAction(identifier: "open", title: "Открыть", options: [.foreground])
        let cat = UNNotificationCategory(identifier: "problem", actions: [ack, snooze, open], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([cat])
        UNUserNotificationCenter.current().delegate = NotifDelegate.shared
    }
}

final class NotifDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotifDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let id = info["eventid"] as? String ?? ""
        let title = response.notification.request.content.body
        let action = response.actionIdentifier
        Task { @MainActor in
            defer { completionHandler() }
            guard !id.isEmpty else { return }
            switch action {
            case "ack", "snooze":
                let s = Badge.session ?? Session()
                if !s.loggedIn { await s.restore() }
                let q = action == "ack"
                    ? QueuedAction(eventId: id, action: 6, message: "Подтверждено из уведомления", title: title)
                    : QueuedAction(eventId: id, action: 32, until: Date().addingTimeInterval(3600).timeIntervalSince1970.rounded(), title: title)
                var extra: [String: JSON] = [:]
                if let u = q.until { extra["suppress_until"] = .number(u) }
                do { try await s.eventAction([id], action: q.action, message: q.message, extra: extra) }
                catch { if ActionQueue.isOffline(error) { ActionQueue.shared.add(q) } }
            default:
                DeepLink.shared.problem = ProblemRef(id: id)
            }
        }
    }
}

// MARK: Тихие часы

enum QuietHours {
    static var on: Bool { UserDefaults.standard.bool(forKey: "quietOn") }
    static var from: Int { UserDefaults.standard.object(forKey: "quietFrom") as? Int ?? 23 }
    static var to: Int { UserDefaults.standard.object(forKey: "quietTo") as? Int ?? 7 }
    static var minSev: Int { UserDefaults.standard.object(forKey: "quietMinSev") as? Int ?? 5 }
    static var hosts: [String] {
        (UserDefaults.standard.string(forKey: "quietHosts") ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    static func isQuiet(_ d: Date = Date()) -> Bool {
        guard on else { return false }
        let h = Calendar.current.component(.hour, from: d)
        return from <= to ? (h >= from && h < to) : (h >= from || h < to)
    }

    /// Пропускать ли уведомление о проблеме сейчас.
    static func allows(_ p: Problem) -> Bool {
        guard isQuiet() else { return true }
        return p.severity >= minSev || hosts.contains { p.host.lowercased().contains($0) }
    }
}

struct QuietHoursView: View {
    @AppStorage("quietOn") private var on = false
    @AppStorage("quietFrom") private var from = 23
    @AppStorage("quietTo") private var to = 7
    @AppStorage("quietMinSev") private var minSev = 5
    @AppStorage("quietHosts") private var hosts = ""

    var body: some View {
        Form {
            Toggle("Тихие часы", isOn: $on)
            if on {
                Stepper("С \(from):00", value: $from, in: 0...23)
                Stepper("До \(to):00", value: $to, in: 0...23)
                Picker("Будить только при", selection: $minSev) {
                    Text("Чрезвычайной").tag(5)
                    Text("Высокой и выше").tag(4)
                }
                Section {
                    TextField("Хосты через запятую, например MBX, DC1", text: $hosts).textInputAutocapitalization(.never)
                } header: { Text("Всегда будить по хостам") } footer: {
                    Text("В тихие часы уведомления приходят только о проблемах нужной важности или с этих хостов. Остальное увидите утром в сводке.")
                }
            }
        }
        .navigationTitle("Тихие часы")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: Утренняя сводка

struct MorningReport {
    var started = 0
    var selfResolved = 0
    var stillOpen: [Problem] = []
    var longOpen: [Problem] = []
    var worst: String?

    var lines: [String] {
        var l = ["За ночь началось проблем: \(started), решились сами: \(selfResolved)."]
        l.append(stillOpen.isEmpty ? "Сейчас открытых проблем нет." : "Открыто сейчас: \(stillOpen.count), высоких: \(stillOpen.filter { $0.severity >= 4 }.count).")
        if !longOpen.isEmpty { l.append("Висят дольше 12 часов: \(longOpen.count).") }
        if let worst { l.append("Самая серьёзная: \(worst).") }
        return l
    }
}

enum MorningSummary {
    @MainActor static func build(_ s: Session) async -> MorningReport {
        var r = MorningReport()
        let cal = Calendar.current
        let nightStart = cal.date(bySettingHour: 20, minute: 0, second: 0, of: cal.date(byAdding: .day, value: -1, to: Date())!)!
        let hist = (try? await s.problemHistory(days: 1)) ?? []
        let night = hist.filter { $0.start >= nightStart }
        r.started = night.count
        r.selfResolved = night.filter { $0.end != nil && !$0.acked }.count
        let open = (try? await s.loadProblems()) ?? []
        r.stillOpen = open
        r.longOpen = open.filter { Date().timeIntervalSince($0.clock) > 12 * 3600 }
        if let w = open.max(by: { $0.severity < $1.severity }) { r.worst = "\(w.name) (\(w.host))" }
        return r
    }

    /// Вызывается из фонового обновления: раз в день после 8:00.
    @MainActor static func maybeSend(_ s: Session) async {
        guard UserDefaults.standard.object(forKey: "morningOn") as? Bool ?? true else { return }
        let cal = Calendar.current
        let h = cal.component(.hour, from: Date())
        let today = cal.startOfDay(for: Date()).timeIntervalSince1970
        guard h >= 8, h < 12, UserDefaults.standard.double(forKey: "morningSent") < today else { return }
        let r = await build(s)
        let c = UNMutableNotificationContent()
        c.title = "Доброе утро: \(r.stillOpen.count) открытых проблем"
        c.body = r.lines.joined(separator: " ")
        c.threadIdentifier = "morning"
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "morning\(today)", content: c, trigger: nil))
        UserDefaults.standard.set(today, forKey: "morningSent")
    }
}

struct MorningView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var r: MorningReport?
    @AppStorage("morningOn") private var on = true

    var body: some View {
        NavigationStack {
            List {
                if let r {
                    Section("Ночь с 20:00") { ForEach(r.lines, id: \.self) { Text($0) } }
                    if !r.longOpen.isEmpty {
                        Section("Висят дольше 12 часов") {
                            ForEach(r.longOpen.sorted { $0.clock < $1.clock }) { p in ProblemRow(p: p) }
                        }
                    }
                } else { ProgressView() }
                Section {
                    Toggle("Присылать сводку утром", isOn: $on)
                } footer: { Text("Приходит при первом фоновом обновлении после 8:00 (iOS сама решает, когда его запускать).") }
            }
            .navigationTitle("Утренняя сводка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } } }
            .task { r = await MorningSummary.build(session) }
        }
    }
}

// MARK: Ранбуки: пошаговые инструкции к триггеру

final class RunbookStore: ObservableObject {
    static let shared = RunbookStore()
    @Published var steps: [String: [String]] { didSet { UserDefaults.standard.set(steps, forKey: "runbooks") } }
    @Published var done: [String: [Int]] { didSet { UserDefaults.standard.set(done, forKey: "runbookDone") } }

    static let demoSteps = ["Проверить пинг до хоста", "Запустить скрипт «Traceroute»", "Позвонить провайдеру филиала", "Записать номер заявки в аварию"]

    init() {
        steps = (UserDefaults.standard.dictionary(forKey: "runbooks") as? [String: [String]]) ?? [:]
        done = (UserDefaults.standard.dictionary(forKey: "runbookDone") as? [String: [Int]]) ?? (Launch.demo ? ["*": [0, 1]] : [:])
    }

    func steps(for triggerId: String) -> [String] { steps[triggerId] ?? (Launch.demo ? Self.demoSteps : []) }
    func done(for eventId: String) -> Set<Int> { Set(done[eventId] ?? (Launch.demo ? done["*"] ?? [] : [])) }
}

struct RunbookSection: View {
    let problem: Problem
    @ObservedObject private var store = RunbookStore.shared
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        let steps = store.steps(for: problem.triggerId)
        let done = store.done(for: problem.id)
        Section {
            if steps.isEmpty {
                Button("Добавить шаги…") { draft = ""; editing = true }
            } else {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                    Button {
                        var d = done
                        if d.contains(i) { d.remove(i) } else { d.insert(i) }
                        store.done[problem.id] = Array(d).sorted()
                        if d.count == steps.count { Haptics.success() } else { Haptics.tap() }
                    } label: {
                        HStack(alignment: .top) {
                            Image(systemName: done.contains(i) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(done.contains(i) ? Level.ok.color : Color.secondary)
                            Text("\(i + 1). \(s)").strikethrough(done.contains(i)).foregroundStyle(.primary)
                        }
                    }
                }
                ProgressView(value: Double(done.count), total: Double(steps.count)).tint(Level.ok.color)
                HStack {
                    Button("Изменить") { draft = steps.joined(separator: "\n"); editing = true }
                    Spacer()
                    ShareLink(item: "Ход работ: \(problem.name)\n" + steps.enumerated().map { "\(done.contains($0.offset) ? "✓" : "–") \($0.element)" }.joined(separator: "\n")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .buttonStyle(.borderless).font(.caption)
            }
        } header: { Text("Что делать (ранбук)") } footer: {
            Text("Шаги общие для этого триггера, отметки — для этой проблемы. Хранится на телефоне.")
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                Form {
                    Section {
                        TextEditor(text: $draft).frame(minHeight: 200)
                    } footer: { Text("Каждый шаг с новой строки.") }
                }
                .navigationTitle("Шаги")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Отмена") { editing = false } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Сохранить") {
                            let s = draft.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                            store.steps[problem.triggerId] = s.isEmpty ? nil : s
                            editing = false
                        }
                    }
                }
            }
        }
    }
}

// MARK: График дежурств

struct DutyShift: Codable, Identifiable, Hashable {
    var id = UUID()
    var person: String
    var start: Date
    var end: Date
    var accepted: Date?
}

final class DutyStore: ObservableObject {
    static let shared = DutyStore()
    @Published var shifts: [DutyShift] { didSet { save() } }
    @Published var me: String { didSet { UserDefaults.standard.set(me, forKey: "dutyMe"); scheduleReminders() } }

    init() {
        me = UserDefaults.standard.string(forKey: "dutyMe") ?? (Launch.demo ? "Иванов" : "")
        if let d = UserDefaults.standard.data(forKey: "dutyShifts"), let v = try? JSONDecoder().decode([DutyShift].self, from: d) {
            shifts = v
        } else if Launch.demo {
            let cal = Calendar.current, d0 = cal.startOfDay(for: Date())
            shifts = (0..<7).map { i in
                let s = cal.date(byAdding: .day, value: i - 1, to: d0)!.addingTimeInterval(9 * 3600)
                return DutyShift(person: ["Иванов", "Петров", "Сидоров"][i % 3], start: s, end: s.addingTimeInterval(86400),
                                 accepted: i == 1 ? Date().addingTimeInterval(-3000) : nil)
            }
        } else { shifts = [] }
    }

    var current: DutyShift? { shifts.first { $0.start <= Date() && $0.end > Date() } }

    private func save() {
        if let d = try? JSONEncoder().encode(shifts) { UserDefaults.standard.set(d, forKey: "dutyShifts") }
        scheduleReminders()
    }

    /// Напоминание за час до каждой своей смены.
    func scheduleReminders() {
        guard !Launch.demo else { return }
        let c = UNUserNotificationCenter.current()
        c.getPendingNotificationRequests { reqs in
            c.removePendingNotificationRequests(withIdentifiers: reqs.map(\.identifier).filter { $0.hasPrefix("duty-") })
        }
        let mine = me.trimmingCharacters(in: .whitespaces).lowercased()
        guard !mine.isEmpty else { return }
        for s in shifts where s.person.lowercased() == mine && s.start.addingTimeInterval(-3600) > Date() {
            let n = UNMutableNotificationContent()
            n.title = "Через час ваше дежурство"
            n.body = "С \(ruDate(s.start)) до \(ruDate(s.end)). Откройте «Передачу смены», чтобы принять дела."
            n.sound = .default
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: s.start.addingTimeInterval(-3600))
            c.add(UNNotificationRequest(identifier: "duty-\(s.id)", content: n, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
        }
    }
}

struct DutyRosterView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = DutyStore.shared
    @State private var adding = false
    @State private var person = ""
    @State private var start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(9 * 3600)
    @State private var hours = 24

    var body: some View {
        NavigationStack {
            List {
                if let c = store.current {
                    Section("Сейчас дежурит") {
                        HStack {
                            Image(systemName: "person.badge.shield.checkmark.fill").font(.title2).foregroundStyle(.orange)
                            VStack(alignment: .leading) {
                                Text(c.person).font(.headline)
                                Text("до \(ruDate(c.end))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let a = c.accepted {
                                Label("принял \(a.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.seal.fill")
                                    .font(.caption).foregroundStyle(Level.ok.color)
                            } else {
                                Button("Принял смену") {
                                    if let i = store.shifts.firstIndex(where: { $0.id == c.id }) { store.shifts[i].accepted = Date(); Haptics.success() }
                                }
                                .buttonStyle(.borderedProminent).tint(.orange).font(.caption)
                            }
                        }
                    }
                }
                Section("Дальше") {
                    ForEach(store.shifts.filter { $0.end > Date() && $0.start > Date() }.sorted { $0.start < $1.start }) { s in
                        HStack {
                            Text(s.person).fontWeight(s.person.lowercased() == store.me.lowercased() ? .bold : .regular)
                            Spacer()
                            Text("\(s.start.formatted(.dateTime.weekday(.abbreviated).day().hour().minute().locale(Locale(identifier: "ru_RU"))))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { idx in
                        let list = store.shifts.filter { $0.end > Date() && $0.start > Date() }.sorted { $0.start < $1.start }
                        let ids = Set(idx.map { list[$0].id })
                        store.shifts.removeAll { ids.contains($0.id) }
                    }
                }
                Section {
                    TextField("Моя фамилия в графике", text: $store.me)
                } footer: { Text("За час до вашей смены придёт напоминание.") }
            }
            .navigationTitle("График дежурств")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button { adding = true } label: { Image(systemName: "plus") } }
            }
            .sheet(isPresented: $adding) {
                NavigationStack {
                    Form {
                        TextField("Кто", text: $person)
                        DatePicker("Начало", selection: $start)
                        Stepper("Длительность: \(hours) ч", value: $hours, in: 1...168, step: hours < 24 ? 1 : 12)
                    }
                    .navigationTitle("Смена")
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button("Отмена") { adding = false } }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Добавить") {
                                store.shifts.append(DutyShift(person: person, start: start, end: start.addingTimeInterval(Double(hours) * 3600)))
                                adding = false; person = ""
                            }
                            .disabled(person.isEmpty)
                        }
                    }
                }
                .presentationDetents([.medium])
            }
        }
    }
}

// MARK: «Почему всё упало»: разбор группы одновременных проблем

struct ProblemGroup: Identifiable { let id: String; let problems: [Problem] }

struct RootCauseView: View {
    let problems: [Problem]
    @Environment(\.dismiss) private var dismiss
    @State private var llm: String?
    @State private var busy = true

    private var first: Problem? { problems.min { $0.clock < $1.clock } }

    private var hints: [String] {
        var h: [String] = []
        if let f = first { h.append("Первой началась: «\(f.name)» на \(f.host) в \(f.clock.formatted(date: .omitted, time: .standard)).") }
        let parents = Dictionary(grouping: problems.compactMap { DepStore.shared.parent[$0.host] }, by: { $0 }).mapValues(\.count)
        if let top = parents.max(by: { $0.value < $1.value }), top.value >= 2 {
            h.append("У \(top.value) хостов общий родитель «\(top.key)» — вероятная причина там.")
        }
        let hosts = Set(problems.map(\.host))
        if hosts.count == 1, let one = hosts.first { h.append("Все проблемы на одном хосте \(one) — скорее всего сам хост (перезагрузка, нехватка ресурсов).") }
        let icmp = problems.filter { $0.name.contains("ICMP") || $0.name.lowercased().contains("unavailable") || $0.name.contains("недоступ") }
        if icmp.count >= 2 { h.append("\(icmp.count) хостов перестали отвечать одновременно — похоже на сеть или питание, а не на сами серверы.") }
        let branches = Set(problems.map { branchName($0.host) }).filter { !$0.isEmpty }
        if branches.count == 1, let b = branches.first, hosts.count > 1 { h.append("Все хосты относятся к одному месту: \(b).") }
        if h.count <= 1 { h.append("Явной общей причины не видно: проверьте, что менялось в это время (карточка проблемы → «Что менялось»).") }
        return h
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Гипотезы") { ForEach(hints, id: \.self) { Text($0).font(.subheadline) } }
                if busy { Section { ProgressView() } }
                if let llm { Section("Модель Apple") { Text(llm).font(.subheadline) } }
                Section("Проблемы группы (\(problems.count))") {
                    ForEach(problems.sorted { $0.clock < $1.clock }) { p in ProblemRow(p: p) }
                }
            }
            .navigationTitle("Почему всё упало")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } } }
            .task {
                defer { busy = false }
                #if canImport(FoundationModels)
                if #available(iOS 26, *) {
                    let ctx = problems.sorted { $0.clock < $1.clock }.map { "\($0.clock.formatted(date: .omitted, time: .standard)) [\(sevName($0.severity))] \($0.host): \($0.name)" }.joined(separator: "\n")
                    llm = await OnDeviceLLM.answer(question: "Эти проблемы начались почти одновременно. Какая наиболее вероятная общая причина и что проверить первым?", context: ctx)
                }
                #endif
            }
        }
    }
}

// MARK: Истекает и устаревает: сертификаты, бэкапы

struct ExpiringRow: Identifiable {
    let id: String
    let host: String
    let name: String
    let value: Double
    let level: Level
    let text: String
}

struct ExpiringView: View {
    @EnvironmentObject var session: Session
    @State private var certs: [ExpiringRow] = []
    @State private var agents: [ExpiringRow] = []
    @State private var jobs: [ExpiringRow] = []
    @State private var loading = true

    var body: some View {
        List {
            if loading { ProgressView() }
            section("SSL-сертификаты", "lock.shield", certs, empty: "Элементов «срок действия SSL» не найдено")
            section("Veeam Agent: с последнего успешного бэкапа", "externaldrive.badge.timemachine", agents, empty: "Агентов Veeam не найдено")
            section("Veeam B&R: задания за сутки", "externaldrive.badge.checkmark", jobs, empty: "Серверов Veeam не найдено")
        }
        .navigationTitle("Истекает и устаревает")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    @ViewBuilder private func section(_ title: String, _ icon: String, _ rows: [ExpiringRow], empty: String) -> some View {
        Section {
            if rows.isEmpty && !loading { Text(empty).font(.footnote).foregroundStyle(.secondary) }
            ForEach(rows) { r in
                HStack {
                    Circle().fill(r.level.color).frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.host).font(.subheadline).lineLimit(1)
                        if r.name != r.host { Text(r.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer()
                    Text(r.text).font(.subheadline.monospacedDigit()).foregroundStyle(r.level == .ok ? Color.secondary : r.level.color)
                }
            }
        } header: { Label(title, systemImage: icon) }
    }

    private func items(_ search: String) async -> [JSON] {
        (try? await session.zabbixResult("item.get", [
            "search": .object(["name": .string(search)]), "monitored": .bool(true),
            "output": .array(["itemid", "name", "lastvalue", "hostid"].map { .string($0) }),
            "selectHosts": .array([.string("name")]), "limit": .number(300)
        ]))?.array ?? []
    }

    private func load() async {
        defer { loading = false }
        certs = await items("SSL сертификата").compactMap { x in
            guard let v = Double(x["lastvalue"].string ?? ""), let id = x["itemid"].string else { return nil }
            let l: Level = v < 14 ? .bad : (v < 30 ? .warn : .ok)
            return ExpiringRow(id: id, host: x["hosts"][0]["name"].string ?? "", name: x["name"].string ?? "", value: v, level: l, text: "\(Int(v)) дн.")
        }.sorted { $0.value < $1.value }
        agents = await items("часов с последнего успешного").compactMap { x in
            guard let v = Double(x["lastvalue"].string ?? ""), let id = x["itemid"].string else { return nil }
            let l: Level = v > 48 ? .bad : (v > 26 ? .warn : .ok)
            return ExpiringRow(id: id, host: x["hosts"][0]["name"].string ?? "", name: x["name"].string ?? "", value: v,
                               level: l, text: v < 48 ? "\(Int(v)) ч" : "\(Int(v / 24)) дн.")
        }.sorted { $0.value > $1.value }
        jobs = await items("Backups finished with Failed").compactMap { x in
            guard let v = Double(x["lastvalue"].string ?? ""), let id = x["itemid"].string else { return nil }
            return ExpiringRow(id: id, host: x["hosts"][0]["name"].string ?? "", name: "", value: v, level: v > 0 ? .bad : .ok,
                               text: v > 0 ? "ошибок: \(Int(v))" : "без ошибок")
        }.sorted { $0.value > $1.value }
    }
}

// MARK: Алерты Grafana

struct GAlert: Identifiable {
    let id: String
    let name: String
    let group: String
    let state: String
    let health: String
    let since: Date?
}

struct GSilence: Identifiable {
    let id: String
    let comment: String
    let by: String
    let ends: Date?
    let matchers: String
}

struct GrafanaAlertsView: View {
    @EnvironmentObject var session: Session
    @State private var alerts: [GAlert] = []
    @State private var silences: [GSilence] = []
    @State private var loading = true
    @State private var showAll = false

    private func color(_ s: String) -> Color { s == "firing" || s == "alerting" ? Level.bad.color : (s == "pending" ? Level.warn.color : Level.ok.color) }
    private func ru(_ s: String) -> String { ["firing": "срабатывает", "alerting": "срабатывает", "pending": "ожидает", "inactive": "норма", "normal": "норма"][s] ?? s }

    var body: some View {
        List {
            if loading { ProgressView() }
            Section {
                Toggle("Показывать правила в норме", isOn: $showAll)
                let shown = alerts.filter { showAll || $0.state != "inactive" }
                if shown.isEmpty && !loading { Label("Сработавших правил нет", systemImage: "checkmark.seal").foregroundStyle(Level.ok.color) }
                ForEach(shown) { a in
                    HStack {
                        Circle().fill(color(a.state)).frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.name).font(.subheadline)
                            Text(a.group + (a.health != "ok" && !a.health.isEmpty ? " · ошибка вычисления" : "")).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(ru(a.state)).font(.caption).foregroundStyle(color(a.state))
                            if let s = a.since, a.state != "inactive" { Text(duration(seconds: Date().timeIntervalSince(s))).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
            } header: { Text("Правила оповещений") }
            Section("Тишина (silences)") {
                if silences.isEmpty && !loading { Text("Активной тишины нет").font(.footnote).foregroundStyle(.secondary) }
                ForEach(silences) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.matchers).font(.subheadline.monospaced())
                        Text("\(s.comment) · \(s.by)").font(.caption)
                        if let e = s.ends { Text("до \(ruDate(e))").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .navigationTitle("Алерты Grafana")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        defer { loading = false }
        if Launch.demo {
            alerts = [GAlert(id: "1", name: "Свободно на томе DB меньше 10%", group: "Хранилища", state: "firing", health: "ok", since: Date().addingTimeInterval(-5400)),
                      GAlert(id: "2", name: "Очередь Exchange > 100", group: "Почта", state: "pending", health: "ok", since: Date().addingTimeInterval(-240)),
                      GAlert(id: "3", name: "CPU гипервизоров > 90%", group: "Серверы", state: "inactive", health: "ok", since: nil)]
            silences = [GSilence(id: "1", comment: "Замена диска", by: "admin", ends: Date().addingTimeInterval(7200), matchers: "host=HYPER3")]
            return
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ s: String?) -> Date? {
            guard let s, !s.hasPrefix("0001") else { return nil }
            return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
        let r = (try? await session.request("/api/prometheus/grafana/api/v1/rules")) ?? .null
        var out: [GAlert] = []
        for g in r["data"]["groups"].array {
            for rule in g["rules"].array {
                let name = rule["name"].string ?? ""
                out.append(GAlert(id: "\(g["name"].string ?? "")/\(name)", name: name, group: g["name"].string ?? "",
                                  state: rule["state"].string ?? "", health: rule["health"].string ?? "",
                                  since: date(rule["alerts"][0]["activeAt"].string)))
            }
        }
        func rank(_ a: GAlert) -> Int { a.state == "firing" ? 0 : (a.state == "pending" ? 1 : 2) }
        alerts = out.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0.name < $1.name }
        let s = (try? await session.request("/api/alertmanager/grafana/api/v2/silences"))?.array ?? []
        silences = s.filter { $0["status"]["state"].string == "active" }.map { x in
            GSilence(id: x["id"].string ?? UUID().uuidString, comment: x["comment"].string ?? "", by: x["createdBy"].string ?? "",
                     ends: date(x["endsAt"].string),
                     matchers: x["matchers"].array.map { "\($0["name"].string ?? "")=\($0["value"].string ?? "")" }.joined(separator: ", "))
        }
    }
}

// MARK: Нативные дашборды Grafana

struct DashRef: Identifiable, Hashable {
    let id: String   // uid
    let title: String
    let folder: String
}

struct GPanel: Identifiable {
    let id: Int
    let title: String
    let type: String
    let targets: [JSON]
    let datasource: JSON
    let unit: String?
    let text: String
}

enum DashTemplating {
    /// Значения переменных дашборда по умолчанию: $group → "/^(A|B)$/" и т. п.
    static func vars(_ dash: JSON) -> [String: String] {
        var m: [String: String] = [:]
        for v in dash["templating"]["list"].array {
            guard let n = v["name"].string else { continue }
            let cur = v["current"]["value"]
            var vals: [String] = cur.array.compactMap(\.string)
            if vals.isEmpty, let s = cur.string { vals = [s] }
            if vals.contains("$__all") || vals.isEmpty { m[n] = "/.*/"; continue }
            m[n] = vals.count == 1 ? vals[0] : "/^(" + vals.joined(separator: "|") + ")$/"
        }
        return m
    }

    static func apply(_ j: JSON, _ vars: [String: String]) -> JSON {
        guard !vars.isEmpty, let d = try? JSONEncoder().encode(j), var s = String(data: d, encoding: .utf8) else { return j }
        for (k, v) in vars.sorted(by: { $0.key.count > $1.key.count }) {
            let esc = v.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            s = s.replacingOccurrences(of: "${\(k)}", with: esc).replacingOccurrences(of: "$\(k)", with: esc)
        }
        return (try? JSONDecoder().decode(JSON.self, from: Data(s.utf8))) ?? j
    }
}

struct DashListView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var list: [DashRef] = []
    @State private var q = ""
    @State private var loading = true

    @State private var path: [DashRef] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if loading { ProgressView() }
                let shown = list.filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) || $0.folder.localizedCaseInsensitiveContains(q) }
                ForEach(Dictionary(grouping: shown, by: \.folder).sorted { $0.key < $1.key }, id: \.key) { entry in
                    Section(entry.key.isEmpty ? "Общие" : entry.key) {
                        ForEach(entry.value.sorted { $0.title < $1.title }) { d in
                            NavigationLink(value: d) { Label(d.title, systemImage: "square.grid.3x2") }
                        }
                    }
                }
            }
            .navigationTitle("Дашборды Grafana")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $q, prompt: "Название или папка")
            .navigationDestination(for: DashRef.self) { DashView(ref: $0) }
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } } }
            .task {
                defer { loading = false }
                if Launch.demo { list = DemoDash.list; if Launch.screen == "dash" { path = [list[0]] }; return }
                let r = (try? await session.request("/api/search?type=dash-db&limit=500"))?.array ?? []
                list = r.compactMap { x in
                    guard let uid = x["uid"].string, let t = x["title"].string else { return nil }
                    return DashRef(id: uid, title: t, folder: x["folderTitle"].string ?? "")
                }
            }
        }
    }
}

struct DashView: View {
    @EnvironmentObject var session: Session
    let ref: DashRef
    @State private var panels: [GPanel] = []
    @State private var defs: [DashVar] = []
    @State private var baseVars: [String: String] = [:]
    @State private var hours = 6.0
    @State private var zoom: ClosedRange<Date>?
    @State private var error: String?
    @State private var dsByName: [String: JSON] = [:]
    @State private var defaultDS: JSON = .null

    private var vars: [String: String] {
        var m = baseVars
        for d in defs { m[d.name] = d.value }
        return m
    }

    private var key: String {
        let v = defs.map { $0.name + "=" + $0.selected.joined(separator: ",") }.joined(separator: "&")
        return "\(hours)-\(zoom?.lowerBound.timeIntervalSince1970 ?? 0)-\(v)"
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                DashVarBar(defs: $defs)
                RangeChips(hours: $hours)
                if let z = zoom {
                    Button { zoom = nil } label: {
                        Label("Сбросить масштаб (" + z.lowerBound.formatted(date: .omitted, time: .shortened) + "–" + z.upperBound.formatted(date: .omitted, time: .shortened) + ")",
                              systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .font(.caption)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
                if panels.isEmpty && error == nil { ProgressView().padding(40) }
                ForEach(panels) { p in
                    GPanelView(panel: p, vars: vars, from: zoom?.lowerBound ?? Date().addingTimeInterval(-hours * 3600),
                               to: zoom?.upperBound ?? Date(), resolveDS: resolve) { zoom = $0 }
                        .id("\(p.id)-\(key)")
                }
            }
            .padding(12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(ref.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: hours) { _ in zoom = nil }
        .task { await load() }
    }

    private func resolve(_ ds: JSON) -> JSON {
        if case .object = ds, ds["uid"].string != nil { return ds }
        if let name = ds.string, let d = dsByName[name] { return d }
        return defaultDS
    }

    private func load() async {
        let dash: JSON
        if Launch.demo {
            dash = await DemoDash.dashboard(session)
        } else {
            guard let r = try? await session.request("/api/dashboards/uid/\(ref.id)") else { error = "Не удалось загрузить дашборд"; return }
            dash = r["dashboard"]
            for d in await session.allDatasources() {
                guard let n = d["name"].string, let uid = d["uid"].string else { continue }
                let j: JSON = .object(["uid": .string(uid), "type": .string(d["type"].string ?? "")])
                dsByName[n] = j
                if d["isDefault"].string == "true" || { if case .bool(true) = d["isDefault"] { return true }; return false }() { defaultDS = j }
            }
        }
        baseVars = DashTemplating.vars(dash)
        var d = DashTemplating.defs(dash)
        for (i, v) in dash["templating"]["list"].array.enumerated() where (v["type"].string ?? "query") == "query" {
            guard let n = v["name"].string, let k = d.firstIndex(where: { $0.name == n }), d[k].options.isEmpty else { continue }
            _ = i
            d[k].options = await DashTemplating.zabbixOptions(v, session: session, vars: baseVars)
        }
        if Launch.demo, let k = d.firstIndex(where: { $0.name == "grp" }), d[k].options.isEmpty {
            d[k].options = ["Hypervisors", "Domain Controllers", "Exchange", "Linux servers"]
        }
        defs = d
        var flat: [JSON] = []
        for p in dash["panels"].array {
            if p["type"].string == "row" { flat += p["panels"].array } else { flat.append(p) }
        }
        flat.sort { ($0["gridPos"]["y"].double ?? 0, $0["gridPos"]["x"].double ?? 0) < ($1["gridPos"]["y"].double ?? 0, $1["gridPos"]["x"].double ?? 0) }
        panels = flat.enumerated().map { i, p in
            GPanel(id: p["id"].int ?? i, title: p["title"].string ?? "", type: p["type"].string ?? "",
                   targets: p["targets"].array, datasource: p["datasource"], unit: p["fieldConfig"]["defaults"]["unit"].string,
                   text: p["options"]["content"].string ?? p["content"].string ?? "")
        }
        if panels.isEmpty { error = "В дашборде нет панелей" }
    }
}

struct GPanelView: View {
    @EnvironmentObject var session: Session
    let panel: GPanel
    let vars: [String: String]
    let from: Date
    let to: Date
    let resolveDS: (JSON) -> JSON
    var onZoom: ((ClosedRange<Date>) -> Void)? = nil
    @State private var res: PanelResult?
    @State private var visible = false

    private var hours: Double { max(0.05, to.timeIntervalSince(from) / 3600) }
    private var isStat: Bool { ["stat", "gauge", "singlestat", "bargauge", "piechart"].contains(panel.type) }
    private var isTable: Bool { panel.type == "table" || panel.type == "table-old" || panel.type == "logs" }
    private var unit: String? { panel.unit == "percent" || panel.unit == "percentunit" ? "percent" : panel.unit }

    var body: some View {
        PanelCard(title: panel.title.isEmpty ? "Без названия" : panel.title, subtitle: panel.type) {
            content.frame(minHeight: 60)
        }
        .onAppear { visible = true }
        .task(id: visible) { if visible && res == nil { await load() } }
    }

    @ViewBuilder private var content: some View {
        if panel.type == "text" {
            Text((try? AttributedString(markdown: panel.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(panel.text))
                .font(.caption)
        } else if let res {
            if let e = res.error, res.series.isEmpty, res.table == nil {
                Text(e).font(.caption).foregroundStyle(.orange)
            } else if panel.type == "logs" {
                LogsPanelBody(lines: (res.table?.rows ?? []).map { $0.joined(separator: "  ") } + res.series.compactMap(\.text))
            } else if isTable, let t = res.table {
                tableView(t)
            } else if panel.type == "gauge" {
                GaugePanelBody(series: res.series, unit: unit)
            } else if panel.type == "bargauge" {
                BarGaugePanelBody(series: res.series, unit: unit)
            } else if panel.type == "piechart" {
                PiePanelBody(series: res.series, unit: unit)
            } else if isStat {
                statView(res.series)
            } else if panel.type == "heatmap", !res.series.isEmpty {
                HeatmapPanelBody(series: res.series)
            } else if panel.type == "state-timeline" || panel.type == "status-history", !res.series.isEmpty {
                StateTimelinePanelBody(series: res.series)
            } else if !res.series.isEmpty {
                InteractiveChart(series: res.series, unit: unit, height: 170, onZoom: onZoom)
            } else if let t = res.table {
                tableView(t)
            } else {
                Text(panel.targets.isEmpty ? "Панель без запросов" : "Нет данных за период").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func chart(_ s: [Series]) -> some View {
        Chart {
            ForEach(s.prefix(8)) { ser in
                ForEach(ser.points) { p in
                    LineMark(x: .value("t", p.t), y: .value("v", p.v), series: .value("s", ser.name))
                        .foregroundStyle(by: .value("ряд", ser.name))
                }
            }
        }
        .chartLegend(s.count > 1 ? .visible : .hidden)
        .chartLegend(position: .bottom)
        .frame(height: 170)
    }

    private func statView(_ s: [Series]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
            ForEach(s.prefix(12)) { ser in
                VStack(spacing: 2) {
                    Text(ser.points.last.map { formatValue($0.v, unit: unit) } ?? (ser.text ?? "—"))
                        .font(.title2.weight(.bold).monospacedDigit()).foregroundStyle(.orange).minimumScaleFactor(0.5).lineLimit(1)
                    Text(ser.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func tableView(_ t: TableData) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow { ForEach(t.columns.indices, id: \.self) { Text(t.columns[$0]).font(.caption2.weight(.bold)) } }
                ForEach(t.rows.prefix(30).indices, id: \.self) { r in
                    GridRow { ForEach(t.rows[r].indices, id: \.self) { Text(t.rows[r][$0]).font(.caption2).lineLimit(1) } }
                }
            }
        }
    }

    private func load() async {
        guard !panel.targets.isEmpty, panel.type != "text" else { res = PanelResult(); return }
        let panelDS = resolveDS(panel.datasource)
        let queries: [JSON] = panel.targets.compactMap { t in
            if case .bool(true) = t["hide"] { return nil }
            guard case .object(var o) = DashTemplating.apply(t, vars) else { return nil }
            let tds = t["datasource"]
            let mixed = panel.datasource["uid"].string == "-- Mixed --" || panel.datasource.string == "-- Mixed --"
            o["datasource"] = (mixed || panelDS == .null) ? resolveDS(tds) : panelDS
            o["intervalMs"] = .number(max(1000, hours * 3_600_000 / 300))
            o["maxDataPoints"] = .number(300)
            return .object(o)
        }
        let body: JSON = .object(["queries": .array(queries), "from": .string(String(Int(from.timeIntervalSince1970 * 1000))),
                                  "to": .string(String(Int(to.timeIntervalSince1970 * 1000)))])
        do {
            let r = try await session.request("/api/ds/query", method: "POST", body: body)
            res = DashboardModel.parse(r, wantTable: isTable || isStat)
        } catch {
            res = PanelResult(error: error.localizedDescription)
        }
    }
}

extension JSON: Equatable {
    static func == (a: JSON, b: JSON) -> Bool {
        guard let x = try? JSONEncoder().encode(a), let y = try? JSONEncoder().encode(b) else { return false }
        return x == y
    }
}

enum DemoDash {
    static let list = [DashRef(id: "srv", title: "Серверы — обзор", folder: "Инфраструктура"),
                       DashRef(id: "net", title: "Филиалы и каналы", folder: "Сеть"),
                       DashRef(id: "mail", title: "Exchange", folder: "Сервисы")]

    @MainActor static func dashboard(_ s: Session) async -> JSON {
        let ds = await s.zabbixDS()
        let dsj: JSON = .object(["uid": .string(ds?.uid ?? "zbx"), "type": .string("alexanderzobnin-zabbix-datasource")])
        func target(_ group: String, _ host: String, _ item: String) -> JSON {
            .object(["refId": .string("A"), "queryType": .string("0"), "group": .object(["filter": .string(group)]),
                     "host": .object(["filter": .string(host)]), "item": .object(["filter": .string(item)]),
                     "application": .object(["filter": .string("")]), "itemTag": .object(["filter": .string("")]),
                     "functions": .array([]), "options": .object([:])])
        }
        func panel(_ id: Int, _ title: String, _ type: String, _ t: JSON, unit: String = "percent", y: Int) -> JSON {
            .object(["id": .number(Double(id)), "title": .string(title), "type": .string(type), "datasource": dsj,
                     "targets": .array([t]), "gridPos": .object(["x": .number(0), "y": .number(Double(y))]),
                     "fieldConfig": .object(["defaults": .object(["unit": .string(unit)])])])
        }
        return .object([
            "templating": .object(["list": .array([.object(["name": .string("grp"), "label": .string("Группа"), "type": .string("query"),
                                                             "includeAll": .bool(true), "multi": .bool(true),
                                                             "current": .object(["value": .string("$__all")])])])]),
            "panels": .array([
                .object(["id": .number(90), "type": .string("text"), "title": .string("О дашборде"), "gridPos": .object(["y": .number(0)]),
                         "options": .object(["content": .string("Дашборд из Grafana, нарисованный **нативно**: любые панели «временной ряд», «статистика» и «таблица».")])]),
                panel(1, "CPU серверов", "timeseries", target("$grp", "/.*/", "CPU utilization"), y: 1),
                panel(2, "Память сейчас", "stat", target(serverGroups, "/.*/", "Memory utilization"), y: 2),
                panel(3, "Задержка до филиалов", "timeseries", target("Mikrotik", "/.*/", "ICMP response time"), unit: "s", y: 3),
                panel(4, "Память (шкалы)", "gauge", target(serverGroups, "/.*/", "Memory utilization"), y: 4),
                panel(5, "CPU (полосы)", "bargauge", target("$grp", "/.*/", "CPU utilization"), y: 5),
                panel(6, "CPU (тепловая карта)", "heatmap", target("$grp", "/.*/", "CPU utilization"), y: 6),
                panel(7, "Доля памяти", "piechart", target(serverGroups, "/.*/", "Memory utilization"), y: 7)
            ])
        ])
    }
}

// MARK: Карты Zabbix (sysmap)

struct ZMapRef: Identifiable, Hashable { let id: String; let name: String }

struct ZMapElement: Identifiable {
    let id: String
    let x: Double
    let y: Double
    let label: String
    let hostName: String?
    let type: Int
}

struct ZMapLink: Identifiable { let id: String; let a: String; let b: String }

struct ZabbixMapsView: View {
    @EnvironmentObject var session: Session
    @State private var maps: [ZMapRef] = []
    @State private var loading = true

    var body: some View {
        List {
            if loading { ProgressView() }
            if maps.isEmpty && !loading { Text("Карт нет или нет прав на них").font(.footnote).foregroundStyle(.secondary) }
            ForEach(maps) { m in NavigationLink { ZabbixMapView(ref: m) } label: { Label(m.name, systemImage: "point.3.connected.trianglepath.dotted") } }
        }
        .navigationTitle("Карты Zabbix")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            defer { loading = false }
            if Launch.demo { maps = [ZMapRef(id: "1", name: "Сеть офиса"), ZMapRef(id: "2", name: "Филиалы")]; return }
            let r = (try? await session.zabbixResult("map.get", ["output": .array([.string("sysmapid"), .string("name")])]))?.array ?? []
            maps = r.compactMap { x in x["sysmapid"].string.map { ZMapRef(id: $0, name: x["name"].string ?? $0) } }
        }
    }
}

struct ZabbixMapView: View {
    @EnvironmentObject var session: Session
    let ref: ZMapRef
    @State private var els: [ZMapElement] = []
    @State private var links: [ZMapLink] = []
    @State private var size = CGSize(width: 800, height: 600)
    @State private var levels: [String: Level] = [:]
    @State private var zoom: CGFloat = 1
    @State private var picked: ZMapElement?

    var body: some View {
        GeometryReader { g in
            let k = g.size.width / max(size.width, 1) * zoom
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in
                        let byId = Dictionary(els.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                        for l in links {
                            guard let a = byId[l.a], let b = byId[l.b] else { continue }
                            var p = Path()
                            p.move(to: CGPoint(x: a.x * k, y: a.y * k))
                            p.addLine(to: CGPoint(x: b.x * k, y: b.y * k))
                            let bad = [a, b].contains { levelOf($0) == .bad }
                            ctx.stroke(p, with: .color(bad ? Level.bad.color.opacity(0.8) : Color.white.opacity(0.3)), lineWidth: bad ? 2.5 : 1.5)
                        }
                    }
                    .frame(width: size.width * k, height: size.height * k)
                    ForEach(els) { e in
                        VStack(spacing: 2) {
                            Image(systemName: icon(e)).font(.system(size: 18 * min(1.4, max(0.7, k))))
                                .foregroundStyle(levelOf(e).color)
                                .padding(6)
                                .background(Circle().fill(levelOf(e).color.opacity(0.18)))
                            Text(e.label).font(.system(size: 9)).lineLimit(2).multilineTextAlignment(.center).frame(width: 90)
                        }
                        .position(x: e.x * k, y: e.y * k + 10)
                        .onTapGesture { if e.hostName != nil { picked = e } }
                    }
                }
                .frame(width: size.width * k, height: size.height * k)
            }
        }
        .background(Color(white: 0.07))
        .navigationTitle(ref.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            HStack {
                Button { zoom = max(0.5, zoom / 1.4) } label: { Image(systemName: "minus.magnifyingglass") }
                Button { zoom = min(4, zoom * 1.4) } label: { Image(systemName: "plus.magnifyingglass") }
            }
        }
        .sheet(item: $picked) { e in
            NavigationStack { HostExplorerView(host: HostMini(id: e.id, name: e.hostName ?? "")) }
        }
        .task { await load() }
    }

    private func levelOf(_ e: ZMapElement) -> Level { e.hostName.map { levels[$0] ?? .ok } ?? .none }

    private func icon(_ e: ZMapElement) -> String {
        let n = (e.hostName ?? e.label).lowercased()
        if n.contains("mikrotik") || n.contains("router") || n.contains("маршрут") { return "wifi.router" }
        if n.contains("switch") || n.contains("коммут") { return "switch.2" }
        if n.contains("msa") || n.contains("synology") || n.contains("storage") { return "externaldrive.connected.to.line.below" }
        if e.type == 1 { return "map" }
        if e.type == 3 { return "square.stack.3d.up" }
        if e.type == 4 { return "photo" }
        return "server.rack"
    }

    private func load() async {
        levels = hostLevels((try? await session.loadProblems()) ?? [])
        if Launch.demo {
            size = CGSize(width: 700, height: 460)
            let names = ["Маршрутизатор ЦОД", "Коммутатор ядра", "HYPER1", "HYPER2", "HYPER3", "MSA 2040", "Synology DS423+", "DC1", "MBX3"]
            let pos: [(Double, Double)] = [(350, 50), (350, 150), (120, 270), (260, 270), (400, 270), (200, 400), (520, 400), (560, 270), (650, 150)]
            els = names.enumerated().map { ZMapElement(id: "\($0.offset)", x: pos[$0.offset].0, y: pos[$0.offset].1, label: $0.element, hostName: $0.element, type: 0) }
            links = [(0, 1), (1, 2), (1, 3), (1, 4), (2, 5), (3, 5), (4, 5), (4, 6), (1, 7), (1, 8)].map { ZMapLink(id: "\($0.0)-\($0.1)", a: "\($0.0)", b: "\($0.1)") }
            return
        }
        guard let m = (try? await session.zabbixResult("map.get", [
            "sysmapids": .array([.string(ref.id)]), "output": .array(["width", "height"].map { .string($0) }),
            "selectSelements": .array(["selementid", "elements", "elementtype", "label", "x", "y"].map { .string($0) }),
            "selectLinks": .array(["linkid", "selementid1", "selementid2"].map { .string($0) })
        ]))?.array.first else { return }
        size = CGSize(width: Double(m["width"].string ?? "") ?? 800, height: Double(m["height"].string ?? "") ?? 600)
        let sel = m["selements"].array
        let hostIds = sel.filter { $0["elementtype"].string == "0" }.compactMap { $0["elements"][0]["hostid"].string }
        var names: [String: String] = [:]
        if !hostIds.isEmpty {
            let hs = (try? await session.zabbixResult("host.get", ["hostids": .array(hostIds.map { .string($0) }),
                                                                   "output": .array([.string("hostid"), .string("name")])]))?.array ?? []
            for h in hs { if let id = h["hostid"].string { names[id] = h["name"].string } }
        }
        els = sel.compactMap { s in
            guard let id = s["selementid"].string else { return nil }
            let type = Int(s["elementtype"].string ?? "") ?? 4
            let hid = s["elements"][0]["hostid"].string
            let hn = hid.flatMap { names[$0] }
            var label = s["label"].string ?? ""
            label = label.replacingOccurrences(of: "{HOST.NAME}", with: hn ?? "").replacingOccurrences(of: "{HOST.HOST}", with: hn ?? "")
            label = label.replacingOccurrences(of: "\\{[^}]+\\}", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            // x/y в Zabbix — левый верхний угол значка (~48 px)
            return ZMapElement(id: hid ?? id, x: (Double(s["x"].string ?? "") ?? 0) + 24, y: (Double(s["y"].string ?? "") ?? 0) + 24,
                               label: label.isEmpty ? (hn ?? "") : label, hostName: hn, type: type)
        }
        // связи ссылаются на selementid, а элементы хостов — на hostid: построим соответствие
        var idMap: [String: String] = [:]
        for s in sel { if let sid = s["selementid"].string { idMap[sid] = s["elements"][0]["hostid"].string ?? sid } }
        links = m["links"].array.compactMap { l in
            guard let a = l["selementid1"].string, let b = l["selementid2"].string else { return nil }
            return ZMapLink(id: l["linkid"].string ?? a + b, a: idMap[a] ?? a, b: idMap[b] ?? b)
        }
    }
}

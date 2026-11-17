import SwiftUI
import CoreImage.CIFilterBuiltins
import VisionKit
import CoreSpotlight
import UniformTypeIdentifiers
import AppIntents
#if canImport(FoundationModels)
import FoundationModels
#endif

// v2.7: обслуживание и скрипты Zabbix, массовое подтверждение, аварии, QR-наклейки,
// Spotlight, фокус «Дежурство», «Спроси у мониторинга».

// MARK: Запросы Zabbix, которые возвращают объект

extension ZabbixDirect {
    static func result(_ c: Config, method: String, params: [String: JSON]) async throws -> JSON {
        var req = URLRequest(url: c.url, timeoutInterval: 30)
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
        return r["result"]
    }
}

struct ZScript: Identifiable, Hashable {
    let id: String
    let name: String
    let confirmation: String
    var type = "0"        // 6 = ссылка (URL), остальные выполняются на сервере/прокси
    var url = ""
    var isLink: Bool { type == "6" }
}

/// Понятное объяснение типовых отказов Zabbix при запуске скриптов.
func explainScriptError(_ e: Error) -> String {
    let m = e.localizedDescription
    if m.contains("Remote commands are not enabled") {
        return "Хост опрашивается через прокси Zabbix, а на прокси выключены удалённые команды. Чтобы скрипты заработали, администратор включает EnableRemoteCommands=1 в zabbix_proxy.conf и перезапускает прокси. Ссылки из раздела «Открыть» работают и без этого."
    }
    if m.contains("Global script execution") {
        return "На сервере Zabbix выключено выполнение скриптов. Чтобы они заработали, администратор включает EnableGlobalScripts=1 в zabbix_server.conf и перезапускает сервер. Ссылки из раздела «Открыть» работают и без этого."
    }
    if m.lowercased().contains("permission") || m.contains("No permissions") {
        return "У пользователя Zabbix нет прав на этот скрипт или хост. Проверьте токен в Настройках → «Подтверждение проблем».\n\n" + m
    }
    return m
}

extension Session {
    /// Ответ Zabbix целиком. Напрямую по токену, если он задан в настройках, иначе через Grafana.
    func zabbixResult(_ method: String, _ params: [String: JSON]) async throws -> JSON {
        if !demo, let d = ZabbixDirect.config { return try await ZabbixDirect.result(d, method: method, params: params) }
        guard let ds = await zabbixDS() else { throw APIError(message: "Источник данных Zabbix не найден") }
        let body: JSON = .object(["datasourceId": .number(Double(ds.id)), "method": .string(method), "params": .object(params)])
        let r = try await request("/api/datasources/uid/\(ds.uid)/resources/zabbix-api", method: "POST", body: body)
        if !r["error"].isNull {
            let e = r["error"]
            let msg = [e["message"].string, e["data"].string].compactMap { $0 }.joined(separator: ": ")
            throw APIError(message: "Zabbix отказал: " + (msg.isEmpty ? "неизвестная ошибка" : msg))
        }
        return r["result"]
    }

    func createMaintenance(host: HostMini, hours: Int, note: String) async throws {
        let now = Int(Date().timeIntervalSince1970)
        let sec = hours * 3600
        _ = try await zabbixResult("maintenance.create", [
            "name": .string("Мобильное приложение: \(host.name) — \(note.isEmpty ? "плановые работы" : note) (\(now))"),
            "active_since": .number(Double(now)),
            "active_till": .number(Double(now + sec)),
            "maintenance_type": .number(0),
            "description": .string(note),
            "hosts": .array([.object(["hostid": .string(host.id)])]),
            "timeperiods": .array([.object(["timeperiod_type": .number(0), "start_date": .number(Double(now)),
                                            "period": .number(Double(sec))])])
        ])
    }

    func hostScripts(_ hostId: String) async throws -> [ZScript] {
        let r = try await zabbixResult("script.get", [
            "hostids": .array([.string(hostId)]),
            "output": .array(["scriptid", "name", "scope", "confirmation", "type", "url"].map { .string($0) })
        ])
        return r.array.compactMap { s in
            guard let id = s["scriptid"].string, let n = s["name"].string else { return nil }
            if let sc = s["scope"].string, sc != "2" { return nil }
            return ZScript(id: id, name: n, confirmation: s["confirmation"].string ?? "",
                           type: s["type"].string ?? "0", url: s["url"].string ?? "")
        }
    }

    /// Адрес хоста для {HOST.CONN}: IP или DNS основного интерфейса.
    func hostConn(_ hostId: String) async -> String? {
        let r = try? await zabbixResult("hostinterface.get", [
            "hostids": .array([.string(hostId)]),
            "output": .array(["ip", "dns", "useip", "main"].map { .string($0) })
        ])
        let list = r?.array ?? []
        guard let i = list.first(where: { $0["main"].string == "1" }) ?? list.first else { return nil }
        let ip = i["ip"].string ?? "", dns = i["dns"].string ?? ""
        return (i["useip"].string == "0" && !dns.isEmpty) ? dns : (ip.isEmpty ? dns : ip)
    }

    /// Готовая ссылка для скрипта-ссылки, или nil, если её не собрать.
    func linkURL(_ s: ZScript, host: HostMini, conn: String?) -> URL? {
        var u = s.url
        u = u.replacingOccurrences(of: "{HOST.ID}", with: host.id)
        u = u.replacingOccurrences(of: "{HOST.NAME}", with: host.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? host.name)
        u = u.replacingOccurrences(of: "{HOST.HOST}", with: host.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? host.name)
        if u.contains("{HOST.CONN}") || u.contains("{HOST.IP}") || u.contains("{HOST.DNS}") {
            guard let conn else { return nil }
            for m in ["{HOST.CONN}", "{HOST.IP}", "{HOST.DNS}"] { u = u.replacingOccurrences(of: m, with: conn) }
        }
        if u.contains("{") { return nil }
        if u.hasPrefix("http://") || u.hasPrefix("https://") { return URL(string: u) }
        // относительная ссылка на веб-интерфейс Zabbix — нужен адрес Zabbix из настроек
        guard let api = ZabbixDirect.config?.url ?? (demo ? URL(string: "https://zabbix.example.com/api_jsonrpc.php") : nil) else { return nil }
        return URL(string: u, relativeTo: api.deletingLastPathComponent())?.absoluteURL
    }

    func runScript(_ s: ZScript, hostId: String) async throws -> String {
        let r = try await zabbixResult("script.execute", ["scriptid": .string(s.id), "hostid": .string(hostId)])
        let v = r["value"].string ?? ""
        return v.isEmpty ? (r["response"].string ?? "Готово") : v
    }

    func acknowledgeMany(_ ids: [String], message: String) async throws {
        let params: [String: JSON] = [
            "eventids": .array(ids.map { .string($0) }),
            "action": .number(message.isEmpty ? 2 : 6),
            "message": .string(message)
        ]
        if !demo, let d = ZabbixDirect.config {
            try await ZabbixDirect.call(d, method: "event.acknowledge", params: params)
        } else {
            _ = try await zabbix("event.acknowledge", params)
        }
    }
}

// MARK: Действия с хостом

struct HostActionsSection: View {
    let host: HostMini
    @State private var maintenance = false
    @State private var scripts = Launch.screen == "scripts"
    @State private var qr = false

    var body: some View {
        Section("Действия") {
            Button { maintenance = true } label: { Label("Плановые работы…", systemImage: "wrench.and.screwdriver") }
            Button { scripts = true } label: { Label("Диагностика: скрипты Zabbix…", systemImage: "terminal") }
            Button { qr = true } label: { Label("QR-наклейка для стойки", systemImage: "qrcode") }
        }
        .sheet(isPresented: $maintenance) { MaintenanceSheet(host: host) }
        .sheet(isPresented: $scripts) { ScriptsSheet(host: host) }
        .sheet(isPresented: $qr) { QRStickerSheet(fixed: [host]) }
    }
}

struct MaintenanceSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let host: HostMini
    @State private var hours = 1
    @State private var note = ""
    @State private var confirm = false
    @State private var busy = false
    @State private var result: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Длительность", selection: $hours) {
                        Text("1 час").tag(1); Text("4 часа").tag(4); Text("24 часа").tag(24)
                    }
                    .pickerStyle(.segmented)
                    TextField("Причина, например: замена диска", text: $note)
                } header: { Text(host.name) } footer: {
                    Text("В Zabbix создаётся обслуживание со сбором данных: графики пишутся, но проблемы хоста не уведомляют, пока оно идёт. Нужен токен Zabbix с правом создавать обслуживание (Настройки → Подтверждение проблем) или права записи у пользователя Grafana.")
                }
                if let result { Section { Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(.green) } }
                if let error { Section { Text(error).foregroundStyle(.orange).font(.footnote) } }
                Section {
                    Button { confirm = true } label: {
                        HStack { Spacer(); if busy { ProgressView() } else { Text("Включить обслуживание").bold() }; Spacer() }
                    }
                    .disabled(busy || result != nil)
                }
            }
            .navigationTitle("Плановые работы")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } } }
            .confirmationDialog("Создать в Zabbix обслуживание для \(host.name) на \(hours) ч?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Да, создать") {
                    busy = true; error = nil
                    Task {
                        do {
                            try await session.createMaintenance(host: host, hours: hours, note: note)
                            result = "Обслуживание включено до \(Date().addingTimeInterval(Double(hours) * 3600).formatted(date: .omitted, time: .shortened))"
                            Annotations.shared.add(key: "panels", date: Date(), text: "Работы: \(host.name)")
                            Haptics.success()
                        } catch { self.error = error.localizedDescription; Haptics.error() }
                        busy = false
                    }
                }
                Button("Отмена", role: .cancel) {}
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct ScriptsSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let host: HostMini
    @State private var scripts: [ZScript] = []
    @State private var loading = true
    @State private var pending: ZScript?
    @State private var running: String?
    @State private var output: String?
    @State private var error: String?
    @State private var conn: String?
    @Environment(\.openURL) private var openURL

    private var links: [ZScript] { scripts.filter(\.isLink) }
    private var commands: [ZScript] { scripts.filter { !$0.isLink } }

    var body: some View {
        NavigationStack {
            List {
                if loading { Section { ProgressView() } }
                if !loading && scripts.isEmpty && error == nil {
                    Section { Text("Для этого хоста в Zabbix нет скриптов, доступных для ручного запуска.").font(.footnote).foregroundStyle(.secondary) }
                }
                if !links.isEmpty {
                    Section {
                        ForEach(links) { s in
                            if let u = session.linkURL(s, host: host, conn: conn) {
                                Button { openURL(u) } label: {
                                    HStack {
                                        Label(s.name, systemImage: "arrow.up.right.square")
                                        Spacer()
                                        Text(u.host ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            } else {
                                Label(s.name, systemImage: "link").foregroundStyle(.secondary)
                            }
                        }
                    } header: { Text("Открыть") } footer: {
                        Text(links.contains { session.linkURL($0, host: host, conn: conn) == nil }
                             ? "Серые ссылки ведут в веб-интерфейс Zabbix: укажите адрес Zabbix в Настройках → «Подтверждение проблем»."
                             : "Ссылки открываются в Safari.")
                    }
                }
                if !commands.isEmpty {
                    Section {
                        ForEach(commands) { s in
                            Button { pending = s } label: {
                                HStack {
                                    Label(s.name, systemImage: "play.circle")
                                    Spacer()
                                    if running == s.id { ProgressView() }
                                }
                            }
                            .disabled(running != nil)
                        }
                    } header: { Text("Выполнить на сервере Zabbix") } footer: {
                        Text("Команду выполняет сервер Zabbix или прокси и возвращает вывод сюда. Перед запуском всегда спрашиваю подтверждение.")
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.orange).font(.footnote) } }
                if let output {
                    Section("Результат") {
                        ScrollView(.horizontal) {
                            Text(output).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                        ShareLink(item: output) { Label("Поделиться выводом", systemImage: "square.and.arrow.up") }
                    }
                }
            }
            .navigationTitle("Скрипты Zabbix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } } }
            .confirmationDialog(pending.map { $0.confirmation.isEmpty ? "Запустить «\($0.name)» на \(host.name)?" : $0.confirmation } ?? "",
                                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                                titleVisibility: .visible, presenting: pending) { s in
                Button("Запустить") { run(s) }
                Button("Отмена", role: .cancel) {}
            }
            .task {
                do { scripts = try await session.hostScripts(host.id) } catch { self.error = explainScriptError(error) }
                if scripts.contains(where: \.isLink) { conn = await session.hostConn(host.id) }
                loading = false
                if Launch.screen == "scripts", let s = commands.first { run(s) }
            }
        }
    }

    private func run(_ s: ZScript) {
        running = s.id; error = nil
        Task {
            do { output = try await session.runScript(s, hostId: host.id); Haptics.success() }
            catch { output = nil; self.error = explainScriptError(error); Haptics.error() }
            running = nil
        }
    }
}

// MARK: Аварии

struct IncidentEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var text: String
}

struct Incident: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var created: Date
    var closed: Date?
    var problems: [String]
    var log: [IncidentEntry]

    var elapsed: TimeInterval { (closed ?? Date()).timeIntervalSince(created) }

    var report: String {
        var s = "Авария: \(title)\nНачало: \(ruDate(created))\n"
        s += closed.map { "Окончание: \(ruDate($0))\n" } ?? "Статус: продолжается\n"
        s += "Длительность: \(duration(seconds: elapsed))\n"
        if !problems.isEmpty { s += "\nПроблемы:\n" + problems.map { "• " + $0 }.joined(separator: "\n") + "\n" }
        if !log.isEmpty {
            let f = DateFormatter(); f.dateFormat = "dd.MM HH:mm"
            s += "\nХронология:\n" + log.sorted { $0.date < $1.date }.map { "\(f.string(from: $0.date)) — \($0.text)" }.joined(separator: "\n")
        }
        return s
    }
}

final class IncidentStore: ObservableObject {
    static let shared = IncidentStore()
    @Published var items: [Incident] { didSet { save() } }

    init() {
        if let d = UserDefaults.standard.data(forKey: "incidents"), let v = try? JSONDecoder().decode([Incident].self, from: d) {
            items = v
        } else if Launch.demo {
            let now = Date()
            items = [
                Incident(title: "Нет связи с Калининградом", created: now.addingTimeInterval(-7200), closed: nil,
                         problems: ["Mikrotik - Kaliningrad: нет ответа на ICMP ping — Mikrotik - Kaliningrad"],
                         log: [IncidentEntry(date: now.addingTimeInterval(-7100), text: "Пропал пинг, филиал не отвечает"),
                               IncidentEntry(date: now.addingTimeInterval(-6600), text: "Позвонил провайдеру, заявка 48213"),
                               IncidentEntry(date: now.addingTimeInterval(-3000), text: "Провайдер: авария на магистрали, срок 3 часа")]),
                Incident(title: "Переполнение очереди Exchange", created: now.addingTimeInterval(-3 * 86400),
                         closed: now.addingTimeInterval(-3 * 86400 + 5400),
                         problems: ["Exchange: очередь доставки больше 100 писем — MBX2"],
                         log: [IncidentEntry(date: now.addingTimeInterval(-3 * 86400 + 600), text: "Перезапущена служба транспорта")])
            ]
        } else {
            items = []
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: "incidents") }
    }

    @discardableResult
    func create(from problems: [Problem]) -> Incident {
        let worst = problems.max { $0.severity < $1.severity }
        let i = Incident(title: worst.map { $0.host.isEmpty ? $0.name : "\($0.host): \($0.name)" } ?? "Авария",
                         created: problems.map { $0.clock }.min() ?? Date(), closed: nil,
                         problems: problems.map { $0.host.isEmpty ? $0.name : "\($0.name) — \($0.host)" },
                         log: [IncidentEntry(date: Date(), text: "Авария открыта, проблем: \(problems.count)")])
        items.insert(i, at: 0)
        return i
    }
}

struct IncidentsView: View {
    @ObservedObject private var store = IncidentStore.shared
    @State private var adding = false
    @State private var newTitle = ""

    var body: some View {
        List {
            if store.items.isEmpty {
                Text("Аварий нет. Выберите несколько проблем в списке («Выбрать») и нажмите «В аварию», или создайте её кнопкой «+».")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(store.items.sorted { ($0.closed == nil ? 1 : 0, $0.created) > ($1.closed == nil ? 1 : 0, $1.created) }) { i in
                NavigationLink { IncidentDetailView(id: i.id) } label: {
                    HStack(spacing: 10) {
                        Circle().fill(i.closed == nil ? Level.bad.color : Level.ok.color).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(i.title).lineLimit(2)
                            Text((i.closed == nil ? "идёт " : "закрыта · длилась ") + duration(seconds: i.elapsed))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onDelete { idx in
                let sorted = store.items.sorted { ($0.closed == nil ? 1 : 0, $0.created) > ($1.closed == nil ? 1 : 0, $1.created) }
                let ids = Set(idx.map { sorted[$0].id })
                store.items.removeAll { ids.contains($0.id) }
            }
        }
        .navigationTitle("Аварии")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { adding = true } label: { Image(systemName: "plus") } } }
        .alert("Новая авария", isPresented: $adding) {
            TextField("Например: нет связи с офисом", text: $newTitle)
            Button("Создать") {
                let t = newTitle.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty {
                    store.items.insert(Incident(title: t, created: Date(), closed: nil, problems: [],
                                                log: [IncidentEntry(date: Date(), text: "Авария открыта")]), at: 0)
                }
                newTitle = ""
            }
            Button("Отмена", role: .cancel) { newTitle = "" }
        }
    }
}

struct IncidentDetailView: View {
    let id: UUID
    @ObservedObject private var store = IncidentStore.shared
    @State private var text = ""

    private var idx: Int? { store.items.firstIndex { $0.id == id } }

    var body: some View {
        if let i = idx {
            let inc = store.items[i]
            List {
                Section {
                    Text(inc.title).font(.headline)
                    LabeledContent("Начало", value: ruDate(inc.created))
                    LabeledContent(inc.closed == nil ? "Идёт" : "Длилась", value: duration(seconds: inc.elapsed))
                    Button(inc.closed == nil ? "Закрыть аварию" : "Открыть снова") {
                        let closing = store.items[i].closed == nil
                        store.items[i].closed = closing ? Date() : nil
                        store.items[i].log.append(IncidentEntry(date: Date(), text: closing ? "Авария закрыта" : "Авария открыта снова"))
                        Haptics.success()
                    }
                    ShareLink(item: inc.report) { Label("Разбор для руководителя", systemImage: "doc.text") }
                }
                if !inc.problems.isEmpty {
                    Section("Проблемы") { ForEach(inc.problems, id: \.self) { Text($0).font(.footnote) } }
                }
                Section("Хронология") {
                    HStack {
                        TextField("Что произошло или сделано", text: $text, axis: .vertical)
                        Button {
                            store.items[i].log.append(IncidentEntry(date: Date(), text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
                            text = ""; Haptics.tap()
                        } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    ForEach(inc.log.sorted { $0.date > $1.date }) { e in
                        HStack(alignment: .top, spacing: 10) {
                            Text(e.date.formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit())
                                .foregroundStyle(.orange).frame(width: 48, alignment: .leading)
                            Text(e.text).font(.subheadline)
                        }
                    }
                }
            }
            .navigationTitle("Авария")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            Text("Авария удалена").foregroundStyle(.secondary)
        }
    }
}

// MARK: Ссылки на хост (QR, Spotlight)

@MainActor
final class DeepLink: ObservableObject {
    static let shared = DeepLink()
    @Published var host: HostMini?

    static func url(_ h: HostMini) -> String {
        "grafanaapp://host/\(h.id)?name=" + (h.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? h.name)
    }

    func open(url: URL) {
        guard url.scheme == "grafanaapp", url.host == "host" else { return }
        let id = url.pathComponents.filter { $0 != "/" }.first ?? ""
        let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "name" }?.value ?? id
        if !id.isEmpty { host = HostMini(id: id, name: name) }
    }

    func openSpotlight(_ identifier: String) {
        let p = identifier.split(separator: "|", maxSplits: 2).map(String.init)
        if p.count == 3, p[0] == "host" { host = HostMini(id: p[1], name: p[2]) }
    }
}

enum SpotlightIndex {
    static func index(_ hosts: [(id: String, name: String)]) {
        guard !hosts.isEmpty else { return }
        let items = hosts.map { h -> CSSearchableItem in
            let a = CSSearchableItemAttributeSet(contentType: UTType.text)
            a.title = h.name
            a.contentDescription = "Хост в мониторинге Zabbix"
            a.keywords = ["zabbix", "хост", "сервер"]
            return CSSearchableItem(uniqueIdentifier: "host|\(h.id)|\(h.name)", domainIdentifier: "hosts", attributeSet: a)
        }
        CSSearchableIndex.default().indexSearchableItems(items) { _ in }
    }
}

extension Session {
    /// Хосты серверов и сети в поиск iPhone (Spotlight): раз в сутки.
    func indexSpotlight() async {
        let last = UserDefaults.standard.double(forKey: "spotlightAt")
        guard Date().timeIntervalSince1970 - last > 86400 else { return }
        var out: [(id: String, name: String)] = []
        for id in ["servers", "net"] {
            if let s = systemScreens.first(where: { $0.id == id }),
               let hs = try? await matchedHosts(group: s.group, host: "/.*/") {
                out += hs.map { ($0.id, $0.name) }
            }
        }
        guard !out.isEmpty else { return }
        SpotlightIndex.index(out)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "spotlightAt")
    }
}

func qrImage(_ s: String, scale: CGFloat = 10) -> UIImage? {
    let f = CIFilter.qrCodeGenerator()
    f.message = Data(s.utf8)
    f.correctionLevel = "M"
    guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
          let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
    return UIImage(cgImage: cg)
}

struct QRSticker: View {
    let host: HostMini

    var body: some View {
        VStack(spacing: 6) {
            if let img = qrImage(DeepLink.url(host)) {
                Image(uiImage: img).interpolation(.none).resizable().scaledToFit().frame(width: 120, height: 120)
            }
            Text(host.name).font(.system(size: 11, weight: .bold)).foregroundStyle(.black).lineLimit(2)
                .multilineTextAlignment(.center)
            Text("Grafana · откройте камерой").font(.system(size: 8)).foregroundStyle(.gray)
        }
        .padding(10)
        .frame(width: 160)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

struct QRStickerSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    var fixed: [HostMini]? = nil
    @State private var hosts: [HostMini] = []

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.fixed(166)), GridItem(.fixed(166)), GridItem(.fixed(166))], spacing: 10) {
            ForEach(hosts) { QRSticker(host: $0) }
        }
        .padding(12)
        .background(Color.white)
    }

    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                if hosts.isEmpty { ProgressView().padding(40) } else { grid }
            }
            .background(Color(white: 0.07))
            .navigationTitle("QR-наклейки (\(hosts.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { makePDF() } label: { Label("PDF", systemImage: "printer") }.disabled(hosts.isEmpty)
                }
            }
            .task {
                if let fixed { hosts = fixed; return }
                var out: [HostMini] = []
                for id in ["servers", "net"] {
                    if let s = systemScreens.first(where: { $0.id == id }) {
                        out += (try? await session.matchedHosts(group: s.group, host: "/.*/")) ?? []
                    }
                }
                hosts = out.sorted { $0.name < $1.name }
            }
        }
    }

    @MainActor private func makePDF() {
        let r = ImageRenderer(content: grid.frame(width: 540).environment(\.colorScheme, .light))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("QR-stickers.pdf")
        r.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil); draw(ctx); ctx.endPDFPage(); ctx.closePDF()
        }
        presentShare([url])
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                           recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                           isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        DispatchQueue.main.async { try? vc.startScanning() }
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFound) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (String) -> Void
        var done = false
        init(_ f: @escaping (String) -> Void) { onFound = f }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in addedItems {
                if case .barcode(let b) = item, let v = b.payloadStringValue {
                    done = true
                    dataScanner.stopScanning()
                    onFound(v)
                    return
                }
            }
        }
    }
}

struct QRScanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var note: String?

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    QRScannerView { v in
                        guard let u = URL(string: v), u.scheme == "grafanaapp" else { note = "Это не наклейка приложения: \(v)"; return }
                        dismiss()
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            DeepLink.shared.open(url: u)
                        }
                    }
                    .ignoresSafeArea()
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.metering.unknown").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Сканер недоступен: нужна камера и разрешение на неё (Настройки iOS → Grafana → Камера). Можно навести и обычную камеру iPhone — наклейка откроет приложение.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }
                    .padding(30)
                }
            }
            .overlay(alignment: .bottom) {
                if let note { Text(note).font(.caption).padding(10).background(.ultraThinMaterial, in: Capsule()).padding() }
            }
            .navigationTitle("Наведите на наклейку")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } } }
        }
    }
}

// MARK: Фокус «Дежурство»

struct DutyFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "Дежурство"
    static var description = IntentDescription("Пока включён этот фокус, в списке проблем видны только высокие и чрезвычайные.")

    @Parameter(title: "Только высокие и выше", default: true)
    var onlyHigh: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: onlyHigh ? "Только высокие и выше" : "Все проблемы")
    }

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(onlyHigh ? 4 : 3, forKey: "minSeverity")
        return .result()
    }
}

// MARK: Спроси у мониторинга

enum MonitorContext {
    static func lastLine(_ s: [Series], unit: String) -> [String: Double] {
        var m: [String: Double] = [:]
        for x in s { if let v = x.points.last?.v { m[x.name] = unit == "s" ? v * 1000 : v } }
        return m
    }

    static func text(problems: [Problem], cpu: [String: Double], mem: [String: Double], rtt: [String: Double]) -> String {
        var lines: [String] = ["Активные проблемы (\(problems.count)):"]
        for p in problems.sorted(by: { $0.severity > $1.severity }).prefix(25) {
            lines.append("- [\(sevName(p.severity))] \(p.name); хост \(p.host); длится \(duration(seconds: Date().timeIntervalSince(p.clock)))")
        }
        lines.append("Загрузка серверов сейчас (CPU %, RAM %):")
        for (h, c) in cpu.sorted(by: { $0.value > $1.value }).prefix(12) {
            lines.append("- \(h): CPU \(Int(c))%" + (mem[h].map { ", RAM \(Int($0))%" } ?? ""))
        }
        lines.append("Задержка до филиалов, мс:")
        for (h, r) in rtt.sorted(by: { $0.value > $1.value }).prefix(10) { lines.append("- \(h): \(Int(r)) мс") }
        return lines.joined(separator: "\n")
    }

    static func keys(for question: String) -> [String] {
        let q = question.lowercased()
        var k: [String] = []
        let syn: [(String, [String])] = [
            ("почт", ["mbx", "exchange"]), ("exchange", ["mbx", "exchange"]), ("филиал", ["mikrotik", "icmp"]),
            ("связ", ["mikrotik", "icmp"]), ("сеть", ["mikrotik", "icmp"]), ("диск", ["space", "fs ", "диск"]),
            ("мест", ["space", "fs "]), ("контроллер", ["dc"]), ("домен", ["dc", "ad"]), ("бэкап", ["veeam"]),
            ("резерв", ["veeam"]), ("гипервиз", ["hyper"]), ("виртуал", ["hyper", "вм"]), ("хранилищ", ["msa", "storage", "synology"]),
            ("сертификат", ["ssl"]), ("антивирус", ["kasper", "kes"])
        ]
        for (w, ks) in syn where q.contains(w) { k += ks }
        for b in BranchStore.shared.items where !b.city.isEmpty && q.contains(String(b.city.lowercased().prefix(4))) {
            k.append(b.host.lowercased())
        }
        let words = q.components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted).filter { $0.count >= 3 }
        k += words.filter { w in w.unicodeScalars.allSatisfy { $0.isASCII } }
        return Array(Set(k))
    }

    static func fallback(question: String, problems: [Problem], cpu: [String: Double], mem: [String: Double], rtt: [String: Double]) -> String {
        let k = keys(for: question)
        let hit = problems.filter { p in k.contains { p.name.lowercased().contains($0) || p.host.lowercased().contains($0) } }
        var out: [String] = []
        if hit.isEmpty {
            out.append("По запросу совпадений среди проблем нет.")
            out.append("Всего активных проблем: \(problems.count).")
            if let w = problems.max(by: { $0.severity < $1.severity }) { out.append("Самая серьёзная: \(w.name) (\(w.host)).") }
        } else {
            out.append("Проблем по запросу: \(hit.count).")
            for p in hit.sorted(by: { $0.severity > $1.severity }).prefix(6) {
                out.append("• [\(sevName(p.severity))] \(p.name) — \(p.host), \(duration(seconds: Date().timeIntervalSince(p.clock)))")
            }
        }
        let hosts = Set(cpu.keys).union(rtt.keys).filter { h in k.contains { h.lowercased().contains($0) } }
        if !hosts.isEmpty {
            out.append("")
            out.append("Сейчас:")
            for h in hosts.sorted().prefix(8) {
                var parts: [String] = []
                if let c = cpu[h] { parts.append("CPU \(Int(c))%") }
                if let m = mem[h] { parts.append("RAM \(Int(m))%") }
                if let r = rtt[h] { parts.append("задержка \(Int(r)) мс") }
                out.append("• \(h): " + parts.joined(separator: ", "))
            }
        }
        return out.joined(separator: "\n")
    }
}

#if canImport(FoundationModels)
@available(iOS 26, *)
enum OnDeviceLLM {
    static func answer(question: String, context: String) async -> String? {
        let m = SystemLanguageModel.default
        guard case .available = m.availability else { return nil }
        let s = LanguageModelSession(instructions: "Ты помощник дежурного системного администратора. Отвечай по-русски, коротко и по пунктам, только на основе данных мониторинга из запроса. Если данных не хватает, так и скажи.")
        do {
            let r = try await s.respond(to: "Данные мониторинга:\n\(context)\n\nВопрос: \(question)")
            return r.content
        } catch {
            return nil
        }
    }
}
#endif

struct AskView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var q = Launch.screen == "ask" ? "Что сейчас с почтой?" : ""
    @State private var answer: String?
    @State private var source = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Например: что с почтой? почему тормозит Казань?", text: $q, axis: .vertical).lineLimit(1...4)
                    Button { Task { await ask() } } label: {
                        HStack { Label("Спросить", systemImage: "sparkles"); Spacer(); if busy { ProgressView() } }
                    }
                    .disabled(busy || q.trimmingCharacters(in: .whitespaces).isEmpty)
                } footer: {
                    Text("Можно надиктовать с клавиатуры (значок микрофона). Отвечает модель Apple прямо на телефоне — нужен iOS 26 с включённым Apple Intelligence, данные никуда не отправляются. Если модель недоступна, показываю поиск по проблемам и нагрузке.")
                }
                if let answer {
                    Section(source) {
                        Text(answer).font(.subheadline).textSelection(.enabled)
                        ShareLink(item: answer) { Label("Поделиться", systemImage: "square.and.arrow.up") }
                    }
                }
            }
            .navigationTitle("Спроси у мониторинга")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } } }
            .task { if Launch.screen == "ask" { await ask() } }
        }
    }

    private func ask() async {
        busy = true
        defer { busy = false }
        let probs = (try? await session.loadProblems()) ?? []
        let cpu = MonitorContext.lastLine((try? await session.hostSeries(host: "/.*/", filter: "CPU utilization", seconds: 3600,
                                                                          group: serverGroups, maxPoints: 20)) ?? [], unit: "percent")
        let mem = MonitorContext.lastLine((try? await session.hostSeries(host: "/.*/", filter: "Memory utilization", seconds: 3600,
                                                                          group: serverGroups, maxPoints: 20)) ?? [], unit: "percent")
        let rtt = MonitorContext.lastLine((try? await session.hostSeries(host: "/.*/", filter: "ICMP response time", seconds: 3600,
                                                                          group: "Mikrotik", maxPoints: 20)) ?? [], unit: "s")
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            let ctx = MonitorContext.text(problems: probs, cpu: cpu, mem: mem, rtt: rtt)
            if let a = await OnDeviceLLM.answer(question: q, context: ctx) {
                answer = a; source = "Ответ модели Apple (на телефоне)"; Haptics.success(); return
            }
        }
        #endif
        answer = MonitorContext.fallback(question: q, problems: probs, cpu: cpu, mem: mem, rtt: rtt)
        source = "Поиск по данным (модель Apple недоступна)"
        Haptics.tap()
    }
}

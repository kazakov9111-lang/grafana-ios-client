import Foundation

/// Параметры запуска для проверки в симуляторе: --demo --tab 1 --open ad --block 3 --check 2 --problem 0
enum Launch {
    static let args = ProcessInfo.processInfo.arguments
    static func value(_ key: String) -> String? {
        guard let i = args.firstIndex(of: key), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }
    static var demo: Bool { args.contains("--demo") }
    static var tab: Int { value("--tab").flatMap(Int.init) ?? 0 }
    static var check: Int? { value("--check").flatMap(Int.init) }
    static var problem: Int? { value("--problem").flatMap(Int.init) }
    static var system: String? { value("--system") }
    static var host: Int? { value("--host").flatMap(Int.init) }
    static var history: Bool { args.contains("--history") }
    static var charts: Bool { args.contains("--charts") }
    static var panels: Int? { value("--panels").flatMap(Int.init) }
    static var search: String? { value("--search") }
    static var explorer: String? { value("--explorer") }
    static var screen: String? { value("--screen") }
    static var panelSet: [String]? { value("--panelset")?.split(separator: ",").map(String.init) }
}

/// Примерные данные, похожие на реальные, — чтобы проверять вёрстку без входа.
enum Demo {
    struct DHost { let id: String; let name: String; let group: String; let items: [(String, Double, String)] }

    static let groups = ["Mikrotik", "Domain Controllers", "Exchange", "Hypervisors", "Storage", "Veeam", "Synology", "Linux servers", "SSL Sites", "Workstations", "Applications"]
    static let maintenanceIds: Set<String> = ["61", "21"]

    private static func srv(_ id: String, _ name: String, _ g: String, ping: Double = 1,
                            cpu: Double, mem: Double, disk: Double, extra: [(String, Double, String)] = []) -> DHost {
        DHost(id: id, name: name, group: g, items: [
            ("Zabbix agent ping", ping, ""), ("CPU utilization", cpu, "%"), ("Memory utilization", mem, "%"),
            ("FS [(C:)]: Space: Used, in %", disk, "%"), ("FS [(D:)]: Space: Used, in %", max(5, disk - 22), "%"),
            ("FS [(C:)]: Space: Total", 4e11 + Double((Int(id) ?? 1) % 5) * 2.5e11, "B"),
            ("FS [(D:)]: Space: Total", 8e11 + Double((Int(id) ?? 1) % 4) * 6e11, "B")
        ] + extra)
    }

    private static func mk(_ id: String, _ city: String, ping: Double = 1, loss: Double = 0, rtt: Double) -> DHost {
        DHost(id: id, name: "Mikrotik - \(city)", group: "Mikrotik",
              items: [("ICMP ping", ping, ""), ("ICMP loss", loss, "%"), ("ICMP response time", rtt, "s")])
    }

    private static func ssl(_ id: String, _ site: String, _ days: Double) -> DHost {
        DHost(id: id, name: site, group: "SSL Sites", items: [("Оставшийся срок действия SSL сертификата", days, "")])
    }

    private static func pc(_ id: String, _ name: String, hours: Double, fail: Double, ok: Double) -> DHost {
        DHost(id: id, name: name, group: "Workstations", items: [
            ("Veeam Agent: часов с последнего успешного", hours, ""), ("Veeam Agent: проблемных за 7 дней", fail, ""),
            ("Veeam Agent: успешных за 7 дней", ok, "")])
    }

    static let hosts: [DHost] = [
        mk("1", "Moscow DC", rtt: 0.012), mk("2", "Moscow", rtt: 0.009), mk("3", "Kaliningrad", ping: 0, loss: 100, rtt: 0),
        mk("4", "Kazan", loss: 8, rtt: 0.191), mk("5", "Piter", rtt: 0.027), mk("6", "Murmansk", rtt: 0.034),
        mk("7", "Samara", rtt: 0.118), mk("8", "Vladivostok", rtt: 0.097), mk("9", "Voronezh", rtt: 0.031),
        mk("12", "Nizhny Novgorod", rtt: 0.022), mk("13", "Rostov", rtt: 0.041), mk("14", "Sochi", rtt: 0.052),
        mk("15", "Volgograd", rtt: 0.047), mk("16", "Saratov", rtt: 0.038), mk("17", "Irkutsk", rtt: 0.163),
        srv("10", "DC1", "Domain Controllers", cpu: 24, mem: 61, disk: 48,
            extra: [("ADDS: LDAP Port is running", 1, ""), ("Active agent availability", 1, ""),
                    ("AD: Kerberos — разных учёток с ошибкой за 10 минут", 3, ""),
                    ("AD: NTLM — разных учёток с ошибкой за 10 минут", 1, ""),
                    ("AD: возраст пароля krbtgt, дней", 212, ""),
                    ("AD: учётки с опасными флагами — число", 0, "")]),
        srv("11", "DC2", "Domain Controllers", cpu: 38, mem: 55, disk: 52,
            extra: [("ADDS: LDAP Port is running", 1, ""), ("Active agent availability", 1, ""),
                    ("AD: Kerberos — разных учёток с ошибкой за 10 минут", 27, ""),
                    ("AD: NTLM — разных учёток с ошибкой за 10 минут", 6, ""),
                    ("AD: возраст пароля krbtgt, дней", 212, ""),
                    ("AD: учётки с опасными флагами — число", 2, "")]),
        srv("20", "MBX1", "Exchange", cpu: 41, mem: 72, disk: 64, extra: [
            ("Exchange Transport Queue Length: Active mailbox delivery queue length", 3, ""),
            ("Exchange Transport Queue Length: Delivery queue length (all queues)", 4, ""),
            ("Exchange Transport Queue Length: Poison queue length", 0, "")]),
        srv("21", "MBX2", "Exchange", cpu: 33, mem: 68, disk: 71, extra: [
            ("Exchange Transport Queue Length: Active mailbox delivery queue length", 120, ""),
            ("Exchange Transport Queue Length: Delivery queue length (all queues)", 134, ""),
            ("Exchange Transport Queue Length: Poison queue length", 0, "")]),
        srv("22", "MBX3", "Exchange", cpu: 29, mem: 70, disk: 93, extra: [
            ("Exchange Transport Queue Length: Active mailbox delivery queue length", 0, ""),
            ("Exchange Transport Queue Length: Delivery queue length (all queues)", 0, ""),
            ("Exchange Transport Queue Length: Poison queue length", 1, "")]),
        srv("30", "HYPER1", "Hypervisors", cpu: 52, mem: 83, disk: 58,
            extra: [("Windows: не установлено обновлений безопасности", 2, ""), ("Windows: дней с последней установки обновлений", 41, ""),
                   ("ВМ: запущено", 14, ""), ("ВМ: всего", 16, "")]),
        srv("31", "HYPER2", "Hypervisors", cpu: 47, mem: 79, disk: 61,
            extra: [("Windows: не установлено обновлений безопасности", 7, ""), ("Windows: дней с последней установки обновлений", 94, ""),
                   ("ВМ: запущено", 11, ""), ("ВМ: всего", 12, "")]),
        srv("32", "HYPER3", "Hypervisors", cpu: 61, mem: 94, disk: 91,
            extra: [("Windows: не установлено обновлений безопасности", 0, ""), ("Windows: дней с последней установки обновлений", 12, ""),
                   ("ВМ: запущено", 9, ""), ("ВМ: всего", 9, "")]),
        srv("33", "KASPER", "Applications", cpu: 22, mem: 58, disk: 44, extra: [
            ("State of service \"kladminserver\" (Сервер администрирования)", 0, ""),
            ("State of service \"klnagent\" (Агент администрирования)", 0, ""),
            ("State of service \"AVP.KES\" (Kaspersky Endpoint Security)", 6, ""),
            ("State of service \"KSCWebConsole\" (Веб-консоль)", 0, "")]),
        ssl("80", "grafana.example.com", 212), ssl("81", "mail.example.com", 9), ssl("82", "vpn.example.com", 24),
        ssl("83", "crm.example.com", 301),
        pc("90", "PC-ABOROVIK", hours: 18, fail: 0, ok: 7), pc("91", "NB-IVANOVA", hours: 130, fail: 3, ok: 2),
        pc("92", "PC-SMIRNOV", hours: 52, fail: 1, ok: 5), pc("93", "NB-KUZNETSOV", hours: 6, fail: 0, ok: 7),
        srv("70", "app-prod-01", "Linux servers", cpu: 18, mem: 44, disk: 37),
        DHost(id: "40", name: "MSA 2040 Storage", group: "Storage", items: [("System health", 2, "")]),
        DHost(id: "41", name: "MSA P2000", group: "Storage", items: [("System health", 0, "")]),
        DHost(id: "60", name: "Synology DS423+", group: "Synology", items: [("Synology: место свободно %", 12, "%")]),
        DHost(id: "61", name: "Synology DS118", group: "Synology", items: [("Synology: место свободно %", 46, "%")]),
        DHost(id: "50", name: "VEEAM1", group: "Veeam", items: [
            ("Veeam: служба Veeam Backup Service", 1, ""), ("Veeam: Backups finished with Failed (24h)", 1, ""),
            ("Veeam: Backups finished with Warning (24h)", 0, ""), ("Veeam: Backups finished with Success (24h)", 3, "")]),
        DHost(id: "51", name: "VEEAM2", group: "Veeam", items: [
            ("Veeam: служба Veeam Backup Service", 1, ""), ("Veeam: Backups finished with Failed (24h)", 0, ""),
            ("Veeam: Backups finished with Warning (24h)", 1, ""), ("Veeam: Backups finished with Success (24h)", 5, "")]),
        DHost(id: "52", name: "Veeam Agents", group: "Veeam", items: [
            ("Veeam Agent: планов просрочено", 3, ""), ("Veeam Agent: планов с ошибкой", 1, "")])
    ]

    static var groupIndex: [String: String] {
        Dictionary(uniqueKeysWithValues: groups.enumerated().map { ($0.element, String($0.offset + 1)) })
    }

    static func demoTags(_ name: String, _ host: String) -> [(String, String)] {
        let n = (name + " " + host).lowercased()
        var t: [(String, String)] = []
        if n.contains("mbx") || n.contains("exchange") || n.contains("почт") { t.append(("service", "mail")) }
        if n.contains("icmp") || n.contains("канал") || n.contains("mikrotik") { t.append(("service", "network")) }
        if n.contains("veeam") || n.contains("бэкап") { t.append(("service", "backup")) }
        if n.contains("hyper") || n.contains("обновлен") { t.append(("scope", "os")) }
        if n.contains("безопасн") { t.append(("scope", "security")) }
        return t
    }

    // MARK: ответы API

    static func respond(path: String, method: String, body: JSON?) -> JSON {
        if path.hasPrefix("/api/datasources/uid/") { return zabbix(body ?? .null) }
        if path == "/api/datasources" {
            return .array([.object(["id": .number(5), "uid": .string("zbx"), "name": .string("Zabbix"),
                                    "type": .string("alexanderzobnin-zabbix-datasource"), "isDefault": .bool(true)])])
        }
        if path == "/api/ds/query" { return query(body ?? .null) }
        return .null
    }

    // MARK: Zabbix API

    private static func zabbix(_ body: JSON) -> JSON {
        let params = body["params"]
        func res(_ a: [JSON]) -> JSON { .object(["result": .array(a)]) }
        switch body["method"].string {
        case "hostgroup.get":
            return res(groups.map { .object(["groupid": .string(groupIndex[$0] ?? ""), "name": .string($0)]) })
        case "host.get":
            let gids = Set(params["groupids"].array.compactMap { $0.string })
            let q = params["search"]["name"].string?.lowercased()
            return res(hosts.filter {
                if let q { return $0.name.lowercased().contains(q) }
                return gids.isEmpty || gids.contains(groupIndex[$0.group] ?? "")
            }.map { .object(["hostid": .string($0.id), "name": .string($0.name),
                             "maintenance_status": .string(maintenanceIds.contains($0.id) ? "1" : "0")]) })
        case "item.get":
            let iids = Set(params["itemids"].array.compactMap { $0.string })
            let hids = Set(params["hostids"].array.compactMap { $0.string })
            let names = Set(params["filter"]["name"].array.compactMap { $0.string })
            let search = params["search"]["name"].string
            var out: [JSON] = []
            for h in hosts where !iids.isEmpty || (hids.isEmpty ? search != nil : hids.contains(h.id)) {
                for (i, it) in h.items.enumerated() {
                    if !iids.isEmpty && !iids.contains("\(h.id)\(i)") { continue }
                    if !names.isEmpty && !names.contains(it.0) { continue }
                    if let search, !it.0.localizedCaseInsensitiveContains(search) && !h.name.localizedCaseInsensitiveContains(search) { continue }
                    out.append(.object(["itemid": .string("\(h.id)\(i)"), "name": .string(it.0),
                                        "lastvalue": .string(String(it.1)), "units": .string(it.2), "hostid": .string(h.id)]))
                }
            }
            return res(out)
        case "script.get":
            return res([("1", "Ping", "0", ""), ("2", "Traceroute", "0", ""),
                        ("7", "Веб-интерфейс (https)", "6", "https://{HOST.CONN}/"),
                        ("11", "Последние данные узла", "6", "zabbix.php?action=latest.view&filter_set=1&hostids%5B%5D={HOST.ID}")].map {
                .object(["scriptid": .string($0.0), "name": .string($0.1), "scope": .string("2"), "confirmation": .string(""),
                         "type": .string($0.2), "url": .string($0.3)])
            })
        case "hostinterface.get":
            return res([.object(["ip": .string("10.10.1.20"), "dns": .string(""), "useip": .string("1"), "main": .string("1")])])
        case "script.execute":
            return .object(["result": .object(["response": .string("success"), "value": .string("""
            PING 10.10.1.20 (10.10.1.20) 56(84) bytes of data.
            64 bytes from 10.10.1.20: icmp_seq=1 ttl=63 time=0.84 ms
            64 bytes from 10.10.1.20: icmp_seq=2 ttl=63 time=0.71 ms
            64 bytes from 10.10.1.20: icmp_seq=3 ttl=63 time=0.77 ms

            --- 10.10.1.20 ping statistics ---
            3 packets transmitted, 3 received, 0% packet loss, time 2003ms
            rtt min/avg/max/mdev = 0.712/0.773/0.841/0.052 ms
            """)])])
        case "maintenance.create":
            return .object(["result": .object(["maintenanceids": .array([.string("77")])])])
        case "problem.get":
            return res(problems.enumerated().map { i, p in
                .object(["eventid": .string("\(9000 + i)"), "name": .string(p.name), "severity": .string("\(p.sev)"),
                         "clock": .string(String(Int(Date().timeIntervalSince1970) - p.ageH * 3600)),
                         "acknowledged": .string(p.acked ? "1" : "0"), "objectid": .string("\(100 + i)"),
                         "tags": .array(demoTags(p.name, p.host).map { t in
                             .object(["tag": .string(t.0), "value": .string(t.1)]) })])
            })
        case "trigger.get":
            let ids = params["triggerids"].array.compactMap { $0.string }
            return res(ids.map { id in
                let i = (Int(id) ?? 100) - 100
                let p = problems[safe: i] ?? problems[0]
                let host = hosts.first { $0.name == p.host } ?? hosts[0]
                return .object([
                    "triggerid": .string(id),
                    "manual_close": .string(i % 2 == 0 ? "1" : "0"),
                    "url": .string(i == 0 ? "https://wiki.example.com/storage/synology" : ""),
                    "url_name": .string(i == 0 ? "Регламент: место на СХД" : ""),
                    "description": .string(p.name),
                    "comments": .string("Проверьте состояние службы и доступность хоста. Если проблема повторяется — эскалировать дежурному."),
                    "hosts": .array([.object(["hostid": .string(host.id), "name": .string(p.host)])]),
                    "hostgroups": .array([.object(["name": .string(host.group)])]),
                    "items": .array(host.items.prefix(3).enumerated().map { j, it in
                        .object(["itemid": .string("\(host.id)\(j)"), "name": .string(it.0),
                                 "lastvalue": .string(String(it.1)), "units": .string(it.2)])
                    })
                ])
            })
        case "event.get":
            let now = Int(Date().timeIntervalSince1970)
            if let oid = params["objectids"].array.first?.string {
                let msgs = ["Перезапустил службу, ушло", "Почистил старые снимки на томе", "", "Провайдер: авария на линии, восстановили за час", ""]
                return res((0..<7).map { n in
                    let start = now - (n + 1) * 9 * 86400 - n * 3700
                    let m = msgs[n % msgs.count]
                    return .object(["eventid": .string("P\(oid)\(n)"), "clock": .string(String(start)), "r_eventid": .string("Q\(n)"),
                                    "acknowledges": .array(m.isEmpty ? [] : [.object([
                                        "clock": .string(String(start + 900)), "message": .string(m),
                                        "userid": .string(n % 2 == 0 ? "3" : "4")])])])
                })
            }
            if params["eventids"].array.count > 0, params["eventids"].array.first?.string?.hasPrefix("Q") == true {
                return res(params["eventids"].array.compactMap { $0.string }.map { id in
                    let n = Int(id.dropFirst()) ?? 0
                    return .object(["eventid": .string(id), "clock": .string(String(now - (n + 1) * 9 * 86400 - n * 3700 + 2400 + n * 1800))])
                })
            }
            if params["eventids"].array.count > 0 {
                return res(params["eventids"].array.compactMap { $0.string }.map { id in
                    let n = Int(id.dropFirst()) ?? 0
                    return .object(["eventid": .string(id), "clock": .string(String(now - n * 64800 - 1200 + ((n % 7) + 1) * 7200))])
                })
            }
            var out: [JSON] = []
            for n in 0..<120 {
                let p = problems[n % problems.count]
                let start = now - n * 64800 - 1200
                let open = n < 3
                out.append(.object([
                    "eventid": .string("E\(n)"), "name": .string(p.name), "clock": .string(String(start)),
                    "r_eventid": .string(open ? "0" : "R\(n)"), "severity": .string("\(p.sev)"),
                    "objectid": .string("\(100 + n % problems.count)"), "acknowledged": .string(n % 3 == 0 ? "1" : "0")]))
            }
            return res(out)
        case "user.get":
            return res([.object(["userid": .string("3"), "username": .string("ivanov"), "name": .string("Иван"), "surname": .string("Петров")]),
                        .object(["userid": .string("4"), "username": .string("smirnova"), "name": .string("Ольга"), "surname": .string("Смирнова")])])
        case "history.get":
            let ids = params["itemids"].array.compactMap { $0.string }
            let now = Int(Date().timeIntervalSince1970)
            var out: [JSON] = []
            for (k, id) in ids.enumerated() {
                for m in stride(from: 0, to: 360, by: 5) {
                    let base = 60 + Double(k * 7 % 30)
                    let jump = m > 300 - k * 20 ? 25.0 : 0
                    let v = base + 6 * sin(Double(m) / 30 + Double(k)) + jump
                    out.append(.object(["itemid": .string(id), "clock": .string(String(now - (360 - m) * 60)), "value": .string(String(v))]))
                }
            }
            return res(out)
        case "maintenance.get":
            let now = Int(Date().timeIntervalSince1970)
            return res([
                .object(["maintenanceid": .string("77"), "name": .string("Мобильное приложение: HYPER2 — замена диска (1)"),
                         "active_since": .string(String(now - 1800)), "active_till": .string(String(now + 5400)),
                         "description": .string("замена диска"), "hosts": .array([.object(["name": .string("HYPER2")])])]),
                .object(["maintenanceid": .string("78"), "name": .string("Обновление Exchange"),
                         "active_since": .string(String(now + 86400)), "active_till": .string(String(now + 86400 + 4 * 3600)),
                         "description": .string("CU15"), "hosts": .array([.object(["name": .string("MBX1")]), .object(["name": .string("MBX2")])])])
            ])
        case "trend.get":
            let ids = params["itemids"].array.compactMap { $0.string }
            let now = Int(Date().timeIntervalSince1970)
            var out: [JSON] = []
            for id in ids {
                let k = Double((Int(id) ?? 7) % 6)
                let slope = [0.05, 0.9, 0.3, 1.6, 0.0, 0.5][Int(k)]
                for h in 0..<(14 * 24) {
                    let v = 40 + slope * Double(h) / 24 + sin(Double(h) / 6)
                    out.append(.object(["itemid": .string(id), "clock": .string(String(now - (14 * 24 - h) * 3600)),
                                        "value_avg": .string(String(v))]))
                }
            }
            return res(out)
        default:
            return res([])
        }
    }

    static let problems: [(name: String, host: String, sev: Int, ageH: Int, acked: Bool)] = [
        ("Windows: на HYPER1 не установлено обновлений безопасности: 2", "HYPER1", 3, 6, false),
        ("Безопасность: на MBX3 очищен журнал — Microsoft-Exchange-ManagedAvailability", "MBX3", 4, 46, false),
        ("Veeam Agent: бэкап завершился с ошибкой", "Veeam Agents", 3, 12, false),
        ("HPE MSA 2040 Storage: Disk [disk_01.09]: Disk health is in fault state", "MSA 2040 Storage", 3, 30, false),
        ("На томе DB диска (F:): из 6.99 TB осталось 629.78 GB", "Synology DS423+", 5, 120, false),
        ("Mikrotik - Kaliningrad: нет ответа на ICMP ping", "Mikrotik - Kaliningrad", 4, 2, true),
        ("Exchange: очередь доставки больше 100 писем", "MBX2", 3, 1, false),
        ("AD: резервная копия AD давно не делалась на DC2", "DC2", 4, 90, false),
        ("Veeam Backup: There are errors in requests to API", "VEEAM1", 3, 72, false),
        ("Windows: FS [D:]: Space is critically low (used > 90%)", "HYPER3", 3, 20, true),
        ("Windows: FS [C:]: Space is critically low (used > 90%)", "MBX3", 4, 8, false)
    ]

    // MARK: запросы метрик

    private static func query(_ body: JSON) -> JSON {
        var results: [String: JSON] = [:]
        let nowMs = Date().timeIntervalSince1970 * 1000
        let fromMs = Double(body["from"].string ?? "") ?? (nowMs - 360_000 * 60)
        let toMs = Double(body["to"].string ?? "") ?? nowMs
        let spanMs = max(60_000, toMs - fromMs)
        for q in body["queries"].array {
            let ref = q["refId"].string ?? "A"
            let gf = q["group"]["filter"].string ?? "", hf = q["host"]["filter"].string ?? "", itf = q["item"]["filter"].string ?? ""
            var frames: [JSON] = []
            for h in hosts where zbxMatch(gf, h.group) && zbxMatch(hf, h.name) {
                for it in h.items where zbxMatch(itf, it.0) {
                    let n = min(400, max(60, Int(spanMs / 600_000)))
                    var times: [JSON] = [], vals: [JSON] = []
                    for k in 0..<n {
                        times.append(.number(toMs - Double(n - k) * spanMs / Double(n)))
                        let binary = it.1 == 0 || it.1 == 1
                        let wave = sin(Double(k) / 5 + Double(h.id.count)) * it.1 * 0.2
                        var v = binary && it.2 == "" ? it.1 : max(0, it.1 + wave)
                        if it.0 == "ICMP ping" && h.id == "4" && (k >= 20 && k < 27 || k >= 44 && k < 47) { v = 0 }
                        if it.0 == "ICMP ping" && h.id == "7" && k >= 8 && k < 11 { v = 0 }
                        if k >= n - 3 && n >= 200 {
                            if it.0 == "CPU utilization" && h.id == "32" { v = 97 }
                            if it.0 == "ICMP response time" && h.id == "17" { v = 0.62 }
                        }
                        if it.2 == "%" { v = min(100, v) }
                        if it.0.contains("Space: Used") {
                            let rise = [0.5, 4, 1.5, 7, 0, 3][(Int(h.id) ?? 1) % 6]
                            v = min(99, max(1, it.1 - rise * Double(n - k) / Double(n) * spanMs / 604_800_000))
                        }
                        if it.0.hasPrefix("Veeam: Backups") {
                            let day = Int((toMs - Double(n - k) * spanMs / Double(n)) / 86_400_000)
                            let r = (day * 3 + h.id.count * 2 + it.0.count) % 7
                            if it.0.contains("Failed") { v = r == 0 ? 2 : (h.id == "50" && r == 3 ? 1 : 0) }
                            else if it.0.contains("Warning") { v = r == 2 ? 1 : 0 }
                            else { v = Double(2 + r % 4) }
                        }
                        vals.append(.number(v))
                    }
                    frames.append(.object([
                        "schema": .object(["name": .string(it.0), "refId": .string(ref), "fields": .array([
                            .object(["name": .string("Time"), "type": .string("time")]),
                            .object(["name": .string("Value"), "type": .string("number"),
                                     "labels": .object(["host": .string(h.name), "item": .string(it.0)]),
                                     "config": .object(["displayNameFromDS": .string(it.0), "unit": .string(it.2 == "%" ? "percent" : (it.2 == "s" ? "s" : "none"))])])
                        ])]),
                        "data": .object(["values": .array([.array(times), .array(vals)])])
                    ]))
                }
            }
            results[ref] = .object(["frames": .array(frames)])
        }
        return .object(["results": .object(results)])
    }
}

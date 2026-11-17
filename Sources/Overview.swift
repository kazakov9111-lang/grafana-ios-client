import SwiftUI
import Charts

// «Обзор» — мобильный дашборд: ключевые проверки из ТВ4 в виде плиток, каждая ведёт к хостам и проблемам.

enum CheckRule {
    case okIsOne          // 1 = работает, 0 = авария
    case badIfPositive    // >0 = плохо
    case badIfNonZero     // 0 = ок, остальное плохо
    case lowIsBad(Double) // меньше порога = плохо
}

struct Check: Identifiable {
    let id: Int
    let title: String
    let icon: String
    let group: String
    let host: String
    let item: String
    let rule: CheckRule
    var unitHint: String = ""

    func isBad(_ v: Double?) -> Bool {
        guard let v else { return true }
        switch rule {
        case .okIsOne: return v < 1
        case .badIfPositive: return v > 0
        case .badIfNonZero: return v != 0
        case .lowIsBad(let t): return v < t
        }
    }
}

let overviewChecks: [Check] = [
    Check(id: 0, title: "Филиалы (ping)", icon: "network", group: "Mikrotik", host: "/^Mikrotik - /", item: "ICMP ping", rule: .okIsOne),
    Check(id: 1, title: "Контроллеры домена", icon: "person.3", group: "Domain Controllers", host: "/.*/", item: "ADDS: LDAP Port is running", rule: .okIsOne),
    Check(id: 2, title: "Почта Exchange", icon: "envelope", group: "/.*/", host: "/MBX/", item: "Zabbix agent ping", rule: .okIsOne),
    Check(id: 3, title: "Гипервизоры", icon: "server.rack", group: "Hypervisors", host: "/.*/", item: "Zabbix agent ping", rule: .okIsOne),
    Check(id: 4, title: "Очереди почты", icon: "tray.full", group: "/.*/", host: "/MBX/",
          item: "/^Exchange Transport Queue Length: Active mailbox delivery queue length$/", rule: .badIfPositive, unitHint: "писем > 100"),
    Check(id: 5, title: "СХД: здоровье", icon: "externaldrive", group: "/.*/", host: "/^(MSA|P2000)/", item: "System health", rule: .badIfNonZero),
    Check(id: 6, title: "Veeam: ошибки 24ч", icon: "arrow.triangle.2.circlepath", group: "/.*/", host: "/.*/",
          item: "Veeam: Backups finished with Failed (24h)", rule: .badIfPositive),
    Check(id: 7, title: "Veeam Agent", icon: "desktopcomputer", group: "Veeam", host: "/.*/",
          item: "/^Veeam Agent: (планов просрочено|планов с ошибкой)$/", rule: .badIfPositive),
    Check(id: 8, title: "NAS: свободное место", icon: "internaldrive", group: "/.*/", host: "/^Synology/",
          item: "Synology: место свободно %", rule: .lowIsBad(15)),
    Check(id: 9, title: "Обновления Windows", icon: "arrow.down.app", group: "Hypervisors", host: "/.*/",
          item: "Windows: не установлено обновлений безопасности", rule: .badIfPositive)
]

@MainActor
final class OverviewModel: ObservableObject {
    @Published var results: [Int: [Series]] = [:]
    @Published var problems: [Problem] = []
    @Published var loading = false
    @Published var error: String?
    @Published var updated: Date?
    @Published var history: [HistEvent] = []

    func value(_ s: Series) -> Double? {
        if let t = s.text { return Double(t) }
        return s.points.last?.v
    }

    func bad(_ check: Check, _ s: Series) -> Bool {
        let v = value(s)
        if check.id == 4 { return (v ?? 0) > 100 } // очередь больше 100 писем
        return check.isBad(v)
    }

    func load(session: Session) async {
        loading = true
        defer { loading = false }
        do {
            problems = try await session.loadProblems()
            Badge.set(Badge.count(problems))
            error = nil
            if let h = try? await session.problemHistory(days: 7) { history = h }
        } catch {
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
        for c in overviewChecks {
            let t: JSON = .object(["group": .object(["filter": .string(c.group)]),
                                   "host": .object(["filter": .string(c.host)]),
                                   "item": .object(["filter": .string(c.item)])])
            if let s = try? await session.textSeries(target: t, ref: "c\(c.id)") { results[c.id] = s }
        }
        updated = Date()
    }
}

struct OverviewView: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var router: Router
    @EnvironmentObject var pins: Pins
    @StateObject private var model = OverviewModel()
    @StateObject private var panels = PanelsModel()
    @State private var ask = Launch.screen == "ask" || Launch.screen == "chat"
    @State private var path: NavigationPath = {
        var p = NavigationPath()
        if let c = Launch.check { p.append(c) }
        return p
    }()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 12) {
                    SignBanner()
                    WatchdogBanner()
                    OnDutyCard()
                    summary
                    FavoritesCard()
                    PanelStatsGrid(model: panels)
                    if !Launch.charts {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(overviewChecks) { c in
                                NavigationLink(value: c.id) { tile(c) }.buttonStyle(.plain)
                            }
                        }
                    }
                    CPUPanelCard(model: panels)
                    BandPanel(series: panels.cpu, title: "Разброс CPU по серверам", height: 140)
                    StatusHistoryPanel(series: panels.cpu)
                    trend
                    heatmap
                    favorites
                    top
                }
                .padding(12)
            }
            .background(StateBackground(severity: model.problems.map(\.severity).max() ?? 0))
            .navigationTitle("Обзор")
            .navigationDestination(for: Int.self) { id in
                if let c = overviewChecks.first(where: { $0.id == id }) {
                    CheckDetailView(check: c, model: model)
                }
            }
            .navigationDestination(for: Problem.self) { ProblemDetailView(problem: $0, all: model.problems) }
            .navigationDestination(for: HostMini.self) { HostExplorerView(host: $0) }
            .refreshable { await model.load(session: session); await panels.loadMetrics(session: session) }
            .task { await model.load(session: session); await panels.loadMetrics(session: session) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if model.loading { ProgressView() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { ask = true } label: { Image(systemName: "sparkles") }
                }
            }
            .sheet(isPresented: $ask) { ChatAskView() }
        }
    }

    // сводка проблем
    private var summary: some View {
        Button { router.problemSearch = ""; router.tab = 1 } label: {
            HStack(spacing: 14) {
                healthRing
                ForEach([5, 4, 3], id: \.self) { s in
                    let n = model.problems.filter { $0.severity == s }.count
                    VStack(spacing: 2) {
                        Text("\(n)").font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(n > 0 ? sevColor(s) : Color.secondary)
                        Text(sevName(s)).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var healthTotals: (total: Int, bad: Int) {
        var t = 0, b = 0
        for c in overviewChecks {
            guard let rows = model.results[c.id] else { continue }
            t += rows.count
            b += rows.filter { model.bad(c, $0) }.count
        }
        return (t, b)
    }

    @ViewBuilder private var healthRing: some View {
        let h = healthTotals
        let pct = h.total == 0 ? 0 : Int((Double(h.total - h.bad) / Double(h.total) * 100).rounded())
        ZStack {
            SegmentRing(segments: [(Double(h.total - h.bad), Level.ok.color), (Double(h.bad), Level.bad.color)], lineWidth: 8)
            VStack(spacing: 0) {
                Text("\(pct)%").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(h.bad == 0 ? Level.ok.color : Color.primary)
                Text("в норме").font(.system(size: 8)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 70, height: 70)
    }

    private struct HeatCell: Identifiable {
        let id: Int
        let hour: Int
        let day: String
        let n: Int
    }

    private var heat: (cells: [HeatCell], days: [String]) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EE d"
        var cells: [HeatCell] = []
        var days: [String] = []
        var id = 0
        for back in (0..<7).reversed() {
            guard let d = cal.date(byAdding: .day, value: -back, to: today) else { continue }
            let label = f.string(from: d)
            days.append(label)
            let ev = model.history.filter { cal.startOfDay(for: $0.start) == d }
            for hour in 0..<24 {
                let n = ev.filter { cal.component(.hour, from: $0.start) == hour }.count
                cells.append(HeatCell(id: id, hour: hour, day: label, n: n)); id += 1
            }
        }
        return (cells, days)
    }

    @ViewBuilder private var heatmap: some View {
        if !model.history.isEmpty {
            let h = heat
            let peak = max(h.cells.map(\.n).max() ?? 1, 1)
            VStack(alignment: .leading, spacing: 10) {
                Text("Когда случаются проблемы").font(.subheadline.weight(.semibold))
                Chart(h.cells) { c in
                    RectangleMark(x: .value("час", String(format: "%02d", c.hour)), y: .value("день", c.day), width: .ratio(0.88), height: .fixed(15))
                        .foregroundStyle(c.n == 0 ? Color.white.opacity(0.05)
                                         : Color(hex: "FF9830").opacity(0.3 + 0.7 * Double(c.n) / Double(peak)))
                        .cornerRadius(2)
                }
                .chartXScale(domain: (0..<24).map { String(format: "%02d", $0) })
                .chartYScale(domain: h.days)
                .chartXAxis {
                    AxisMarks(values: ["00", "06", "12", "18"]) { v in
                        AxisValueLabel { if let x = v.as(String.self) { Text(x + ":00").font(.caption2) } }
                    }
                }
                .chartYAxis { AxisMarks { _ in AxisValueLabel().font(.caption2) } }
                .frame(height: 170)
                Text("Чем ярче клетка, тем больше проблем началось в этот час.").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func tile(_ c: Check) -> some View {
        let rows = model.results[c.id]
        let total = rows?.count ?? 0
        let badN = rows?.filter { model.bad(c, $0) }.count ?? 0
        let color: Color = rows == nil ? .gray : (total == 0 ? .gray : (badN == 0 ? Color(hex: "73BF69") : Color(hex: "F2495C")))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                ZStack {
                    if total > 0 {
                        SegmentRing(segments: [(value: Double(total - badN), color: Color(hex: "73BF69")),
                                               (value: Double(badN), color: Color(hex: "F2495C"))], lineWidth: 3.5)
                    }
                    Image(systemName: c.icon).font(.caption).foregroundStyle(color)
                }
                .frame(width: 30, height: 30)
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }
            Text(c.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if rows == nil {
                ProgressView().scaleEffect(0.8)
            } else if total == 0 {
                Text("нет данных").font(.subheadline).foregroundStyle(.secondary)
            } else if badN == 0 {
                Text("Всё в порядке").font(.subheadline.weight(.semibold)).foregroundStyle(color)
                Text("\(total) шт.").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Проблем: \(badN)").font(.subheadline.weight(.semibold)).foregroundStyle(color)
                Text("из \(total)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(badN > 0 ? color.opacity(0.7) : .clear, lineWidth: 1))
    }

    private struct DayBucket: Identifiable {
        let id: String
        let day: Date
        let sev: String
        let n: Int
    }

    private var buckets: [DayBucket] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var out: [DayBucket] = []
        for back in (0..<7).reversed() {
            guard let day = cal.date(byAdding: .day, value: -back, to: today) else { continue }
            let ev = model.history.filter { cal.startOfDay(for: $0.start) == day }
            for sev in [3, 4, 5] {
                out.append(DayBucket(id: "\(back)-\(sev)", day: day, sev: sevName(sev), n: ev.filter { $0.severity == sev }.count))
            }
        }
        return out
    }

    private var noisy: [(host: String, n: Int)] {
        Dictionary(grouping: model.history.filter { !$0.host.isEmpty && $0.severity >= 3 }, by: { $0.host })
            .map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }.prefix(5).map { $0 }
    }

    @ViewBuilder private var trend: some View {
        if !model.history.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Проблемы за 7 дней").font(.subheadline.weight(.semibold))
                Chart(buckets) { b in
                    BarMark(x: .value("день", b.day, unit: .day), y: .value("n", b.n))
                        .foregroundStyle(by: .value("важность", b.sev))
                        .cornerRadius(3)
                }
                .chartForegroundStyleScale(domain: [3, 4, 5].map { sevName($0) }, range: [3, 4, 5].map { sevColor($0) })
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.abbreviated).locale(Locale(identifier: "ru_RU")))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.white.opacity(0.12))
                        AxisValueLabel().font(.caption2)
                    }
                }
                .chartLegend(position: .bottom, spacing: 8)
                .frame(height: 170)

                if !noisy.isEmpty {
                    Divider()
                    Text("Больше всего проблем").font(.subheadline.weight(.semibold))
                    Chart(noisy, id: \.host) { d in
                        BarMark(x: .value("n", d.n), y: .value("хост", d.host), width: .fixed(14))
                            .foregroundStyle(LinearGradient(colors: [Color(hex: "FF9830"), Color(hex: "F2495C")],
                                                            startPoint: .leading, endPoint: .trailing))
                            .cornerRadius(4)
                            .annotation(position: .trailing, spacing: 4) {
                                Text("\(d.n)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            }
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis { AxisMarks { _ in AxisValueLabel().font(.caption2) } }
                    .chartXScale(domain: 0...(Double(noisy.first?.n ?? 1) * 1.2))
                    .frame(height: CGFloat(noisy.count) * 30 + 8)
                }
            }
            .padding(12)
            .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder private var favorites: some View {
        if !pins.items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Избранные хосты").font(.subheadline.weight(.semibold))
                ForEach(pins.items) { h in
                    let n = model.problems.filter { $0.host == h.name }.count
                    NavigationLink(value: h) {
                        HStack {
                            Circle().fill(n > 0 ? Level.bad.color : Level.ok.color).frame(width: 10, height: 10)
                            Text(h.name).font(.subheadline)
                            Spacer()
                            Text(n > 0 ? "проблем: \(n)" : "всё хорошо").font(.caption)
                                .foregroundStyle(n > 0 ? Level.bad.color : Level.ok.color)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var top: some View {
        let list = model.problems.sorted { ($0.severity, $0.clock) > ($1.severity, $1.clock) }.prefix(5)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Главное сейчас").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Все") { router.problemSearch = ""; router.tab = 1 }.font(.caption)
            }
            ForEach(Array(list)) { p in
                NavigationLink(value: p) {
                    ProblemRow(p: p).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                Divider()
            }
            if list.isEmpty && !model.loading {
                Label("Проблем нет", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.subheadline)
            }
            if let e = model.error { Text(e).font(.caption).foregroundStyle(.orange) }
        }
        .padding(12)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct CheckDetailView: View {
    @EnvironmentObject var router: Router
    let check: Check
    @ObservedObject var model: OverviewModel

    var body: some View {
        let rows = (model.results[check.id] ?? []).sorted { a, b in
            let ba = model.bad(check, a), bb = model.bad(check, b)
            if ba != bb { return ba }
            return a.name < b.name
        }
        List {
            Section {
                Text(check.item.replacingOccurrences(of: "/^", with: "").replacingOccurrences(of: "$/", with: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Хосты") {
                ForEach(rows) { s in
                    let bad = model.bad(check, s)
                    let v = model.value(s)
                    Button {
                        router.showProblems(host: s.name.components(separatedBy: ": ").first ?? s.name)
                    } label: {
                        HStack {
                            Circle().fill(bad ? Color(hex: "F2495C") : Color(hex: "73BF69")).frame(width: 10, height: 10)
                            Text(s.name).foregroundStyle(.primary)
                            Spacer()
                            Text(v.map { formatValue($0, unit: s.unit == "%" ? "percent" : nil) } ?? (s.text ?? "—"))
                                .foregroundStyle(bad ? Color(hex: "F2495C") : Color.secondary)
                                .font(.subheadline.weight(.semibold))
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Section { Text("Нажмите на хост — откроются его проблемы.").font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle(check.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

import SwiftUI
import Charts

// Вкладка «Панели»: набор панелей в стиле Grafana (stat со спарклайном, временные ряды
// с легендой-таблицей, state timeline, honeycomb, donut, bar gauge).

@MainActor
final class PanelsModel: ObservableObject {
    @Published var cpu: [Series] = []
    @Published var mem: [Series] = []
    @Published var rtt: [Series] = []
    @Published var ping: [Series] = []
    @Published var problems: [Problem] = []
    @Published var loading = false
    @Published var updated: Date?
    @Published var range: TimeRange = TimeRange(rawValue: UserDefaults.standard.string(forKey: "panelRange") ?? "") ?? .h6 {
        didSet { UserDefaults.standard.set(range.rawValue, forKey: "panelRange") }
    }
    @Published var history: [HistEvent] = []
    @Published var history90: [HistEvent] = []
    @Published var cpuWeek: [Series] = []
    @Published var diskFC: [DiskFC] = []
    @Published var diskSeries: [String: Series] = [:]
    var live = false
    @Published var customRange: ClosedRange<Date>?
    @Published var anomalies: [Anomaly] = []
    @Published var cells: [DiskCell] = []
    @Published var cpuPrev: [Series] = []
    @Published var rttPrev: [Series] = []
    @Published var groupIndex: Int = 0
    let systems = SystemsModel()

    static let groups: [(title: String, regex: String)] = [
        ("Все серверы", serverGroups), ("Гипервизоры", "/^Hypervisors$/"), ("Exchange", "/^Exchange$/"),
        ("Контроллеры домена", "/^Domain Controllers$/"), ("Linux", "/^Linux servers$/")
    ]
    var groupRegex: String { PanelsModel.groups[groupIndex].regex }

    var windowSeconds: Double { customRange.map { $0.upperBound.timeIntervalSince($0.lowerBound) } ?? range.seconds }
    var windowEnd: Date { customRange?.upperBound ?? Date() }
    var windowLabel: String {
        guard let c = customRange else { return range.label }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMM HH:mm"
        return "\(f.string(from: c.lowerBound)) — \(f.string(from: c.upperBound))"
    }

    /// Сдвиг окна на его ширину: -1 назад, +1 вперёд (дошли до «сейчас» — снова живой режим).
    func shift(_ dir: Int) {
        let w = windowSeconds
        let newEnd = windowEnd.addingTimeInterval(Double(dir) * w)
        if newEnd >= Date().addingTimeInterval(-1) { customRange = nil }
        else { customRange = newEnd.addingTimeInterval(-w)...newEnd }
    }

    /// Только метрики для графиков (без экранов «Систем» и проблем).
    /// Те же окна неделю назад (пунктир под текущими линиями), если включено в меню «Вид».
    func loadPrev(session: Session) async {
        guard UserDefaults.standard.bool(forKey: "chartWeekAgo"), windowSeconds <= 2 * 86400 else {
            cpuPrev = []; rttPrev = []; return
        }
        let week = 7 * 86400.0
        let end = windowEnd.addingTimeInterval(-week)
        func shifted(_ s: [Series]) -> [Series] {
            s.map { x in
                Series(id: x.id, name: x.name, points: x.points.map { Pt(id: $0.id, t: $0.t.addingTimeInterval(week), v: $0.v) },
                       text: x.text, unit: x.unit, ref: x.ref, host: x.host, item: x.item)
            }
        }
        let c = (try? await session.hostSeries(host: "/.*/", filter: "CPU utilization", seconds: windowSeconds, group: groupRegex,
                                               maxPoints: 200, to: end)) ?? []
        let r = (try? await session.hostSeries(host: "/.*/", filter: "ICMP response time", seconds: windowSeconds, group: "Mikrotik",
                                               maxPoints: 200, to: end)) ?? []
        cpuPrev = shifted(c); rttPrev = shifted(r)
    }

    func loadMetrics(session: Session) async {
        await loadPrev(session: session)
        let c = (try? await session.hostSeries(host: "/.*/", filter: "CPU utilization", seconds: windowSeconds, group: groupRegex, maxPoints: 200, to: windowEnd)) ?? []
        let m = (try? await session.hostSeries(host: "/.*/", filter: "Memory utilization", seconds: windowSeconds, group: groupRegex, maxPoints: 200, to: windowEnd)) ?? []
        let r = (try? await session.hostSeries(host: "/.*/", filter: "ICMP response time", seconds: windowSeconds, group: "Mikrotik", maxPoints: 200, to: windowEnd)) ?? []
        let p = (try? await session.hostSeries(host: "/.*/", filter: "ICMP ping", range: .h24, group: "Mikrotik")) ?? []
        withAnimation(live ? .easeInOut(duration: 0.7) : nil) { cpu = c; mem = m; rtt = r; ping = p }
    }

    /// 8 дней CPU: для сравнения «сейчас и неделю назад» и полосы нормы.
    func loadWeek(session: Session) async {
        cpuWeek = (try? await session.hostSeries(host: "/.*/", filter: "CPU utilization", seconds: 8 * 86400,
                                                 group: groupRegex, maxPoints: 400)) ?? []
        await loadAnomalies(session: session)
    }

    /// Текущее значение против того же времени суток за прошлые 7 дней.
    func loadAnomalies(session: Session) async {
        let mem = (try? await session.hostSeries(host: "/.*/", filter: "Memory utilization", seconds: 8 * 86400,
                                                 group: groupRegex, maxPoints: 400)) ?? []
        let rtt = (try? await session.hostSeries(host: "/.*/", filter: "ICMP response time", seconds: 8 * 86400,
                                                 group: "Mikrotik", maxPoints: 400)) ?? []
        let all = AnomalyScan.scan(cpuWeek, metric: "CPU", unit: "percent", minDelta: 15)
            + AnomalyScan.scan(mem, metric: "RAM", unit: "percent", minDelta: 10)
            + AnomalyScan.scan(rtt, metric: "Задержка", unit: "s", minDelta: 0.05)
        anomalies = all.sorted { $0.z > $1.z }
    }

    /// Диски с самым близким заполнением и их история для графика прогноза.
    func loadDisks(session: Session) async {
        cells = (try? await session.diskCells()) ?? []
        let fc = (try? await session.diskForecasts()) ?? []
        var pick = Array(fc.filter { $0.daysLeft != nil }.sorted { ($0.daysLeft ?? 9e9) < ($1.daysLeft ?? 9e9) }.prefix(3))
        let chosen = pick
        if pick.count < 3 {
            pick += fc.filter { f in !chosen.contains { $0.id == f.id } }.sorted { $0.used > $1.used }.prefix(3 - pick.count)
        }
        var map: [String: Series] = [:]
        for d in pick {
            let esc = NSRegularExpression.escapedPattern(for: d.host)
            let ser = (try? await session.hostSeries(host: "/^\(esc)$/", filter: "/Space: Used, in %/", seconds: 7 * 86400,
                                                     group: "/.*/", maxPoints: 200)) ?? []
            if let x = ser.first(where: { $0.name.contains("[\(d.disk)]") }) ?? ser.first { map[d.id] = x }
        }
        diskFC = pick
        diskSeries = map
    }

    func load(session: Session) async {
        loading = true
        defer { loading = false }
        cpu = (try? await session.hostSeries(host: "/.*/", filter: "CPU utilization", seconds: windowSeconds, group: groupRegex, maxPoints: 200, to: windowEnd)) ?? []
        mem = (try? await session.hostSeries(host: "/.*/", filter: "Memory utilization", seconds: windowSeconds, group: groupRegex, maxPoints: 200, to: windowEnd)) ?? []
        rtt = (try? await session.hostSeries(host: "/.*/", filter: "ICMP response time", seconds: windowSeconds, group: "Mikrotik", maxPoints: 200, to: windowEnd)) ?? []
        ping = (try? await session.hostSeries(host: "/.*/", filter: "ICMP ping", range: .h24, group: "Mikrotik")) ?? []
        problems = (try? await session.loadProblems()) ?? []
        history90 = (try? await session.problemHistory(days: 90)) ?? history90
        let cut = Date().addingTimeInterval(-7 * 86400)
        history = history90.filter { ($0.end ?? Date()) > cut }
        await loadWeek(session: session)
        await loadDisks(session: session)
        for id in ["servers", "net"] {
            if let s = systemScreens.first(where: { $0.id == id }) { await systems.load(s, session: session) }
        }
        updated = Date()
    }
}

// MARK: Помощники

func lastValues(_ s: [Series]) -> [Double] { s.compactMap { $0.points.last?.v } }

func average(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }

/// Среднее по всем рядам во времени (для спарклайна).
func averaged(_ series: [Series], buckets: Int = 36) -> [Pt] {
    let all = series.flatMap { $0.points }
    guard let t0 = all.map({ $0.t }).min(), let t1 = all.map({ $0.t }).max(), t1 > t0 else { return [] }
    let step = t1.timeIntervalSince(t0) / Double(buckets)
    var sums = [Double](repeating: 0, count: buckets)
    var cnt = [Int](repeating: 0, count: buckets)
    for p in all {
        let i = min(buckets - 1, Int(p.t.timeIntervalSince(t0) / step))
        sums[i] += p.v
        cnt[i] += 1
    }
    var out: [Pt] = []
    for i in 0..<buckets where cnt[i] > 0 {
        out.append(Pt(id: i, t: t0.addingTimeInterval(step * (Double(i) + 0.5)), v: sums[i] / Double(cnt[i])))
    }
    return out
}

func shortName(_ n: String) -> String {
    var s = n.replacingOccurrences(of: "Mikrotik - ", with: "")
    if let r = s.range(of: "^[A-Z][0-9]{2}(RU|MSC[0-9]{2})?", options: .regularExpression), r.upperBound < s.endIndex { s.removeSubrange(r) }
    return String(s.prefix(7))
}

// MARK: Контейнеры

struct PanelCard<Content: View>: View {
    @Environment(\.reportLight) private var reportLight
    @Environment(\.snapshot) private var snapshot
    @Namespace private var zoomNS
    let title: String
    var subtitle: String?
    var shareable = true
    var expandable = true
    @ViewBuilder let content: () -> Content
    @State private var full = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary) }
                if expandable {
                    Button { full = true } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                if shareable {
                    Button { sharePanel(PanelCard(title: title, subtitle: subtitle, shareable: false, expandable: false, content: content)) } label: {
                        Image(systemName: "square.and.arrow.up").font(.caption).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            content()
        }
        .padding(12)
        .modifier(CardBackground())
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06)))
        .modifier(ZoomSource(id: title, ns: snapshot ? nil : zoomNS))
        .fullScreenCover(isPresented: $full) {
            PanelFullScreen(title: title, subtitle: subtitle, content: content).modifier(ZoomDest(id: title, ns: zoomNS))
        }
        .onAppear { if Launch.screen == "fullscreen" && title == "Загрузка CPU" { full = true } }
    }
}

struct StatPanel: View {
    @Environment(\.reportLight) private var reportLight
    let title: String
    let value: String
    let color: Color
    let spark: [Pt]

    var body: some View {
        let vals = spark.map { $0.v }
        let lo = vals.min() ?? 0, hi = vals.max() ?? 1
        let pad = max((hi - lo) * 0.2, 0.5)
        ZStack(alignment: .bottom) {
            if spark.count > 1 {
                Chart {
                    ForEach(spark) { p in
                        AreaMark(x: .value("t", p.t), yStart: .value("0", lo - pad), yEnd: .value("v", p.v))
                            .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.0)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("t", p.t), y: .value("v", p.v))
                            .foregroundStyle(color.opacity(0.9))
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .interpolationMethod(.monotone)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: (lo - pad)...(hi + pad))
                .frame(height: 50)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(value).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(color)
                    .minimumScaleFactor(0.6).lineLimit(1)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: value)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .frame(height: 112)
        .modifier(CardBackground())
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.25)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct Hex: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let h = r.height
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + h * 0.25))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + h * 0.75))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + h * 0.75))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + h * 0.25))
        p.closeSubpath()
        return p
    }
}

struct HoneycombPanel: View {
    struct Item: Identifiable { let id: String; let name: String; let level: Level }
    let items: [Item]
    @Environment(\.drillDown) private var drill

    var body: some View {
        let width = UIScreen.main.bounds.width - 48
        let cols = 7
        let hexW = width / (Double(cols) + 0.5)
        let hexH = hexW * 1.1547
        let rows = (items.count + cols - 1) / cols
        ZStack(alignment: .topLeading) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                let row = i / cols, col = i % cols
                let x = Double(col) * hexW + (row % 2 == 1 ? hexW / 2 : 0) + hexW / 2
                let y = Double(row) * hexH * 0.75 + hexH / 2
                let c = it.level == .none ? Color.gray : it.level.color
                ZStack {
                    Hex().fill(c.opacity(0.85))
                    Hex().stroke(Color.black.opacity(0.5), lineWidth: 1.5)
                    Text(shortName(it.name)).font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.white).lineLimit(1).minimumScaleFactor(0.6)
                }
                .frame(width: hexW - 2, height: hexH - 2)
                .contentShape(Rectangle())
                .onTapGesture { drill?(it.name) }
                .position(x: x, y: y)
            }
        }
        .frame(width: width, height: Double(max(rows, 1)) * hexH * 0.75 + hexH * 0.25)
    }
}

// MARK: Экран

struct PanelsView: View {
    @EnvironmentObject var session: Session
    @StateObject private var model = PanelsModel()
    @ObservedObject private var customStore = CustomPanelStore.shared
    @State private var duty = Launch.screen == "duty"
    @State private var carousel = Launch.screen == "carousel"
    @State private var wall = Launch.screen == "wall" || Launch.screen == "wall-night"
    @State private var dashes = Launch.screen == "dashes" || Launch.screen == "dash"
    @State private var searchAll = Launch.screen == "search-all"
    @State private var noc = Launch.screen == "noc"
    @State private var report = Launch.screen == "report" || Launch.screen == "report-light"
    @State private var editMine = Launch.screen == "mine-edit"
    @State private var thrSheet = Launch.screen == "thr"
    @State private var rangeSheet = Launch.screen == "range"
    @State private var hidden: Set<String> = []
    @State private var path = NavigationPath()
    @State private var lastRefresh = Date()
    @AppStorage("refreshSec") private var refreshSec = 0
    @AppStorage("chartStyle") private var chartStyle = "line"
    @AppStorage("chartZero") private var chartZero = false
    @AppStorage("chartWeekAgo") private var weekAgo = false
    @AppStorage("chartScroll") private var chartScroll = false
    private let timer = Timer.publish(every: 120, on: .main, in: .common).autoconnect()
    private let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private var carouselIds: [String] {
        ["stats", "cpu", "anom", "rtt", "timeline", "stack", "honey", "treemap", "dfc"] + (customStore.items.isEmpty ? [] : ["mine"])
    }

    private var timeBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button { model.shift(-1); Haptics.tap() } label: { Image(systemName: "chevron.left").frame(width: 26, height: 30) }
                Picker("Период", selection: $model.range) {
                    ForEach(TimeRange.allCases) { Text($0.shortLabel).tag($0) }
                }
                .pickerStyle(.segmented)
                Button { model.shift(1); Haptics.tap() } label: { Image(systemName: "chevron.right").frame(width: 26, height: 30) }
                    .disabled(model.customRange == nil)
            }
            HStack(spacing: 8) {
                Menu {
                    Picker("Группа", selection: $model.groupIndex) {
                        ForEach(PanelsModel.groups.indices, id: \.self) { Text(PanelsModel.groups[$0].title).tag($0) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(PanelsModel.groups[model.groupIndex].title).foregroundStyle(.orange).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color(white: 0.14), in: Capsule())
                }
                Spacer()
                Button { rangeSheet = true } label: {
                    Image(systemName: "calendar").foregroundStyle(model.customRange == nil ? Color.secondary : Color.orange)
                        .padding(8).background(Color(white: 0.14), in: Circle())
                }
                Menu {
                    Picker("Обновление", selection: $refreshSec) {
                        Text("Не обновлять").tag(0); Text("Каждые 5 с").tag(5); Text("Каждые 30 с").tag(30)
                        Text("Каждую минуту").tag(60); Text("Каждые 5 минут").tag(300)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath").modifier(LoadingSpin(active: model.loading))
                        if refreshSec > 0 { Text(refreshSec >= 60 ? "\(refreshSec / 60)м" : "\(refreshSec)с").font(.caption.monospacedDigit()) }
                    }
                    .foregroundStyle(refreshSec > 0 ? Color.green : Color.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 8).background(Color(white: 0.14), in: Capsule())
                }
                Menu {
                    Picker("Вид", selection: $chartStyle) {
                        Text("Линия").tag("line"); Text("Ступеньки").tag("step"); Text("Столбцы").tag("bars")
                    }
                    Toggle("Ось Y от нуля", isOn: $chartZero)
                    Toggle("Сравнить с неделей назад", isOn: $weekAgo)
                    Toggle("Листать график пальцем", isOn: $chartScroll)
                } label: {
                    Image(systemName: "waveform.path.ecg").foregroundStyle(.secondary)
                        .padding(8).background(Color(white: 0.14), in: Circle())
                }
            }
            if model.customRange != nil {
                HStack {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.orange)
                    Text(model.windowLabel).font(.caption)
                    Spacer()
                    Button("К «сейчас»") { model.customRange = nil }.font(.caption)
                }
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 12) {
                    timeBar
                    if let set = Launch.panelSet {
                        ForEach(set, id: \.self) { panel($0) }
                    } else {
                        panel("stats")
                        panel("anom")
                        DashRow(id: "servers", title: "Серверы", icon: "server.rack") {
                            ForEach(["cpu", "fcast", "week", "band", "status", "xy", "cpu3d", "mem"], id: \.self) { panel($0) }
                        }
                        DashRow(id: "net", title: "Сеть и филиалы", icon: "network") {
                            ForEach(["nodes", "rtt", "box", "hist", "timeline"], id: \.self) { panel($0) }
                        }
                        DashRow(id: "problems", title: "Проблемы", icon: "exclamationmark.triangle") {
                            ForEach(["stack", "lanes", "calendar", "hourheat", "noisy", "donut", "honey"], id: \.self) { panel($0) }
                        }
                        DashRow(id: "disks", title: "Диски", icon: "internaldrive") {
                            ForEach(["dfc", "treemap", "disk"], id: \.self) { panel($0) }
                        }
                        DashRow(id: "mine", title: "Мои панели", icon: "square.grid.2x2") { panel("mine") }
                    }
                }
                .padding(12)
            }
            .background(Color(white: 0.07))
            .navigationTitle("Панели")
            .navigationDestination(for: HostMini.self) { HostExplorerView(host: $0) }
            .navigationDestination(for: String.self) { id in if id == "sla" { SLAView() } else if id == "zdash" { ZabbixDashListView() } }
            .environment(\.drillDown, { drill($0) })
            .refreshable { await model.load(session: session) }
            .task { await model.load(session: session) }
            .onAppear { model.live = refreshSec > 0 && refreshSec <= 30 }
            .onReceive(timer) { _ in Task { await model.load(session: session) } }
            .onReceive(tick) { _ in
                if refreshSec > 0 && model.customRange == nil && Date().timeIntervalSince(lastRefresh) >= Double(refreshSec) - 0.5 {
                    lastRefresh = Date()
                    Task { await model.loadMetrics(session: session) }
                }
            }
            .onChange(of: weekAgo) { _ in Task { await model.loadMetrics(session: session) } }
            .onChange(of: refreshSec) { v in model.live = v > 0 && v <= 30; lastRefresh = Date() }
            .onChange(of: model.range) { _ in
                if model.customRange != nil { model.customRange = nil } else { Task { await model.loadMetrics(session: session) } }
            }
            .onChange(of: model.customRange) { _ in Task { await model.loadMetrics(session: session) } }
            .onChange(of: model.groupIndex) { _ in Task { await model.loadMetrics(session: session); await model.loadWeek(session: session) } }
            .fullScreenCover(isPresented: $duty) { DutyView() }
            .fullScreenCover(isPresented: $carousel) { CarouselView(ids: carouselIds) { panel($0) } }
            .fullScreenCover(isPresented: $wall) { WallView(model: model, ids: carouselIds) { panel($0) } }
            .sheet(isPresented: $searchAll) { SearchAllView() }
            .sheet(isPresented: $dashes) { DashListView() }
            .fullScreenCover(isPresented: $noc) { NOCGridView() }
            .sheet(isPresented: $report) { ReportSheet() }
            .sheet(isPresented: $editMine) { CustomPanelsEditor() }
            .sheet(isPresented: $rangeSheet) { CustomRangeSheet(model: model) }
            .sheet(isPresented: $thrSheet) { NavigationStack { ThresholdsView() } }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        if model.loading { ProgressView() }
                        Button { duty = true } label: { Image(systemName: "tv") }
                        Menu {
                            Button { dashes = true } label: { Label("Дашборды Grafana", systemImage: "square.grid.3x2") }
                            Button { path.append("zdash") } label: { Label("Дашборды Zabbix", systemImage: "rectangle.3.group") }
                            Button { noc = true } label: { Label("NOC-сетка всех хостов", systemImage: "square.grid.4x3.fill") }
                            Button { wall = true } label: { Label("Режим «стена» (альбомный)", systemImage: "tv.and.mediabox") }
                            Button { carousel = true } label: { Label("Карусель панелей", systemImage: "rectangle.on.rectangle") }
                            Button { searchAll = true } label: { Label("Поиск по всему", systemImage: "magnifyingglass") }
                            Button { path.append("sla") } label: { Label("Доступность филиалов (SLA)", systemImage: "checkmark.seal") }
                            Button { report = true } label: { Label("Отчёт за неделю (PDF)", systemImage: "doc.richtext") }
                            Button { editMine = true } label: { Label("Мои панели…", systemImage: "square.grid.2x2") }
                            Button { thrSheet = true } label: { Label("Свои пороги…", systemImage: "slider.horizontal.3") }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
        }
    }

    @ViewBuilder private var mineView: some View {
        if customStore.items.isEmpty {
            Button { editMine = true } label: {
                Label("Добавить свою панель: любой показатель любого хоста", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity).padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            }
        } else {
            ForEach(customStore.items) { CustomPanelView(panel: $0, seconds: model.windowSeconds, end: model.windowEnd) }
            Button { editMine = true } label: { Label("Настроить панели", systemImage: "slider.horizontal.3").font(.caption) }
        }
    }

    @ViewBuilder private func panel(_ id: String) -> some View {
        switch id {
        case "stats": PanelStatsGrid(model: model)
        case "cpu": cpuPanel
        case "week": WeekComparePanel(series: model.cpuWeek)
        case "nodes": NodeGraphPanel(rows: model.systems.rows["net"] ?? [], branches: BranchStore.shared.items)
        case "box": BoxPlotPanel(series: model.rtt)
        case "calendar": CalendarHeatPanel(events: model.history90)
        case "hourheat": HourHeatPanel(events: model.history90)
        case "cpu3d":
            if #available(iOS 26, *) { CPU3DPanel(cpu: model.cpu, mem: model.mem) }
        case "noisy": NoisyHostsPanel(events: model.history90)
        case "dfc": DiskForecastPanel(disks: model.diskFC, series: model.diskSeries)
        case "band": BandPanel(series: model.cpu)
        case "status": StatusHistoryPanel(series: model.cpu)
        case "xy": XYPanel(cpu: model.cpu, mem: model.mem)
        case "mem": gaugeList("mem", title: "Память серверов", subtitle: "bar gauge")
        case "rtt": rttPanel
        case "hist":
            HistogramPanel(title: "Распределение задержки до филиалов", subtitle: "гистограмма · \(model.windowLabel)",
                           values: model.rtt.flatMap { $0.points.map { $0.v } }, scale: 1000, suffix: " мс", bins: 12)
        case "timeline": timeline
        case "stack": StackedProblemsPanel(events: model.history)
        case "lanes": LanesPanel(events: model.history)
        case "fcast": ForecastPanel()
        case "donut": donut
        case "honey": honeycomb
        case "disk": gaugeList("disk", title: "Заполнение дисков", subtitle: "bar gauge")
        case "anom":
            PanelCard(title: "Аномалии сейчас", subtitle: "против прошлых 7 дней") { AnomalyPanel(items: model.anomalies) }
        case "treemap":
            if !model.cells.isEmpty {
                PanelCard(title: "Карта дисков", subtitle: "treemap · нажмите на том") { TreemapPanel(cells: model.cells) }
            }
        case "mine": mineView
        default: EmptyView()
        }
    }

    // MARK: временные ряды с легендой-таблицей

    private func top(_ s: [Series], n: Int = 6) -> [Series] {
        s.filter { !$0.points.isEmpty }.sorted { ($0.points.last?.v ?? 0) > ($1.points.last?.v ?? 0) }.prefix(n).map { $0 }
    }

    private func drill(_ name: String) {
        Haptics.tap()
        Task {
            let found = (try? await session.searchHosts(name)) ?? []
            if let h = found.first(where: { $0.name == name }) ?? found.first { path.append(h) }
        }
    }

    private func problemMarkers(for s: [Series]) -> [Date] {
        let hosts = Set(s.map { $0.name })
        let to = model.windowEnd
        let from = to.addingTimeInterval(-model.windowSeconds)
        return model.history.filter { $0.severity >= 4 && $0.start >= from && $0.start <= to && hosts.contains($0.host) }
            .map { $0.start }.prefix(14).map { $0 }
    }

    private func legend(_ s: [Series], unit: String?) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text("").frame(maxWidth: .infinity, alignment: .leading)
                Text("сейчас").frame(width: 56, alignment: .trailing)
                Text("макс").frame(width: 56, alignment: .trailing)
            }
            .font(.caption2).foregroundStyle(.secondary)
            ForEach(Array(s.enumerated()), id: \.element.id) { i, x in
                HStack {
                    Circle().fill(seriesPalette[i % seriesPalette.count]).frame(width: 8, height: 8)
                    Text(shortName(x.name)).font(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text(formatValue(x.points.last?.v ?? 0, unit: unit)).frame(width: 56, alignment: .trailing)
                        .foregroundStyle(unit == "percent" ? HostThrStore.shared.color(x.name, "cpu", x.points.last?.v ?? 0) : Color.primary)
                    Text(formatValue(x.points.map { $0.v }.max() ?? 0, unit: unit)).frame(width: 56, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit())
                .opacity(hidden.contains(x.name) ? 0.35 : 1)
                .contentShape(Rectangle())
                .onTapGesture {
                    if hidden.contains(x.name) { hidden.remove(x.name) } else { hidden.insert(x.name) }
                    Haptics.tap()
                }
                .onLongPressGesture {
                    let only = Set(s.map { $0.name }).subtracting([x.name])
                    hidden = (hidden == only) ? [] : only
                    Haptics.tap()
                }
            }
            Text("строка — скрыть/показать · удержание — оставить только её · удержание на графике — метка")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var cpuPanel: some View {
        let s = top(model.cpu)
        if !s.isEmpty {
            PanelCard(title: "Загрузка CPU", subtitle: "\(model.windowLabel) · топ-6") {
                TimeSeriesChart(series: s, unit: "percent",
                                thresholds: [(Thr.cpuWarn, Level.warn.color), (Thr.cpuBad, Level.bad.color)], showLegend: false,
                                markers: problemMarkers(for: s), hidden: hidden, annotationKey: "panels", prev: model.cpuPrev).chartH(170)
                legend(s, unit: "percent")
                if !problemMarkers(for: s).isEmpty {
                    Label("пунктир — проблемы на этих серверах", systemImage: "line.diagonal").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var rttPanel: some View {
        let s = top(model.rtt)
        if !s.isEmpty {
            PanelCard(title: "Задержка до филиалов", subtitle: "\(model.windowLabel) · топ-6") {
                TimeSeriesChart(series: s, unit: "s",
                                thresholds: [(Thr.rttWarn / 1000, Level.warn.color), (Thr.rttBad / 1000, Level.bad.color)], showLegend: false,
                                hidden: hidden, annotationKey: "panels", prev: model.rttPrev).chartH(170)
                legend(s, unit: "s")
            }
        }
    }

    // MARK: state timeline

    private struct Seg: Identifiable {
        let id: Int
        let host: String
        let start: Date
        let end: Date
        let up: Bool?
    }

    private var timelineData: (segs: [Seg], hosts: [String]) {
        let now = Date()
        let from = now.addingTimeInterval(-86400)
        let slots = 48
        let step = 86400.0 / Double(slots)
        var segs: [Seg] = []
        var downCount: [(String, Int)] = []
        var id = 0
        for s in model.ping where !s.points.isEmpty {
            var states: [Bool?] = Array(repeating: nil, count: slots)
            var bucket = [[Double]](repeating: [], count: slots)
            for p in s.points {
                let i = Int(p.t.timeIntervalSince(from) / step)
                if i >= 0 && i < slots { bucket[i].append(p.v) }
            }
            for i in 0..<slots where !bucket[i].isEmpty { states[i] = (bucket[i].min() ?? 1) >= 0.5 }
            let name = shortName(s.name)
            var i = 0
            while i < slots {
                var j = i
                while j + 1 < slots && states[j + 1] == states[i] { j += 1 }
                segs.append(Seg(id: id, host: name, start: from.addingTimeInterval(Double(i) * step),
                                end: from.addingTimeInterval(Double(j + 1) * step), up: states[i]))
                id += 1
                i = j + 1
            }
            downCount.append((name, states.filter { $0 == false }.count))
        }
        let hosts = downCount.sorted { $0.1 > $1.1 }.map { $0.0 }
        return (segs, hosts)
    }

    @ViewBuilder private var timeline: some View {
        let d = timelineData
        if !d.segs.isEmpty {
            PanelCard(title: "Доступность филиалов", subtitle: "24 часа · state timeline") {
                Chart(d.segs) { s in
                    BarMark(xStart: .value("с", s.start), xEnd: .value("по", s.end),
                            y: .value("хост", s.host), height: .fixed(14))
                        .foregroundStyle(s.up == nil ? Color.gray.opacity(0.16) : (s.up! ? Level.ok.color.opacity(0.85) : Level.bad.color))
                        .cornerRadius(2)
                }
                .chartYScale(domain: d.hosts)
                .chartYAxis { AxisMarks(position: .leading) { _ in AxisValueLabel(centered: true).font(.caption2) } }
                .chartPlotStyle { $0.padding(.leading, 62) }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.white.opacity(0.1))
                        AxisValueLabel(format: .dateTime.hour().minute().locale(Locale(identifier: "ru_RU")))
                    }
                }
                .frame(height: CGFloat(d.hosts.count) * 20 + 28)
                HStack(spacing: 12) {
                    legendDot(Level.ok.color, "работает")
                    legendDot(Level.bad.color, "нет связи")
                    legendDot(Color.gray, "нет данных")
                }
            }
        }
    }

    private func legendDot(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { Circle().fill(c).frame(width: 8, height: 8); Text(t).font(.caption2).foregroundStyle(.secondary) }
    }

    // MARK: honeycomb

    @ViewBuilder private var honeycomb: some View {
        let rows = (model.systems.rows["servers"] ?? []) + (model.systems.rows["net"] ?? [])
        if !rows.isEmpty {
            PanelCard(title: "Карта состояния", subtitle: "серверы и филиалы") {
                HoneycombPanel(items: rows.map { .init(id: $0.id, name: $0.name, level: $0.level) })
                HStack(spacing: 12) {
                    legendDot(Level.ok.color, "норма")
                    legendDot(Level.warn.color, "внимание")
                    legendDot(Level.bad.color, "проблема")
                }
            }
        }
    }

    // MARK: donut

    @ViewBuilder private var donut: some View {
        let sev = [5, 4, 3].map { s in (s, model.problems.filter { $0.severity == s }.count) }
        let total = sev.reduce(0) { $0 + $1.1 }
        let segs: [(value: Double, color: Color)] = total == 0
            ? [(value: 1, color: Level.ok.color)]
            : sev.map { (value: Double($0.1), color: sevColor($0.0)) }
        PanelCard(title: "Проблемы по важности", subtitle: "сейчас") {
            HStack(spacing: 18) {
                ZStack {
                    SegmentRing(segments: segs, lineWidth: 14)
                    VStack(spacing: 0) {
                        Text("\(total)").font(.system(size: 26, weight: .bold, design: .rounded))
                        Text("всего").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 110, height: 110)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(sev, id: \.0) { s in
                        HStack {
                            Circle().fill(sevColor(s.0)).frame(width: 9, height: 9)
                            Text(sevName(s.0)).font(.subheadline)
                            Spacer()
                            Text("\(s.1)").font(.subheadline.weight(.bold).monospacedDigit())
                        }
                    }
                }
            }
        }
    }

    // MARK: bar gauge

    private func gaugeList(_ col: String, title: String, subtitle: String) -> some View {
        let rows = (model.systems.rows["servers"] ?? [])
            .compactMap { r in r.values[col].map { (name: r.name, v: $0) } }
            .sorted { $0.v > $1.v }.prefix(7)
        return Group {
            if !rows.isEmpty {
                PanelCard(title: title, subtitle: subtitle) {
                    VStack(spacing: 8) {
                        ForEach(Array(rows), id: \.name) { r in
                            let c: Color = HostThrStore.shared.color(r.name, col == "disk" ? "disk" : "mem", r.v)
                            VStack(spacing: 3) {
                                HStack {
                                    Text(r.name).font(.caption).lineLimit(1)
                                    Spacer()
                                    Text(String(format: "%.0f%%", r.v)).font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(c)
                                }
                                BarGauge(fraction: r.v / 100, color: c, height: 8)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var bars: some View {
        gaugeList("mem", title: "Память серверов", subtitle: "bar gauge")
        gaugeList("disk", title: "Заполнение дисков", subtitle: "bar gauge")
    }
}


// MARK: Сетка stat-панелей (используется на «Обзоре» и во вкладке «Панели»)

struct PanelStatsGrid: View {
    @ObservedObject var model: PanelsModel

    private func level(_ v: Double?, warn: Double, bad: Double) -> Color {
        guard let v else { return .gray }
        return v >= bad ? Level.bad.color : (v >= warn ? Level.warn.color : Level.ok.color)
    }

    private var uptime: Double? {
        let v = model.ping.flatMap { $0.points.map { $0.v } }
        return v.isEmpty ? nil : Double(v.filter { $0 >= 0.5 }.count) / Double(v.count) * 100
    }

    var body: some View {
        let cpu = average(lastValues(model.cpu))
        let mem = average(lastValues(model.mem))
        let rtt = average(lastValues(model.rtt))
        let up = uptime
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            StatPanel(title: "CPU серверов, среднее", value: cpu.map { String(format: "%.0f%%", $0) } ?? "—",
                      color: level(cpu, warn: Thr.cpuWarn, bad: Thr.cpuBad), spark: averaged(model.cpu))
            StatPanel(title: "RAM серверов, среднее", value: mem.map { String(format: "%.0f%%", $0) } ?? "—",
                      color: level(mem, warn: Thr.memWarn, bad: Thr.memBad), spark: averaged(model.mem))
            StatPanel(title: "Задержка до филиалов", value: rtt.map { String(format: "%.0f мс", $0 * 1000) } ?? "—",
                      color: level(rtt.map { $0 * 1000 }, warn: Thr.rttWarn, bad: Thr.rttBad), spark: averaged(model.rtt))
            StatPanel(title: "Доступность филиалов 24ч", value: up.map { String(format: "%.1f%%", $0) } ?? "—",
                      color: up.map { $0 >= Thr.uptime ? Level.ok.color : ($0 >= Thr.uptime - 2.5 ? Level.warn.color : Level.bad.color) } ?? .gray,
                      spark: averaged(model.ping).map { Pt(id: $0.id, t: $0.t, v: $0.v * 100) })
        }
    }
}

/// Загрузка CPU по серверам: график с порогами и легендой.
struct CPUPanelCard: View {
    @ObservedObject var model: PanelsModel

    var body: some View {
        let s = model.cpu.filter { !$0.points.isEmpty }
            .sorted { ($0.points.last?.v ?? 0) > ($1.points.last?.v ?? 0) }.prefix(5).map { $0 }
        if !s.isEmpty {
            PanelCard(title: "Загрузка CPU", subtitle: "\(model.windowLabel) · топ-5") {
                TimeSeriesChart(series: s, unit: "percent",
                                thresholds: [(Thr.cpuWarn, Level.warn.color), (Thr.cpuBad, Level.bad.color)], showLegend: false).chartH(150)
                HStack(spacing: 10) {
                    ForEach(Array(s.enumerated()), id: \.element.id) { i, x in
                        HStack(spacing: 4) {
                            Circle().fill(seriesPalette[i % seriesPalette.count]).frame(width: 7, height: 7)
                            Text(shortName(x.name)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}

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
    @Published var groupIndex: Int = 0
    let systems = SystemsModel()

    static let groups: [(title: String, regex: String)] = [
        ("Все серверы", serverGroups), ("Гипервизоры", "/^Hypervisors$/"), ("Exchange", "/^Exchange$/"),
        ("Контроллеры домена", "/^Domain Controllers$/"), ("Linux", "/^Linux servers$/")
    ]
    var groupRegex: String { PanelsModel.groups[groupIndex].regex }

    /// Только метрики для графиков (без экранов «Систем» и проблем).
    func loadMetrics(session: Session) async {
        cpu = (try? await session.hostSeries(host: "/.*/", filter: "CPU utilization", range: range, group: groupRegex)) ?? []
        mem = (try? await session.hostSeries(host: "/.*/", filter: "Memory utilization", range: range, group: groupRegex)) ?? []
        rtt = (try? await session.hostSeries(host: "/.*/", filter: "ICMP response time", range: range, group: "Mikrotik")) ?? []
        ping = (try? await session.hostSeries(host: "/.*/", filter: "ICMP ping", range: .h24, group: "Mikrotik")) ?? []
    }

    func load(session: Session) async {
        loading = true
        defer { loading = false }
        cpu = (try? await session.hostSeries(host: "/.*/", filter: "CPU utilization", range: range, group: groupRegex)) ?? []
        mem = (try? await session.hostSeries(host: "/.*/", filter: "Memory utilization", range: range, group: groupRegex)) ?? []
        rtt = (try? await session.hostSeries(host: "/.*/", filter: "ICMP response time", range: range, group: "Mikrotik")) ?? []
        ping = (try? await session.hostSeries(host: "/.*/", filter: "ICMP ping", range: .h24, group: "Mikrotik")) ?? []
        problems = (try? await session.loadProblems()) ?? []
        history = (try? await session.problemHistory(days: 7)) ?? history
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
    let title: String
    var subtitle: String?
    var shareable = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary) }
                if shareable {
                    Button { sharePanel(PanelCard(title: title, subtitle: subtitle, shareable: false, content: content)) } label: {
                        Image(systemName: "square.and.arrow.up").font(.caption).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            content()
        }
        .padding(12)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06)))
    }
}

struct StatPanel: View {
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
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .frame(height: 112)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 10))
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
    @State private var duty = Launch.screen == "duty"
    private let timer = Timer.publish(every: 120, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Picker("Период", selection: $model.range) {
                        ForEach(TimeRange.allCases) { Text($0.shortLabel).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Menu {
                            Picker("Группа", selection: $model.groupIndex) {
                                ForEach(PanelsModel.groups.indices, id: \.self) { Text(PanelsModel.groups[$0].title).tag($0) }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text("Группа:").foregroundStyle(.secondary)
                                Text(PanelsModel.groups[model.groupIndex].title).foregroundStyle(.orange)
                                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Color(white: 0.14), in: Capsule())
                        }
                        Spacer()
                    }
                    if let set = Launch.panelSet {
                        ForEach(set, id: \.self) { panel($0) }
                    } else {
                        panel("stats")
                        DashRow(id: "servers", title: "Серверы", icon: "server.rack") {
                            ForEach(["cpu", "band", "status", "xy", "mem"], id: \.self) { panel($0) }
                        }
                        DashRow(id: "net", title: "Сеть и филиалы", icon: "network") {
                            ForEach(["rtt", "hist", "timeline"], id: \.self) { panel($0) }
                        }
                        DashRow(id: "problems", title: "Проблемы", icon: "exclamationmark.triangle") {
                            ForEach(["stack", "donut", "honey", "disk"], id: \.self) { panel($0) }
                        }
                    }
                }
                .padding(12)
            }
            .background(Color(white: 0.07))
            .navigationTitle("Панели")
            .refreshable { await model.load(session: session) }
            .task { await model.load(session: session) }
            .onReceive(timer) { _ in Task { await model.load(session: session) } }
            .onChange(of: model.range) { _ in Task { await model.loadMetrics(session: session) } }
            .onChange(of: model.groupIndex) { _ in Task { await model.loadMetrics(session: session) } }
            .fullScreenCover(isPresented: $duty) { DutyView() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        if model.loading { ProgressView() }
                        Button { duty = true } label: { Image(systemName: "tv") }
                    }
                }
            }
        }
    }

    @ViewBuilder private func panel(_ id: String) -> some View {
        switch id {
        case "stats": PanelStatsGrid(model: model)
        case "cpu": cpuPanel
        case "band": BandPanel(series: model.cpu)
        case "status": StatusHistoryPanel(series: model.cpu)
        case "xy": XYPanel(cpu: model.cpu, mem: model.mem)
        case "mem": gaugeList("mem", title: "Память серверов", subtitle: "bar gauge")
        case "rtt": rttPanel
        case "hist":
            HistogramPanel(title: "Распределение задержки до филиалов", subtitle: "гистограмма · \(model.range.label)",
                           values: model.rtt.flatMap { $0.points.map { $0.v } }, scale: 1000, suffix: " мс", bins: 12)
        case "timeline": timeline
        case "stack": StackedProblemsPanel(events: model.history)
        case "donut": donut
        case "honey": honeycomb
        case "disk": gaugeList("disk", title: "Заполнение дисков", subtitle: "bar gauge")
        default: EmptyView()
        }
    }

    // MARK: временные ряды с легендой-таблицей

    private func top(_ s: [Series], n: Int = 6) -> [Series] {
        s.filter { !$0.points.isEmpty }.sorted { ($0.points.last?.v ?? 0) > ($1.points.last?.v ?? 0) }.prefix(n).map { $0 }
    }

    private func problemMarkers(for s: [Series]) -> [Date] {
        let hosts = Set(s.map { $0.name })
        let from = Date().addingTimeInterval(-model.range.seconds)
        return model.history.filter { $0.severity >= 4 && $0.start >= from && hosts.contains($0.host) }
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
                    Text(formatValue(x.points.map { $0.v }.max() ?? 0, unit: unit)).frame(width: 56, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit())
            }
        }
    }

    @ViewBuilder private var cpuPanel: some View {
        let s = top(model.cpu)
        if !s.isEmpty {
            PanelCard(title: "Загрузка CPU", subtitle: "\(model.range.label) · топ-6") {
                TimeSeriesChart(series: s, unit: "percent",
                                thresholds: [(80, Level.warn.color), (90, Level.bad.color)], showLegend: false,
                                markers: problemMarkers(for: s)).frame(height: 170)
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
            PanelCard(title: "Задержка до филиалов", subtitle: "\(model.range.label) · топ-6") {
                TimeSeriesChart(series: s, unit: "s",
                                thresholds: [(0.15, Level.warn.color), (0.4, Level.bad.color)], showLegend: false).frame(height: 170)
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
                            let c: Color = r.v >= 92 ? Level.bad.color : (r.v >= 85 ? Level.warn.color : Level.ok.color)
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
                      color: level(cpu, warn: 70, bad: 85), spark: averaged(model.cpu))
            StatPanel(title: "RAM серверов, среднее", value: mem.map { String(format: "%.0f%%", $0) } ?? "—",
                      color: level(mem, warn: 80, bad: 90), spark: averaged(model.mem))
            StatPanel(title: "Задержка до филиалов", value: rtt.map { String(format: "%.0f мс", $0 * 1000) } ?? "—",
                      color: level(rtt.map { $0 * 1000 }, warn: 120, bad: 300), spark: averaged(model.rtt))
            StatPanel(title: "Доступность филиалов 24ч", value: up.map { String(format: "%.1f%%", $0) } ?? "—",
                      color: up.map { $0 >= 99.5 ? Level.ok.color : ($0 >= 97 ? Level.warn.color : Level.bad.color) } ?? .gray,
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
            PanelCard(title: "Загрузка CPU", subtitle: "\(model.range.label) · топ-5") {
                TimeSeriesChart(series: s, unit: "percent",
                                thresholds: [(80, Level.warn.color), (90, Level.bad.color)], showLegend: false).frame(height: 150)
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

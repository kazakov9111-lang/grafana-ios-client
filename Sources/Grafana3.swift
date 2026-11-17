import SwiftUI
import Charts

// v2.4: пороги, метки на графиках, «Что менялось», аномалии, SLA, treemap дисков.

func meanStd(_ v: [Double]) -> (mean: Double, std: Double) {
    guard !v.isEmpty else { return (0, 0) }
    let m = v.reduce(0, +) / Double(v.count)
    let s = (v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count)).squareRoot()
    return (m, s)
}

// MARK: Свои пороги

enum Thr {
    private static func d(_ k: String, _ def: Double) -> Double {
        (UserDefaults.standard.object(forKey: k) as? Double) ?? def
    }
    static var cpuWarn: Double { d("thr.cpuWarn", 80) }
    static var cpuBad: Double { d("thr.cpuBad", 90) }
    static var memWarn: Double { d("thr.memWarn", 85) }
    static var memBad: Double { d("thr.memBad", 92) }
    static var diskWarn: Double { d("thr.diskWarn", 85) }
    static var diskBad: Double { d("thr.diskBad", 92) }
    static var rttWarn: Double { d("thr.rttWarn", 150) }   // мс
    static var rttBad: Double { d("thr.rttBad", 400) }     // мс
    static var uptime: Double { d("thr.uptime", 99.5) }    // %

    static let keys = ["thr.cpuWarn", "thr.cpuBad", "thr.memWarn", "thr.memBad", "thr.diskWarn", "thr.diskBad",
                       "thr.rttWarn", "thr.rttBad", "thr.uptime"]

    static func color(_ v: Double, warn: Double, bad: Double) -> Color {
        v >= bad ? Level.bad.color : (v >= warn ? Level.warn.color : Level.ok.color)
    }
}

struct ThresholdsView: View {
    @AppStorage("thr.cpuWarn") private var cpuWarn = 80.0
    @AppStorage("thr.cpuBad") private var cpuBad = 90.0
    @AppStorage("thr.memWarn") private var memWarn = 85.0
    @AppStorage("thr.memBad") private var memBad = 92.0
    @AppStorage("thr.diskWarn") private var diskWarn = 85.0
    @AppStorage("thr.diskBad") private var diskBad = 92.0
    @AppStorage("thr.rttWarn") private var rttWarn = 150.0
    @AppStorage("thr.rttBad") private var rttBad = 400.0
    @AppStorage("thr.uptime") private var uptime = 99.5

    private func row(_ title: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, step: Double, suffix: String) -> some View {
        Stepper(value: v, in: r, step: step) {
            HStack { Text(title); Spacer(); Text("\(v.wrappedValue.formatted())\(suffix)").foregroundStyle(.orange).monospacedDigit() }
        }
    }

    var body: some View {
        Form {
            Section("CPU, %") {
                row("Внимание (жёлтый)", $cpuWarn, 1...100, step: 1, suffix: "%")
                row("Проблема (красный)", $cpuBad, 1...100, step: 1, suffix: "%")
            }
            Section("Память, %") {
                row("Внимание", $memWarn, 1...100, step: 1, suffix: "%")
                row("Проблема", $memBad, 1...100, step: 1, suffix: "%")
            }
            Section("Диски, %") {
                row("Внимание", $diskWarn, 1...100, step: 1, suffix: "%")
                row("Проблема", $diskBad, 1...100, step: 1, suffix: "%")
            }
            Section("Задержка до филиалов, мс") {
                row("Внимание", $rttWarn, 5...2000, step: 5, suffix: " мс")
                row("Проблема", $rttBad, 5...5000, step: 10, suffix: " мс")
            }
            Section("Доступность филиалов") {
                row("Цель (SLA)", $uptime, 90...100, step: 0.1, suffix: "%")
            }
            Section {
                Button("Вернуть значения по умолчанию", role: .destructive) {
                    Thr.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
                    cpuWarn = 80; cpuBad = 90; memWarn = 85; memBad = 92; diskWarn = 85; diskBad = 92
                    rttWarn = 150; rttBad = 400; uptime = 99.5
                }
            } footer: {
                Text("Пороги действуют на вкладке «Панели» и в обзоре: цвета, пунктирные линии на графиках, плитки и шкалы. Цвета колонок в списках «Систем» заданы в самих экранах и от этих настроек не зависят.")
            }
        }
        .navigationTitle("Свои пороги")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: Свои метки на графиках

struct Annotation: Codable, Identifiable, Hashable {
    var id = UUID()
    var key: String
    var date: Date
    var text: String
    var remoteId: Int? = nil
}

final class Annotations: ObservableObject {
    static let shared = Annotations()
    @Published var items: [Annotation] { didSet { save() } }
    /// Отправка метки в Grafana (ставится после входа); возвращает id аннотации.
    var sink: ((Date, String) async -> Int?)?

    init() {
        if let d = UserDefaults.standard.data(forKey: "annotations"),
           let v = try? JSONDecoder().decode([Annotation].self, from: d) {
            items = v
        } else if Launch.demo {
            items = [Annotation(key: "panels", date: Date().addingTimeInterval(-3 * 3600), text: "Обновление прошивки")]
        } else {
            items = []
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: "annotations") }
    }

    func add(key: String, date: Date, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let a = Annotation(key: key, date: date, text: t)
        items.append(a)
        if items.count > 300 { items.removeFirst(items.count - 300) }
        if key == "panels", let sink {
            Task { @MainActor in
                if let rid = await sink(date, t), let i = self.items.firstIndex(where: { $0.id == a.id }) { self.items[i].remoteId = rid }
            }
        }
    }
}

struct AnnotationsListView: View {
    @ObservedObject private var store = Annotations.shared

    var body: some View {
        List {
            if store.items.isEmpty {
                Text("Меток пока нет. Нажмите на график на вкладке «Панели» и удерживайте палец, чтобы добавить метку. Метка также ставится сама, когда вы подтверждаете проблему.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(store.items.sorted { $0.date > $1.date }) { a in
                NavigationLink { BeforeAfterView(date: a.date, title: a.text) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(a.text)
                            if a.remoteId != nil { Image(systemName: "icloud.fill").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Text(ruDate(a.date) + " · сравнить до и после").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { idx in
                let sorted = store.items.sorted { $0.date > $1.date }
                let ids = Set(idx.map { sorted[$0].id })
                store.items.removeAll { ids.contains($0.id) }
            }
        }
        .navigationTitle("Мои метки")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }
}

struct AnnoGesture: ViewModifier {
    let enabled: Bool
    let proxy: ChartProxy
    let geo: GeometryProxy
    let onAdd: (Date) -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.simultaneousGesture(
                LongPressGesture(minimumDuration: 0.6).sequenced(before: DragGesture(minimumDistance: 0))
                    .onEnded { v in
                        if case .second(true, let d?) = v {
                            let x = d.location.x - geo[proxy.plotAreaFrame].origin.x
                            if let t: Date = proxy.value(atX: x) { onAdd(t) }
                        }
                    })
        } else {
            content
        }
    }
}

// MARK: «Что менялось» в карточке проблемы

struct ContextChange: Identifiable {
    let id: Int
    let name: String
    let series: Series
    let score: Double
    let before: Double
    let after: Double
}

enum ContextLoader {
    static let words = ["cpu", "memory", "ram", "space", "disk", "icmp", "ping", "response", "loss", "queue", "load",
                        "bits", "error", "latency", "processor", "очеред", "памят", "диск"]

    @MainActor static func load(session: Session, problem: Problem) async -> [ContextChange] {
        let found = (try? await session.searchHosts(problem.host)) ?? []
        guard let h = found.first(where: { $0.name == problem.host }) ?? found.first else { return [] }
        let its = (try? await session.hostItems(h.id)) ?? []
        let names = its.filter { it in
            it.numeric != nil && !it.name.isEmpty && !it.name.lowercased().contains("total") && words.contains { it.name.lowercased().contains($0) }
        }.map { $0.name }
        let uniq = Array(Set(names)).sorted().prefix(18)
        guard !uniq.isEmpty else { return [] }
        let esc = NSRegularExpression.escapedPattern(for: h.name)
        let filt = "/^(" + uniq.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")$/"
        let end = min(Date(), problem.clock.addingTimeInterval(3600))
        let ser = (try? await session.hostSeries(host: "/^\(esc)$/", filter: filt, seconds: 7200, group: "/.*/",
                                                 maxPoints: 120, to: end)) ?? []
        var out: [ContextChange] = []
        for (i, s) in ser.enumerated() where s.points.count >= 8 {
            let before = s.points.filter { $0.t < problem.clock }.map { $0.v }
            let after = s.points.filter { $0.t >= problem.clock }.map { $0.v }
            guard before.count >= 3, after.count >= 3 else { continue }
            let b = meanStd(before)
            let a = meanStd(after).mean
            let all = s.points.map { $0.v }
            let spread = (all.max() ?? 0) - (all.min() ?? 0)
            guard abs(a - b.mean) > 1e-9 else { continue }
            let score = abs(a - b.mean) / (b.std + 0.05 * abs(b.mean) + 0.02 * spread + 1e-9)
            out.append(ContextChange(id: i, name: s.item.isEmpty ? s.name : s.item, series: s, score: score,
                                     before: b.mean, after: a))
        }
        return Array(out.sorted { $0.score > $1.score }.prefix(4))
    }
}

struct ProblemContextSection: View {
    @EnvironmentObject var session: Session
    let problem: Problem
    @State private var items: [ContextChange] = []
    @State private var done = false

    var body: some View {
        Section {
            if !done {
                HStack { ProgressView(); Text("Ищу изменения рядом с началом…").font(.caption).foregroundStyle(.secondary) }
            } else if items.isEmpty {
                Text("Заметных изменений показателей хоста за час до и после начала не найдено.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(items) { c in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(c.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Spacer()
                        Text("\(formatValue(c.before, unit: c.series.unit)) → \(formatValue(c.after, unit: c.series.unit))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.orange)
                    }
                    Chart {
                        ForEach(c.series.points) { p in
                            LineMark(x: .value("t", p.t), y: .value("v", p.v))
                                .foregroundStyle(Color.orange).interpolationMethod(.monotone)
                        }
                        RuleMark(x: .value("начало", problem.clock))
                            .foregroundStyle(Level.bad.color)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisValueLabel(format: .dateTime.hour().minute().locale(Locale(identifier: "ru_RU")))
                        }
                    }
                    .chartYAxis(.hidden)
                    .frame(height: 70)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Что менялось рядом")
        } footer: {
            if !items.isEmpty { Text("Показатели хоста за час до и после начала проблемы, самые резкие изменения сверху. Красный пунктир — начало проблемы.") }
        }
        .task {
            items = await ContextLoader.load(session: session, problem: problem)
            done = true
        }
    }
}

// MARK: Аномалии сейчас

struct Anomaly: Identifiable {
    let id: String
    let host: String
    let metric: String
    let unit: String?
    let current: Double
    let normal: Double
    let z: Double
    let spark: [Pt]
}

enum AnomalyScan {
    /// Сравнивает последнее значение с тем же временем суток за предыдущие 7 дней.
    static func scan(_ series: [Series], metric: String, unit: String?, minDelta: Double) -> [Anomaly] {
        var out: [Anomaly] = []
        for s in series where s.points.count >= 100 {
            let pts = s.points.sorted { $0.t < $1.t }
            guard let last = pts.last else { continue }
            let cur = meanStd(pts.suffix(3).map { $0.v }).mean
            var base: [Double] = []
            for k in 1...7 {
                let c = last.t.addingTimeInterval(-Double(k) * 86400)
                base += pts.filter { abs($0.t.timeIntervalSince(c)) <= 2400 }.map { $0.v }
            }
            guard base.count >= 10 else { continue }
            let b = meanStd(base)
            let z = (cur - b.mean) / max(b.std, 0.03 * max(abs(b.mean), 1))
            guard z >= 3, cur - b.mean >= minDelta else { continue }
            let day = pts.filter { $0.t > last.t.addingTimeInterval(-86400) }
            let stride = max(1, day.count / 60)
            let spark = day.enumerated().filter { $0.offset % stride == 0 }.map { $0.element }
            out.append(Anomaly(id: metric + s.name, host: s.name, metric: metric, unit: unit, current: cur,
                               normal: b.mean, z: z, spark: spark))
        }
        return out
    }
}

struct AnomalyPanel: View {
    let items: [Anomaly]
    @Environment(\.drillDown) private var drill

    var body: some View {
        if items.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Level.ok.color)
                Text("Всё в пределах привычного для этого времени суток").font(.subheadline)
            }
            .padding(.vertical, 6)
        } else {
            VStack(spacing: 10) {
                ForEach(items.prefix(6)) { a in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(branchName(a.host)).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text("\(a.metric): \(formatValue(a.current, unit: a.unit)), обычно \(formatValue(a.normal, unit: a.unit))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Sparkline(points: a.spark, color: Level.warn.color).frame(width: 70, height: 28)
                        Text(String(format: "%.1fσ", a.z)).font(.caption.weight(.bold).monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(a.z >= 5 ? Level.bad.color : Level.warn.color, in: Capsule())
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { drill?(a.host) }
                }
            }
        }
    }
}

// MARK: SLA по филиалам

struct SLARow: Identifiable {
    let id: String
    let name: String
    let up7: Double
    let up30: Double
    let out7: Int
    let out30: Int
    let down7: TimeInterval
    let down30: TimeInterval
}

@MainActor
final class SLAModel: ObservableObject {
    @Published var rows: [SLARow] = []
    @Published var loading = false

    private func stat(_ pts: [Pt], from: Date, step: TimeInterval) -> (Double, Int, TimeInterval) {
        let p = pts.filter { $0.t >= from }
        guard !p.isEmpty else { return (100, 0, 0) }
        let down = p.filter { $0.v < 0.5 }.count
        var out = 0
        var prev = true
        for x in p {
            let up = x.v >= 0.5
            if !up && prev { out += 1 }
            prev = up
        }
        return (Double(p.count - down) / Double(p.count) * 100, out, Double(down) * step)
    }

    func load(session: Session) async {
        loading = true
        defer { loading = false }
        let ser = (try? await session.hostSeries(host: "/.*/", filter: "ICMP ping", seconds: 30 * 86400,
                                                 group: "Mikrotik", maxPoints: 720)) ?? []
        let now = Date()
        var out: [SLARow] = []
        for s in ser where s.points.count > 3 {
            let pts = s.points.sorted { $0.t < $1.t }
            let step = (pts.last!.t.timeIntervalSince(pts.first!.t)) / Double(pts.count - 1)
            let a = stat(pts, from: now.addingTimeInterval(-7 * 86400), step: step)
            let b = stat(pts, from: now.addingTimeInterval(-30 * 86400), step: step)
            out.append(SLARow(id: s.name, name: s.name, up7: a.0, up30: b.0, out7: a.1, out30: b.1, down7: a.2, down30: b.2))
        }
        rows = out.sorted { $0.up30 < $1.up30 }
    }
}

struct SLARing: View {
    let value: Double
    let target: Double

    var body: some View {
        let c = value >= target ? Level.ok.color : (value >= target - 2 ? Level.warn.color : Level.bad.color)
        ZStack {
            Circle().stroke(Color.white.opacity(0.1), lineWidth: 12)
            Circle().trim(from: 0, to: max(0.001, min(1, value / 100)))
                .stroke(c, style: StrokeStyle(lineWidth: 12, lineCap: .round)).rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(String(format: "%.2f%%", value)).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(c)
                Text("цель \(target.formatted())%").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 130, height: 130)
    }
}

func shortDuration(_ s: TimeInterval) -> String {
    if s < 60 { return "0 мин" }
    let m = Int(s / 60)
    if m < 60 { return "\(m) мин" }
    let h = m / 60
    if h < 48 { return "\(h) ч \(m % 60) мин" }
    return "\(h / 24) дн \(h % 24) ч"
}

struct SLASummary: View {
    let rows: [SLARow]
    let days: Int
    var limit = 8

    private func up(_ r: SLARow) -> Double { days == 7 ? r.up7 : r.up30 }
    private func outs(_ r: SLARow) -> Int { days == 7 ? r.out7 : r.out30 }
    private func down(_ r: SLARow) -> TimeInterval { days == 7 ? r.down7 : r.down30 }

    var body: some View {
        let target = Thr.uptime
        let avg = rows.isEmpty ? 100 : rows.map(up).reduce(0, +) / Double(rows.count)
        let below = rows.filter { up($0) < target }.count
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                SLARing(value: avg, target: target)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Среднее по филиалам за \(days) дн.").font(.subheadline.weight(.semibold))
                    Text("Ниже цели: \(below) из \(rows.count)").font(.caption)
                        .foregroundStyle(below == 0 ? Level.ok.color : Level.bad.color)
                    Text("Сбоев всего: \(rows.map(outs).reduce(0, +))").font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 6) {
                ForEach(rows.sorted { up($0) < up($1) }.prefix(limit)) { r in
                    HStack {
                        Text(branchName(r.name)).font(.caption).frame(width: 96, alignment: .leading).lineLimit(1).minimumScaleFactor(0.8)
                        BarGauge(fraction: up(r) / 100, color: up(r) >= target ? Level.ok.color : (up(r) >= target - 2 ? Level.warn.color : Level.bad.color), height: 6)
                        Text(String(format: "%.2f%%", up(r))).font(.caption.monospacedDigit()).frame(width: 58, alignment: .trailing)
                        Text(outs(r) == 0 ? "—" : "\(outs(r))× · \(shortDuration(down(r)))").font(.caption2)
                            .foregroundStyle(.secondary).frame(width: 82, alignment: .trailing).lineLimit(1)
                    }
                }
            }
        }
    }
}

struct SLAView: View {
    @EnvironmentObject var session: Session
    @StateObject private var model = SLAModel()
    @State private var days = Launch.screen == "sla7" ? 7 : 30

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Picker("Период", selection: $days) { Text("7 дней").tag(7); Text("30 дней").tag(30) }.pickerStyle(.segmented)
                if model.rows.isEmpty {
                    if model.loading { ProgressView().padding(40) }
                    else { Text("Нет данных по доступности филиалов").foregroundStyle(.secondary).padding(40) }
                } else {
                    PanelCard(title: "Доступность филиалов (SLA)", subtitle: "ICMP ping · \(days) дн.", expandable: false) {
                        SLASummary(rows: model.rows, days: days, limit: 30)
                    }
                    Text("Доступность считается по ответам ICMP ping от Zabbix: доля замеров, на которые филиал ответил. Цель меняется в Настройки → Свои пороги.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
        .background(Color(white: 0.07))
        .navigationTitle("Доступность (SLA)")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(session: session) }
        .refreshable { await model.load(session: session) }
    }
}

// MARK: Treemap дисков

struct DiskCell: Identifiable {
    let id: String
    let host: String
    let disk: String
    let usedPct: Double
    let total: Double?
    var weight: Double { total.map { $0 * usedPct / 100 } ?? usedPct }
}

extension Session {
    func diskCells() async throws -> [DiskCell] {
        let hosts = try await matchedHosts(group: systemScreens[0].group, host: "/.*/")
        guard !hosts.isEmpty else { return [] }
        var hostName: [String: String] = [:]
        for h in hosts { hostName[h.id] = h.name }
        func get(_ q: String) async throws -> [JSON] {
            try await zabbix("item.get", [
                "hostids": .array(hosts.map { .string($0.id) }),
                "output": .array(["itemid", "name", "lastvalue", "hostid"].map { .string($0) }),
                "search": .object(["name": .string(q)]),
                "webitems": .bool(true)
            ])
        }
        func disk(_ raw: String) -> String {
            if let a = raw.firstIndex(of: "["), let b = raw.firstIndex(of: "]"), a < b { return String(raw[raw.index(after: a)..<b]) }
            return raw
        }
        let used = try await get("Space: Used, in %")
        let totals = try await get("Space: Total")
        var tot: [String: Double] = [:]
        for t in totals {
            guard let h = t["hostid"].string, let v = Double(t["lastvalue"].string ?? ""), v > 0 else { continue }
            tot[h + "|" + disk(t["name"].string ?? "")] = v
        }
        var out: [DiskCell] = []
        for u in used {
            guard let h = u["hostid"].string, let id = u["itemid"].string, let p = Double(u["lastvalue"].string ?? "") else { continue }
            let d = disk(u["name"].string ?? "")
            out.append(DiskCell(id: id, host: hostName[h] ?? "", disk: d, usedPct: p, total: tot[h + "|" + d]))
        }
        return out
    }
}

func treemapLayout(_ items: [DiskCell], in rect: CGRect) -> [(DiskCell, CGRect)] {
    let sorted = items.filter { $0.weight > 0 }.sorted { $0.weight > $1.weight }
    return treemapSplit(sorted[...], rect)
}

private func treemapSplit(_ a: ArraySlice<DiskCell>, _ r: CGRect) -> [(DiskCell, CGRect)] {
    if a.isEmpty { return [] }
    if a.count == 1, let f = a.first { return [(f, r)] }
    let total = a.reduce(0) { $0 + $1.weight }
    var acc = 0.0
    var idx = a.startIndex
    for i in a.indices {
        acc += a[i].weight
        idx = i
        if acc >= total / 2 { break }
    }
    if idx >= a.endIndex - 1 { idx = a.endIndex - 2 }
    let first = a[a.startIndex...idx], second = a[(idx + 1)...]
    let f = first.reduce(0) { $0 + $1.weight } / total
    if r.width >= r.height {
        let w = r.width * f
        return treemapSplit(first, CGRect(x: r.minX, y: r.minY, width: w, height: r.height))
            + treemapSplit(second, CGRect(x: r.minX + w, y: r.minY, width: r.width - w, height: r.height))
    } else {
        let h = r.height * f
        return treemapSplit(first, CGRect(x: r.minX, y: r.minY, width: r.width, height: h))
            + treemapSplit(second, CGRect(x: r.minX, y: r.minY + h, width: r.width, height: r.height - h))
    }
}

struct TreemapPanel: View {
    let cells: [DiskCell]
    @Environment(\.drillDown) private var drill

    private func bytes(_ v: Double) -> String {
        let tb = v / 1e12
        return tb >= 1 ? String(format: "%.1f ТБ", tb) : String(format: "%.0f ГБ", v / 1e9)
    }

    var body: some View {
        let w = UIScreen.main.bounds.width - 48
        let h: CGFloat = 230
        let hasTotals = cells.contains { $0.total != nil }
        let lay = treemapLayout(cells, in: CGRect(x: 0, y: 0, width: w, height: h))
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                ForEach(lay, id: \.0.id) { c, r in
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(heatColor(c.usedPct, lo: 40, hi: 95))
                        Rectangle().stroke(Color.black.opacity(0.55), lineWidth: 1.5)
                        if r.width > 44 && r.height > 28 {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(shortName(c.host)).font(.system(size: 10, weight: .bold)).lineLimit(1)
                                Text("\(c.disk) \(Int(c.usedPct))%").font(.system(size: 9)).lineLimit(1)
                                if r.height > 46, let t = c.total {
                                    Text(bytes(t * c.usedPct / 100)).font(.system(size: 9)).lineLimit(1).opacity(0.85)
                                }
                            }
                            .foregroundStyle(Color.black.opacity(0.85)).padding(4)
                        }
                    }
                    .frame(width: max(0, r.width), height: max(0, r.height))
                    .contentShape(Rectangle())
                    .onTapGesture { drill?(c.host) }
                    .position(x: r.midX, y: r.midY)
                }
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(hasTotals ? "Площадь — сколько занято (ГБ/ТБ), цвет — процент заполнения тома."
                           : "Размеры томов не получены: площадь показывает процент заполнения, цвет — тоже.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

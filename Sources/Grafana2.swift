import SwiftUI
import Charts

// Версия 2.3: общий курсор и масштаб, полноэкранный режим, сравнение с прошлой неделей,
// прогноз дисков, node graph, календарь проблем, box plot, шумные хосты, спарклайны.

// MARK: Общее состояние графиков и окружение

final class ChartSync: ObservableObject {
    @Published var crosshair: Date?
    @Published var zoom: ClosedRange<Date>?
}

private struct FsHeightKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }
private struct DrillKey: EnvironmentKey { static let defaultValue: ((String) -> Void)? = nil }

extension EnvironmentValues {
    /// Высота, доступная графику в полноэкранном режиме (nil — обычный режим).
    var fsHeight: CGFloat? {
        get { self[FsHeightKey.self] }
        set { self[FsHeightKey.self] = newValue }
    }
    /// Переход к хосту по имени (из status history, XY, honeycomb, node graph).
    var drillDown: ((String) -> Void)? {
        get { self[DrillKey.self] }
        set { self[DrillKey.self] = newValue }
    }
}

struct ChartHeight: ViewModifier {
    @Environment(\.fsHeight) private var fs
    let base: CGFloat
    func body(content: Content) -> some View {
        content.frame(height: fs.map { max(base, $0 - 110) } ?? base)
    }
}

extension View {
    func chartH(_ base: CGFloat) -> some View { modifier(ChartHeight(base: base)) }
}

/// Выделение интервала пальцем и щипок для масштаба (только в полноэкранном режиме).
struct ZoomGestures: ViewModifier {
    let enabled: Bool
    let proxy: ChartProxy
    let geo: GeometryProxy
    let full: ClosedRange<Date>
    let sync: ChartSync
    @Binding var a: CGFloat?
    @Binding var b: CGFloat?

    func body(content: Content) -> some View {
        if enabled {
            content
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { v in a = a ?? v.startLocation.x; b = v.location.x }
                        .onEnded { v in
                            defer { a = nil; b = nil }
                            let o = geo[proxy.plotAreaFrame].origin.x
                            guard abs(v.location.x - v.startLocation.x) > 24,
                                  let d1: Date = proxy.value(atX: v.startLocation.x - o),
                                  let d2: Date = proxy.value(atX: v.location.x - o) else { return }
                            sync.zoom = min(d1, d2)...max(d1, d2)
                        }
                )
                .simultaneousGesture(
                    MagnificationGesture().onEnded { s in
                        let cur = sync.zoom ?? full
                        let span = cur.upperBound.timeIntervalSince(cur.lowerBound)
                        let mid = cur.lowerBound.addingTimeInterval(span / 2)
                        let half = span / 2 / Double(max(0.2, s))
                        let lo = max(full.lowerBound, mid.addingTimeInterval(-half))
                        let hi = min(full.upperBound, mid.addingTimeInterval(half))
                        let fullSpan = full.upperBound.timeIntervalSince(full.lowerBound)
                        sync.zoom = (hi > lo && hi.timeIntervalSince(lo) < fullSpan * 0.98) ? lo...hi : nil
                    }
                )
        } else {
            content
        }
    }
}

// MARK: Полноэкранная панель

struct PanelFullScreen<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss
    @StateObject private var sync = ChartSync()

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline)
                        if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
                    }
                }
                ScrollView {
                    content()
                        .environment(\.fsHeight, geo.size.height - 70)
                        .padding(.bottom, 20)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
        }
        .background(Color(white: 0.07).ignoresSafeArea())
        .environmentObject(sync)
        .preferredColorScheme(.dark)
    }
}

// MARK: Спарклайн для строк таблиц

struct Sparkline: View {
    let points: [Pt]
    let color: Color

    var body: some View {
        let v = points.map { $0.v }
        let lo = v.min() ?? 0, hi = v.max() ?? 1
        let pad = max((hi - lo) * 0.15, 0.001)
        Chart(points) { p in
            AreaMark(x: .value("t", p.t), yStart: .value("lo", lo - pad), yEnd: .value("v", p.v))
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("t", p.t), y: .value("v", p.v))
                .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.3)).interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .chartYScale(domain: (lo - pad)...(hi + pad))
    }
}

// MARK: Сейчас против прошлой недели + полоса нормы

struct WeekComparePanel: View {
    let series: [Series]

    private struct P: Identifiable {
        let id: Int; let t: Date; let now: Double?; let week: Double?; let mean: Double?; let lo: Double?; let hi: Double?
        var over: Bool { if let n = now, let h = hi { return n > h }; return false }
    }

    private func compute() -> [P] {
        let all = series.flatMap { $0.points }
        guard let tMax = all.map({ $0.t }).max() else { return [] }
        let slot: TimeInterval = 1800, slots = 384
        let t0 = tMax.addingTimeInterval(-Double(slots) * slot)
        var sum = [Double](repeating: 0, count: slots), cnt = [Int](repeating: 0, count: slots)
        for p in all {
            let i = Int(p.t.timeIntervalSince(t0) / slot)
            if i >= 0 && i < slots { sum[i] += p.v; cnt[i] += 1 }
        }
        let avg: [Double?] = (0..<slots).map { cnt[$0] == 0 ? nil : sum[$0] / Double(cnt[$0]) }
        return (0..<48).map { j in
            let idx = 336 + j
            let hist = (1...7).compactMap { avg[idx - 48 * $0] }
            var mean: Double?, lo: Double?, hi: Double?
            if hist.count >= 3 {
                let m = hist.reduce(0, +) / Double(hist.count)
                let sd = (hist.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(hist.count)).squareRoot()
                mean = m; lo = max(0, m - 1.5 * sd - 2); hi = min(100, m + 1.5 * sd + 2)
            }
            return P(id: j, t: t0.addingTimeInterval((Double(idx) + 0.5) * slot), now: avg[idx], week: avg[idx - 336],
                     mean: mean, lo: lo, hi: hi)
        }
    }

    var body: some View {
        let pts = compute()
        if pts.contains(where: { $0.now != nil }) {
            let accent = Color(hex: "5794F2")
            let over = pts.filter { $0.over }.count
            let last = pts.last(where: { $0.now != nil })
            PanelCard(title: "CPU: сейчас и неделю назад", subtitle: "24 часа · норма по 7 дням") {
                Chart {
                    ForEach(pts) { p in
                        if let lo = p.lo, let hi = p.hi {
                            AreaMark(x: .value("t", p.t), yStart: .value("lo", lo), yEnd: .value("hi", hi), series: .value("s", "band"))
                                .foregroundStyle(accent.opacity(0.16)).interpolationMethod(.monotone)
                        }
                        if let w = p.week {
                            LineMark(x: .value("t", p.t), y: .value("v", w), series: .value("s", "week"))
                                .foregroundStyle(Color.gray.opacity(0.8)).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                                .interpolationMethod(.monotone)
                        }
                        if let n = p.now {
                            LineMark(x: .value("t", p.t), y: .value("v", n), series: .value("s", "now"))
                                .foregroundStyle(accent).lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round))
                                .interpolationMethod(.monotone)
                        }
                    }
                    ForEach(pts.filter { $0.over }) { p in
                        PointMark(x: .value("t", p.t), y: .value("v", p.now ?? 0)).foregroundStyle(Level.bad.color).symbolSize(45)
                    }
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { v in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.white.opacity(0.12))
                        AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))%").font(.caption2) } }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.white.opacity(0.12))
                        AxisValueLabel(format: .dateTime.hour().minute().locale(Locale(identifier: "ru_RU")))
                    }
                }
                .chartH(170)
                HStack {
                    stat("сейчас", last?.now.map { String(format: "%.0f%%", $0) } ?? "—", accent)
                    Spacer()
                    stat("неделю назад", last?.week.map { String(format: "%.0f%%", $0) } ?? "—", .secondary)
                    Spacer()
                    stat("выше нормы", "\(over) из 48", over == 0 ? Level.ok.color : Level.bad.color)
                }
                HStack(spacing: 12) {
                    legendDot(accent, "сейчас"); legendDot(.gray, "7 дней назад"); legendDot(accent.opacity(0.3), "норма")
                }
            }
        }
    }

    private func stat(_ t: String, _ v: String, _ c: Color) -> some View {
        VStack(spacing: 1) {
            Text(v).font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(c)
            Text(t).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func legendDot(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { Circle().fill(c).frame(width: 7, height: 7); Text(t).font(.caption2).foregroundStyle(.secondary) }
    }
}

// MARK: Прогноз заполнения дисков

struct DiskForecastPanel: View {
    let disks: [DiskFC]
    let series: [String: Series]

    private struct Line: Identifiable {
        let id: String; let title: String; let color: Color
        let hist: [Pt]; let end: (t: Date, v: Double)?; let last: Pt
    }

    private func lines() -> [Line] {
        disks.enumerated().compactMap { i, d in
            guard let s = series[d.id], s.points.count > 3, let last = s.points.last, let first = s.points.first else { return nil }
            let xs = s.points.map { $0.t.timeIntervalSince(first.t) / 86400 }
            let ys = s.points.map { $0.v }
            let n = Double(xs.count)
            let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
            let vr = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
            let slope = vr > 0 ? zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / vr : 0
            var end: (Date, Double)?
            if slope > 0.05, last.v < 100 {
                let days = min(60, (100 - last.v) / slope)
                end = (last.t.addingTimeInterval(days * 86400), min(100, last.v + slope * days))
            }
            return Line(id: d.id, title: "\(d.host) · \(d.disk)", color: seriesPalette[i % seriesPalette.count],
                        hist: s.points, end: end.map { (t: $0.0, v: $0.1) }, last: last)
        }
    }

    var body: some View {
        let ls = lines()
        if !ls.isEmpty {
            let low = max(0, (ls.map { $0.hist.map { $0.v }.min() ?? 50 }.min() ?? 50) - 8)
            PanelCard(title: "Прогноз заполнения дисков", subtitle: "тренд 7 дней · пунктир — прогноз") {
                Chart {
                    RuleMark(y: .value("100%", 100)).foregroundStyle(Level.bad.color.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    ForEach(ls) { l in
                        ForEach(l.hist) { p in
                            LineMark(x: .value("t", p.t), y: .value("v", p.v), series: .value("s", l.id))
                                .foregroundStyle(l.color).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.monotone)
                        }
                        if let e = l.end {
                            LineMark(x: .value("t", l.last.t), y: .value("v", l.last.v), series: .value("s", l.id + "f"))
                                .foregroundStyle(l.color.opacity(0.9)).lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
                            LineMark(x: .value("t", e.t), y: .value("v", e.v), series: .value("s", l.id + "f"))
                                .foregroundStyle(l.color.opacity(0.9)).lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
                            PointMark(x: .value("t", e.t), y: .value("v", e.v)).foregroundStyle(l.color).symbolSize(70)
                                .annotation(position: .top, spacing: 2) {
                                    Text(e.t, format: .dateTime.day().month(.twoDigits).locale(Locale(identifier: "ru_RU")))
                                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(l.color).fixedSize()
                                }
                        }
                    }
                }
                .chartYScale(domain: low...106)
                .chartYAxis {
                    AxisMarks(position: .leading) { v in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.white.opacity(0.12))
                        AxisValueLabel { if let d = v.as(Double.self), d <= 100 { Text("\(Int(d))%").font(.caption2) } }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.white.opacity(0.12))
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated).locale(Locale(identifier: "ru_RU")))
                    }
                }
                .chartH(200)
                ForEach(ls) { l in
                    HStack {
                        Circle().fill(l.color).frame(width: 8, height: 8)
                        Text(l.title).font(.caption).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.0f%%", l.last.v)).font(.caption.weight(.bold).monospacedDigit())
                        if let e = l.end {
                            Text("до 100% ~ \(max(1, Int(e.t.timeIntervalSince(l.last.t) / 86400))) дн.")
                                .font(.caption).foregroundStyle(Level.warn.color)
                        } else {
                            Text("растёт медленно").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

// MARK: Node graph: топология филиалов

private struct NodeDot: View {
    let label: String
    let text: String
    let color: Color
    let pulse: Bool
    let host: String
    @Environment(\.drillDown) private var drill
    @State private var on = false

    var body: some View {
        VStack(spacing: 1) {
            ZStack {
                if pulse {
                    Circle().stroke(color.opacity(0.7), lineWidth: 2).scaleEffect(on ? 1.8 : 1).opacity(on ? 0 : 0.9)
                }
                Circle().fill(color.opacity(0.28))
                Circle().stroke(color, lineWidth: 2)
                Text(text).font(.system(size: 9, weight: .bold)).foregroundStyle(.white).minimumScaleFactor(0.6)
            }
            .frame(width: 32, height: 32)
            Text(label).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1).frame(width: 60)
        }
        .contentShape(Rectangle())
        .onTapGesture { drill?(host) }
        .onAppear {
            if pulse { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on = true } }
        }
    }
}

struct NodeGraphPanel: View {
    let rows: [HostRow]
    let branches: [Branch]

    private struct N: Identifiable {
        let id: String; let host: String; let label: String; let level: Level; let rtt: Double?; let down: Bool
    }

    private func city(_ name: String) -> String {
        branches.first { $0.host == name }?.city ?? (name.components(separatedBy: " - ").last ?? name)
    }

    var body: some View {
        let all: [N] = rows.map { r in
            N(id: r.id, host: r.name, label: String(city(r.name).prefix(11)), level: r.level,
              rtt: r.values["rtt"], down: r.values["ping"] == 0)
        }
        if all.count > 1 {
            let centerIdx = all.firstIndex { city($0.host).contains("ЦОД") }
            let ring = all.enumerated().filter { $0.offset != centerIdx }.map { $0.element }
            PanelCard(title: "Топология сети", subtitle: "node graph · цвет — состояние") {
                GeometryReader { g in
                    let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
                    let R = min(g.size.width, g.size.height) / 2 - 36
                    ZStack {
                        ForEach(Array(ring.enumerated()), id: \.element.id) { i, n in
                            let p = point(i, ring.count, c, R)
                            Path { $0.move(to: c); $0.addLine(to: p) }
                                .stroke(color(n).opacity(n.level == .bad ? 0.9 : 0.55),
                                        style: StrokeStyle(lineWidth: n.level == .bad ? 2 : 1.6, dash: n.down ? [4, 4] : []))
                        }
                        centerNode(centerIdx.map { all[$0] }).position(c)
                        ForEach(Array(ring.enumerated()), id: \.element.id) { i, n in
                            NodeDot(label: n.label, text: nodeText(n), color: color(n), pulse: n.level == .bad, host: n.host)
                                .position(point(i, ring.count, c, R))
                        }
                    }
                }
                .chartH(340)
                HStack(spacing: 12) {
                    dot(Level.ok.color, "норма"); dot(Level.warn.color, "внимание"); dot(Level.bad.color, "нет связи")
                    Spacer()
                    Text("в узле — мс").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func point(_ i: Int, _ n: Int, _ c: CGPoint, _ r: Double) -> CGPoint {
        let a = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(max(n, 1))
        return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
    }

    private func color(_ n: N) -> Color { n.level == .none ? Level.ok.color : n.level.color }

    private func nodeText(_ n: N) -> String {
        if n.down { return "✕" }
        guard let r = n.rtt else { return "·" }
        return r < 1 ? String(format: "%.0f", r * 1000) : "—"
    }

    @ViewBuilder private func centerNode(_ n: N?) -> some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().fill(Color(hex: "5794F2").opacity(0.25))
                Circle().stroke(Color(hex: "5794F2"), lineWidth: 2.5)
                Image(systemName: "server.rack").foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            Text(n.map { String(city($0.host).prefix(12)) } ?? "Сеть").font(.system(size: 9, weight: .semibold))
        }
    }

    private func dot(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { Circle().fill(c).frame(width: 7, height: 7); Text(t).font(.caption2).foregroundStyle(.secondary) }
    }
}

// MARK: Календарь проблем (90 дней)

struct CalendarHeatPanel: View {
    let events: [HistEvent]
    @State private var sel: (date: Date, n: Int)?

    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.firstWeekday = 2; c.locale = Locale(identifier: "ru_RU"); return c }

    private func dayCounts(_ cal: Calendar) -> [Date: Int] {
        var counts: [Date: Int] = [:]
        for e in events where e.severity >= 3 { counts[cal.startOfDay(for: e.start), default: 0] += 1 }
        return counts
    }

    var body: some View {
        let cal = self.cal
        let today = cal.startOfDay(for: Date())
        let wd = (cal.component(.weekday, from: today) + 5) % 7
        let lastMonday = cal.date(byAdding: .day, value: -wd, to: today) ?? today
        let start = cal.date(byAdding: .day, value: -12 * 7, to: lastMonday) ?? today
        let counts = dayCounts(cal)
        let maxN = max(1, counts.filter { $0.key >= start }.values.max() ?? 1)
        let total = counts.filter { $0.key >= start }.values.reduce(0, +)
        PanelCard(title: "Проблемы по дням", subtitle: "90 дней · всего \(total)") {
            HStack(alignment: .top, spacing: 4) {
                VStack(spacing: 4) {
                    Text(" ").font(.system(size: 9))
                    ForEach(0..<7, id: \.self) { d in
                        Text([0, 2, 4, 6].contains(d) ? ["Пн", "", "Ср", "", "Пт", "", "Вс"][d] : " ")
                            .font(.system(size: 9)).foregroundStyle(.secondary).frame(height: 18)
                    }
                }
                ForEach(0..<13, id: \.self) { w in
                    VStack(spacing: 4) {
                        let first = cal.date(byAdding: .day, value: w * 7, to: start) ?? start
                        Text(cal.component(.day, from: first) <= 7
                             ? first.formatted(.dateTime.month(.abbreviated).locale(Locale(identifier: "ru_RU"))) : " ")
                            .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                            .frame(height: 11, alignment: .leading)
                        ForEach(0..<7, id: \.self) { d in
                            let date = cal.date(byAdding: .day, value: w * 7 + d, to: start) ?? start
                            let n = counts[date] ?? 0
                            RoundedRectangle(cornerRadius: 3)
                                .fill(date > today ? Color.clear : (n == 0 ? Color.white.opacity(0.07) : heatColor(Double(n) / Double(maxN) * 100, lo: 0, hi: 100)))
                                .frame(height: 18)
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(sel?.date == date ? Color.white : Color.clear, lineWidth: 1.5))
                                .onTapGesture { if date <= today { sel = (date, n); Haptics.tap() } }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 4) {
                if let sel {
                    Text("\(sel.date.formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "ru_RU")))): \(sel.n)")
                        .font(.caption.weight(.semibold))
                } else {
                    Text("Нажмите на день").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("меньше").font(.caption2).foregroundStyle(.secondary)
                ForEach([0.0, 25, 50, 75, 100], id: \.self) { t in
                    RoundedRectangle(cornerRadius: 2).fill(t == 0 ? Color.white.opacity(0.07) : heatColor(t, lo: 0, hi: 100)).frame(width: 12, height: 12)
                }
                Text("больше").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Box plot задержки по филиалам

struct BoxPlotPanel: View {
    let series: [Series]
    @Environment(\.drillDown) private var drill

    private struct Box: Identifiable {
        let id: String; let name: String; let mn: Double; let q1: Double; let med: Double; let q3: Double; let mx: Double
    }

    private func quant(_ s: [Double], _ p: Double) -> Double { s[min(s.count - 1, Int(Double(s.count - 1) * p))] }

    var body: some View {
        let boxes: [Box] = series.compactMap { s in
            let v = s.points.map { $0.v * 1000 }.sorted()
            guard v.count >= 5 else { return nil }
            return Box(id: s.name, name: shortName(s.name), mn: v[0], q1: quant(v, 0.25), med: quant(v, 0.5), q3: quant(v, 0.75), mx: v[v.count - 1])
        }
        .sorted { $0.med > $1.med }.prefix(12).map { $0 }
        if boxes.count > 1 {
            let full = Dictionary(boxes.map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a })
            PanelCard(title: "Разброс задержки по филиалам", subtitle: "box plot · мс") {
                Chart(boxes) { b in
                    RuleMark(xStart: .value("min", b.mn), xEnd: .value("max", b.mx), y: .value("филиал", b.name))
                        .foregroundStyle(Color.gray.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1.5))
                    BarMark(xStart: .value("q1", b.q1), xEnd: .value("q3", b.q3), y: .value("филиал", b.name), height: .fixed(13))
                        .foregroundStyle(heatColor(b.med, lo: 40, hi: 200).gradient).cornerRadius(3)
                    PointMark(x: .value("медиана", b.med), y: .value("филиал", b.name))
                        .symbol(.circle).symbolSize(34).foregroundStyle(Color.white)
                }
                .chartYScale(domain: boxes.map { $0.name })
                .chartYAxis { AxisMarks(position: .leading) { _ in AxisValueLabel(centered: true).font(.caption2) } }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.white.opacity(0.12))
                        AxisValueLabel().font(.caption2)
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(Color.clear).contentShape(Rectangle()).onTapGesture { loc in
                            let y = loc.y - geo[proxy.plotAreaFrame].origin.y
                            if let n: String = proxy.value(atY: y), let f = full[n] { drill?(f) }
                        }
                    }
                }
                .frame(height: CGFloat(boxes.count) * 26 + 30)
                HStack(spacing: 10) {
                    Text("● медиана").font(.caption2).foregroundStyle(.secondary)
                    Text("▬ 25–75%").font(.caption2).foregroundStyle(.secondary)
                    Text("— min…max").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: Шумные хосты

struct NoisyHostsPanel: View {
    let events: [HistEvent]

    private struct Bar: Identifiable { let id: String; let label: String; let sev: String; let n: Int }

    private func fmt(_ t: TimeInterval) -> String {
        t < 3600 ? "\(max(1, Int(t / 60))) мин" : String(format: "%.1f ч", t / 3600)
    }

    var body: some View {
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        let recent = events.filter { $0.start > cutoff && $0.severity >= 3 && !$0.host.isEmpty }
        let groups = Dictionary(grouping: recent, by: { $0.host }).map { ($0.key, $0.value) }
            .sorted { $0.1.count > $1.1.count }.prefix(8)
        let names: [(String, String)] = groups.map { host, evs in
            let closed = evs.compactMap { e in e.end.map { $0.timeIntervalSince(e.start) } }
            let avg = closed.isEmpty ? "" : " · ср. \(fmt(closed.reduce(0, +) / Double(closed.count)))"
            return (host, "\(shortName(host))\(avg)")
        }
        let sevNames = [3: "Средняя", 4: "Высокая", 5: "Чрезвычайная"]
        let bars: [Bar] = groups.enumerated().flatMap { i, g in
            [3, 4, 5].compactMap { s -> Bar? in
                let n = g.1.filter { $0.severity == s }.count
                return n == 0 ? nil : Bar(id: "\(i)-\(s)", label: names[i].1, sev: sevNames[s] ?? "", n: n)
            }
        }
        if !bars.isEmpty {
            PanelCard(title: "Шумные хосты", subtitle: "30 дней · число проблем и ср. длительность") {
                Chart(bars) { b in
                    BarMark(x: .value("n", b.n), y: .value("хост", b.label), height: .fixed(14))
                        .foregroundStyle(by: .value("Важность", b.sev)).cornerRadius(3)
                }
                .chartYScale(domain: names.map { $0.1 })
                .chartForegroundStyleScale(domain: ["Средняя", "Высокая", "Чрезвычайная"],
                                           range: [sevColor(3), sevColor(4), sevColor(5)])
                .chartLegend(.hidden)
                .chartYAxis { AxisMarks(position: .leading) { _ in AxisValueLabel().font(.caption2) } }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.white.opacity(0.12))
                        AxisValueLabel().font(.caption2)
                    }
                }
                .frame(height: CGFloat(groups.count) * 28 + 30)
            }
        }
    }
}

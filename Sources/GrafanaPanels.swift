import SwiftUI
import Charts

// Дополнительные панели в стиле Grafana: status history, полосы min/avg/max, stacked area,
// гистограмма, XY-диаграмма, сворачиваемые ряды (rows) и переменная «Группа».

// MARK: Помощники

/// Непрерывная шкала зелёный → жёлтый → красный (как цветовая схема Grafana «From thresholds»).
func heatColor(_ v: Double, lo: Double = 30, hi: Double = 90) -> Color {
    let t = min(1, max(0, (v - lo) / (hi - lo)))
    return Color(hue: 0.33 * (1 - t), saturation: 0.58 + 0.2 * t, brightness: 0.74 + 0.14 * t)
}

/// Средние значения по временным корзинам для каждого ряда.
private func bucketed(_ series: [Series], buckets: Int) -> (t0: Date, step: TimeInterval, rows: [(name: String, v: [Double?])])? {
    let all = series.flatMap { $0.points }
    guard let a = all.map({ $0.t }).min(), let b = all.map({ $0.t }).max(), b > a else { return nil }
    let step = b.timeIntervalSince(a) / Double(buckets)
    let rows = series.filter { !$0.points.isEmpty }.map { s -> (name: String, v: [Double?]) in
        var sum = [Double](repeating: 0, count: buckets), cnt = [Int](repeating: 0, count: buckets)
        for p in s.points {
            let i = min(buckets - 1, Int(p.t.timeIntervalSince(a) / step))
            sum[i] += p.v; cnt[i] += 1
        }
        return (s.name, (0..<buckets).map { cnt[$0] == 0 ? nil : sum[$0] / Double(cnt[$0]) })
    }
    return (a, step, rows)
}

// MARK: Сворачиваемый ряд (Grafana row)

struct DashRow<Content: View>: View {
    let title: String
    let icon: String
    @AppStorage private var open: Bool
    @ViewBuilder let content: () -> Content

    init(id: String, title: String, icon: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.icon = icon; self.content = content
        _open = AppStorage(wrappedValue: true, "row.\(id)")
    }

    var body: some View {
        VStack(spacing: 12) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { open.toggle() }; Haptics.tap() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).rotationEffect(.degrees(open ? 90 : 0))
                    Image(systemName: icon).foregroundStyle(.orange)
                    Text(title).font(.headline)
                    Spacer()
                }
                .foregroundStyle(.primary)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { content() }
        }
    }
}

// MARK: Status history: сервер × время, цвет = значение

struct StatusHistoryPanel: View {
    let series: [Series]
    @Environment(\.drillDown) private var drill
    var title = "Загрузка CPU по серверам"
    var subtitle = "status history"

    private struct Cell: Identifiable { let id: Int; let host: String; let start: Date; let end: Date; let v: Double? }

    var body: some View {
        if let b = bucketed(series, buckets: 36) {
            let rows = b.rows.sorted { ($0.v.compactMap { $0 }.max() ?? 0) > ($1.v.compactMap { $0 }.max() ?? 0) }.prefix(9)
            let names = rows.map { shortName($0.name) }
            let cells: [Cell] = rows.enumerated().flatMap { r, row in
                row.v.enumerated().map { i, v in
                    Cell(id: r * 100 + i, host: shortName(row.name),
                         start: b.t0.addingTimeInterval(Double(i) * b.step),
                         end: b.t0.addingTimeInterval(Double(i + 1) * b.step), v: v)
                }
            }
            let full = Dictionary(rows.map { (shortName($0.name), $0.name) }, uniquingKeysWith: { a, _ in a })
            PanelCard(title: title, subtitle: subtitle) {
                Chart(cells) { c in
                    BarMark(xStart: .value("с", c.start), xEnd: .value("по", c.end), y: .value("хост", c.host), height: .fixed(17))
                        .foregroundStyle(c.v.map { heatColor($0) } ?? Color.gray.opacity(0.15))
                }
                .chartYScale(domain: names)
                .chartYAxis { AxisMarks(position: .leading) { _ in AxisValueLabel(centered: true).font(.caption2) } }
                .chartPlotStyle { $0.padding(.leading, 62) }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisValueLabel(format: .dateTime.hour().minute().locale(Locale(identifier: "ru_RU")))
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
                .frame(height: CGFloat(names.count) * 22 + 26)
                HStack(spacing: 6) {
                    Text("30%").font(.caption2).foregroundStyle(.secondary)
                    LinearGradient(colors: stride(from: 30.0, through: 90.0, by: 10).map { heatColor($0) },
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(height: 8).clipShape(Capsule())
                    Text("90%").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: Полоса min / среднее / max по серверам

struct BandPanel: View {
    let series: [Series]
    var title = "Разброс CPU по серверам"
    var height: CGFloat = 170

    private struct P: Identifiable { let id: Int; let t: Date; let lo: Double; let avg: Double; let hi: Double }

    var body: some View {
        if let b = bucketed(series, buckets: 40) {
            let pts: [P] = (0..<40).compactMap { i in
                let v = b.rows.compactMap { $0.v[i] }
                guard let lo = v.min(), let hi = v.max() else { return nil }
                return P(id: i, t: b.t0.addingTimeInterval((Double(i) + 0.5) * b.step), lo: lo, avg: v.reduce(0, +) / Double(v.count), hi: hi)
            }
            let accent = Color(hex: "5794F2")
            PanelCard(title: title, subtitle: "min · среднее · max") {
                Chart {
                    ForEach(pts) { p in
                        AreaMark(x: .value("t", p.t), yStart: .value("min", p.lo), yEnd: .value("max", p.hi), series: .value("s", "band"))
                            .foregroundStyle(LinearGradient(colors: [accent.opacity(0.38), accent.opacity(0.12)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("t", p.t), y: .value("v", p.hi), series: .value("s", "max"))
                            .foregroundStyle(Level.warn.color.opacity(0.9)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("t", p.t), y: .value("v", p.avg), series: .value("s", "avg"))
                            .foregroundStyle(accent).lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("t", p.t), y: .value("v", p.lo), series: .value("s", "min"))
                            .foregroundStyle(Level.ok.color.opacity(0.9)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .interpolationMethod(.monotone)
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
                .chartH(height)
                HStack(spacing: 14) {
                    dot(Level.warn.color, "максимум"); dot(accent, "среднее"); dot(Level.ok.color, "минимум")
                }
            }
        }
    }

    private func dot(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { Circle().fill(c).frame(width: 7, height: 7); Text(t).font(.caption2).foregroundStyle(.secondary) }
    }
}

// MARK: Stacked area: открытые проблемы во времени

struct StackedProblemsPanel: View {
    let events: [HistEvent]
    var days = 7

    private struct P: Identifiable { let id: Int; let t: Date; let sev: String; let n: Int }

    var body: some View {
        let now = Date()
        let step: TimeInterval = 3 * 3600
        let count = days * 8
        let sevs: [(Int, String, Color)] = [(3, "Средняя", sevColor(3)), (4, "Высокая", sevColor(4)), (5, "Чрезвычайная", sevColor(5))]
        let pts: [P] = (0...count).flatMap { i -> [P] in
            let t = now.addingTimeInterval(-Double(count - i) * step)
            return sevs.map { s in
                P(id: i * 10 + s.0, t: t, sev: s.1,
                  n: events.filter { $0.severity == s.0 && $0.start <= t && ($0.end ?? now) > t }.count)
            }
        }
        let peak = Dictionary(grouping: pts, by: { $0.t }).values.map { $0.reduce(0) { $0 + $1.n } }.max() ?? 0
        PanelCard(title: "Открытые проблемы во времени", subtitle: "\(days) дней · пик \(peak)") {
            Chart(pts) { p in
                AreaMark(x: .value("t", p.t), y: .value("n", p.n))
                    .foregroundStyle(by: .value("Важность", p.sev))
                    .interpolationMethod(.stepEnd)
            }
            .chartForegroundStyleScale(domain: sevs.map { $0.1 }, range: sevs.map { $0.2.opacity(0.85) })
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.white.opacity(0.12))
                    AxisValueLabel().font(.caption2)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.white.opacity(0.12))
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated).locale(Locale(identifier: "ru_RU")))
                }
            }
            .chartH(160)
            HStack(spacing: 14) {
                ForEach(sevs.reversed(), id: \.0) { s in
                    HStack(spacing: 4) { Circle().fill(s.2).frame(width: 7, height: 7); Text(s.1).font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

// MARK: Гистограмма распределения

struct HistogramPanel: View {
    let title: String
    let subtitle: String
    let values: [Double]
    var scale = 1.0
    var suffix = ""
    var bins = 12
    var fixedRange: ClosedRange<Double>?

    private struct Bin: Identifiable { let id: Int; let label: String; let n: Int }

    var body: some View {
        let v = values.map { $0 * scale }
        if v.count > 3 {
            let lo = fixedRange?.lowerBound ?? 0
            let hi = fixedRange?.upperBound ?? max((v.max() ?? 1) * 1.001, lo + 1)
            let w = (hi - lo) / Double(bins)
            let items = makeBins(v, lo: lo, width: w)
            let sorted = v.sorted()
            let med = sorted[sorted.count / 2], p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            PanelCard(title: title, subtitle: subtitle) {
                Chart(items) { b in
                    BarMark(x: .value("v", b.label), y: .value("n", b.n))
                        .foregroundStyle(heatColor(Double(b.id) / Double(bins - 1) * 100, lo: 25, hi: 85).gradient)
                        .cornerRadius(3)
                }
                .chartXAxis {
                    AxisMarks(values: items.filter { $0.id % 2 == 0 }.map { $0.label }) { _ in AxisValueLabel().font(.caption2) }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.white.opacity(0.12))
                        AxisValueLabel().font(.caption2)
                    }
                }
                .chartH(130)
                HStack {
                    stat("медиана", String(format: "%.0f%@", med, suffix))
                    Spacer()
                    stat("p95", String(format: "%.0f%@", p95, suffix))
                    Spacer()
                    stat("максимум", String(format: "%.0f%@", sorted.last ?? 0, suffix))
                    Spacer()
                    stat("замеров", "\(v.count)")
                }
            }
        }
    }

    private func makeBins(_ v: [Double], lo: Double, width w: Double) -> [Bin] {
        var counts = [Int](repeating: 0, count: bins)
        for x in v { counts[min(bins - 1, max(0, Int((x - lo) / w)))] += 1 }
        return counts.enumerated().map { Bin(id: $0.offset, label: String(format: "%.0f", lo + Double($0.offset) * w), n: $0.element) }
    }

    private func stat(_ t: String, _ v: String) -> some View {
        VStack(spacing: 1) {
            Text(v).font(.subheadline.weight(.bold).monospacedDigit())
            Text(t).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: XY: CPU против памяти

struct XYPanel: View {
    let cpu: [Series]
    let mem: [Series]
    @Environment(\.drillDown) private var drill

    private struct P: Identifiable { let id: String; let name: String; let x: Double; let y: Double }

    var body: some View {
        let memLast = Dictionary(mem.compactMap { s in s.points.last.map { (s.name, $0.v) } }, uniquingKeysWith: { a, _ in a })
        let pts: [P] = cpu.compactMap { s in
            guard let x = s.points.last?.v, let y = memLast[s.name] else { return nil }
            return P(id: s.name, name: shortName(s.name), x: x, y: y)
        }
        if pts.count > 1 {
            PanelCard(title: "CPU и память по серверам", subtitle: "XY chart") {
                Chart {
                    RectangleMark(xStart: .value("x0", 80), xEnd: .value("x1", 100), yStart: .value("y0", 85), yEnd: .value("y1", 100))
                        .foregroundStyle(Level.bad.color.opacity(0.14))
                    RuleMark(x: .value("порог", 80)).foregroundStyle(Level.warn.color.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    RuleMark(y: .value("порог", 85)).foregroundStyle(Level.warn.color.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    ForEach(pts) { p in
                        PointMark(x: .value("CPU", p.x), y: .value("RAM", p.y))
                            .symbolSize(150)
                            .foregroundStyle(heatColor(max(p.x, p.y), lo: 50, hi: 95).opacity(0.9))
                            .annotation(position: .top, spacing: 2) {
                                Text(p.name).font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                            }
                    }
                }
                .chartXScale(domain: 0...100)
                .chartYScale(domain: 0...100)
                .chartXAxis {
                    AxisMarks(values: [0, 25, 50, 75, 100]) { v in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.white.opacity(0.1))
                        AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))%").font(.caption2) } }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { v in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.white.opacity(0.1))
                        AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))%").font(.caption2) } }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(Color.clear).contentShape(Rectangle()).onTapGesture { loc in
                            let o = geo[proxy.plotAreaFrame].origin
                            guard let x: Double = proxy.value(atX: loc.x - o.x), let y: Double = proxy.value(atY: loc.y - o.y),
                                  let best = pts.min(by: { hypot($0.x - x, $0.y - y) < hypot($1.x - x, $1.y - y) }),
                                  hypot(best.x - x, best.y - y) < 9 else { return }
                            drill?(best.id)
                        }
                    }
                }
                .chartH(250)
                HStack {
                    Text("по горизонтали — CPU, по вертикали — память").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }
}

import SwiftUI
import WidgetKit
import AppIntents
import Charts

// Виджет «Графики»: избранные метрики и средние с «Обзора». Листается кнопками ‹ › (iOS 17).
// Данные кладёт приложение в общую папку (SharedGroup.saveCharts).

/// Кнопка «‹ / ›» в виджете: меняет номер страницы, WidgetKit сам перерисовывает виджет.
struct WidgetPageIntent: AppIntent {
    static var title: LocalizedStringResource = "Листать виджет"
    static var isDiscoverable = false

    @Parameter(title: "Виджет") var key: String
    @Parameter(title: "Шаг") var delta: Int

    init() {}
    init(key: String, delta: Int) { self.key = key; self.delta = delta }

    func perform() async throws -> some IntentResult {
        SharedGroup.setPage(key, SharedGroup.page(key) + delta)
        return .result()
    }
}

/// Стрелки и точки страниц.
struct PagerBar: View {
    let key: String
    let page: Int
    let count: Int

    var body: some View {
        if count > 1 {
            HStack(spacing: 6) {
                Button(intent: WidgetPageIntent(key: key, delta: -1)) {
                    Image(systemName: "chevron.left").font(.caption.weight(.bold)).frame(width: 26, height: 22)
                }
                .buttonStyle(.plain)
                HStack(spacing: 3) {
                    ForEach(0..<min(count, 8), id: \.self) { i in
                        Circle().fill(i == page ? Color.primary : Color.secondary.opacity(0.35)).frame(width: 5, height: 5)
                    }
                }
                Button(intent: WidgetPageIntent(key: key, delta: 1)) {
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).frame(width: 26, height: 22)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.orange)
        }
    }
}

/// Номер страницы по кругу (в обе стороны).
func wrapPage(_ raw: Int, _ count: Int) -> Int {
    guard count > 0 else { return 0 }
    return ((raw % count) + count) % count
}

struct ChartsEntry: TimelineEntry {
    let date: Date
    let charts: [WidgetChart]
    let page: Int
}

struct ChartsProvider: TimelineProvider {
    func placeholder(in context: Context) -> ChartsEntry { ChartsEntry(date: .now, charts: Self.sample, page: 0) }
    func getSnapshot(in context: Context, completion: @escaping (ChartsEntry) -> Void) {
        let c = SharedGroup.loadCharts()
        completion(ChartsEntry(date: .now, charts: c.isEmpty ? Self.sample : c, page: SharedGroup.page("charts")))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ChartsEntry>) -> Void) {
        let e = ChartsEntry(date: .now, charts: SharedGroup.loadCharts(), page: SharedGroup.page("charts"))
        completion(Timeline(entries: [e], policy: .after(Date().addingTimeInterval(15 * 60))))
    }

    static let sample: [WidgetChart] = {
        let now = Date()
        let pts = (0..<36).map { i in WidgetPoint(t: now.addingTimeInterval(Double(i - 36) * 600), v: 45 + 20 * sin(Double(i) / 5)) }
        return [WidgetChart(id: "s", title: "CPU серверов", subtitle: "среднее", value: "45%", level: 0, points: pts, updated: now)]
    }()
}

private func levelColor(_ l: Int) -> Color { l >= 2 ? Color(red: 0.88, green: 0.18, blue: 0.27) : (l == 1 ? .orange : .green) }

struct ChartCell: View {
    let c: WidgetChart
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(c.title).font(.caption.weight(.semibold)).lineLimit(1)
                    if !c.subtitle.isEmpty { Text(c.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 4)
                Text(c.value).font((compact ? Font.subheadline : Font.title3).weight(.bold).monospacedDigit())
                    .foregroundStyle(levelColor(c.level)).lineLimit(1).minimumScaleFactor(0.6)
            }
            Chart(c.points, id: \.t) { p in
                AreaMark(x: .value("t", p.t), y: .value("v", p.v))
                    .foregroundStyle(LinearGradient(colors: [levelColor(c.level).opacity(0.35), levelColor(c.level).opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", p.t), y: .value("v", p.v))
                    .foregroundStyle(levelColor(c.level))
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .interpolationMethod(.monotone)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisValueLabel(format: .dateTime.hour().minute()).font(.system(size: 8))
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                    AxisValueLabel().font(.system(size: 8))
                }
            }
        }
    }
}

struct ChartsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ChartsEntry

    var body: some View {
        let per = family == .systemLarge ? 3 : 1
        let pages = max(1, Int((Double(entry.charts.count) / Double(per)).rounded(.up)))
        let page = wrapPage(entry.page, pages)
        let shown = Array(entry.charts.dropFirst(page * per).prefix(per))
        if entry.charts.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "chart.xyaxis.line").font(.title3)
                Text("Откройте приложение: графики появятся после загрузки «Обзора». Свои метрики — «Избранные метрики» на «Обзоре».")
                    .font(.caption).multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(shown) { c in
                    ChartCell(c: c, compact: family == .systemSmall).frame(maxHeight: .infinity)
                }
                HStack {
                    Text("обновлено " + (entry.charts.map(\.updated).max() ?? .now).formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    Spacer()
                    PagerBar(key: "charts", page: page, count: pages)
                }
            }
            .widgetURL(URL(string: "grafanaapp://tab/0"))
        }
    }
}

struct ChartsHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.personal.grafana.charts", provider: ChartsProvider()) { e in
            ChartsWidgetView(entry: e).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Графики")
        .description("Избранные метрики и средние CPU, RAM, задержка, доступность. Листается кнопками ‹ ›.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

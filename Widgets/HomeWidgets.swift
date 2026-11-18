import SwiftUI
import WidgetKit

#if APPGROUP

// Виджеты на экран «Домой» и экран блокировки. Данные кладёт приложение (SharedGroup),
// сам виджет в сеть не ходит: обновляется, когда приложение загрузило проблемы.

struct SnapEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot?
}

struct SnapProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapEntry { SnapEntry(date: .now, snap: Self.sample) }
    func getSnapshot(in context: Context, completion: @escaping (SnapEntry) -> Void) {
        completion(SnapEntry(date: .now, snap: SharedGroup.load() ?? Self.sample))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapEntry>) -> Void) {
        let e = SnapEntry(date: .now, snap: SharedGroup.load())
        completion(Timeline(entries: [e], policy: .after(Date().addingTimeInterval(15 * 60))))
    }

    static let sample = WidgetSnapshot(count: 4, high: 1, unacked: 2, top: [
        WidgetProblem(id: "1", name: "Нет ответа на ICMP ping", host: "Филиал 3", severity: 4, clock: .now.addingTimeInterval(-1800), acked: false),
        WidgetProblem(id: "2", name: "Мало места на диске C:", host: "FS01", severity: 3, clock: .now.addingTimeInterval(-7200), acked: true),
        WidgetProblem(id: "3", name: "Очередь почты больше 100", host: "MBX01", severity: 3, clock: .now.addingTimeInterval(-600), acked: false)
    ], updated: .now, offline: false)
}

private func wColor(_ s: Int) -> Color {
    switch s {
    case 5...: return Color(red: 0.88, green: 0.18, blue: 0.27)
    case 4: return Color(red: 1, green: 0.45, blue: 0.2)
    case 3: return .orange
    case 1...2: return .yellow
    default: return .green
    }
}

private func ago(_ d: Date) -> String {
    let m = Int(Date().timeIntervalSince(d) / 60)
    if m < 60 { return "\(max(m, 0)) мин" }
    if m < 1440 { return "\(m / 60) ч" }
    return "\(m / 1440) д"
}

struct ProblemsHomeView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapEntry

    var body: some View {
        if let s = entry.snap {
            content(s).widgetURL(URL(string: "grafanaapp://problems"))
        } else {
            VStack(spacing: 6) {
                Image(systemName: "arrow.clockwise.circle").font(.title2)
                Text("Откройте приложение, чтобы виджет получил данные").font(.caption).multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
        }
    }

    private func stale(_ s: WidgetSnapshot) -> Bool { Date().timeIntervalSince(s.updated) > 3600 }

    @ViewBuilder private func content(_ s: WidgetSnapshot) -> some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: Double(min(s.count, 20)), in: 0...20) {
                Image(systemName: "exclamationmark.triangle")
            } currentValueLabel: { Text("\(s.count)") }
            .gaugeStyle(.accessoryCircular)
        case .accessoryInline:
            Text(s.count == 0 ? "Проблем нет" : "Проблем: \(s.count), высоких: \(s.high)")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("Проблем: \(s.count)").font(.headline)
                if let w = s.top.first { Text(w.name).font(.caption).lineLimit(2) } else { Text("Всё спокойно").font(.caption) }
            }
        case .systemSmall:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(s.count)").font(.system(size: 40, weight: .bold).monospacedDigit())
                        .foregroundStyle(s.count == 0 ? .green : wColor(s.top.map(\.severity).max() ?? 3))
                    Spacer()
                    Image(systemName: s.count == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(s.count == 0 ? .green : wColor(s.top.map(\.severity).max() ?? 3))
                }
                Text(s.count == 0 ? "Проблем нет" : "высоких \(s.high) · неподтв. \(s.unacked)").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let w = s.top.first { Text(w.name).font(.caption).lineLimit(2) }
                footer(s)
            }
        default:
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Проблем: \(s.count)").font(.headline)
                    Text("высоких \(s.high) · неподтв. \(s.unacked)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                if s.top.isEmpty {
                    Spacer()
                    Label("Всё спокойно", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    Spacer()
                } else {
                    ForEach(s.top.prefix(family == .systemLarge ? 8 : 3)) { p in
                        Link(destination: URL(string: "grafanaapp://problem/\(p.id)")!) {
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2).fill(wColor(p.severity)).frame(width: 4, height: 26)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(p.name).font(.caption.weight(.semibold)).lineLimit(1)
                                    Text(p.host).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                if !p.acked { Circle().fill(Color.blue).frame(width: 6, height: 6) }
                                Text(ago(p.clock)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                footer(s)
            }
        }
    }

    private func footer(_ s: WidgetSnapshot) -> some View {
        Text((s.offline ? "нет связи · " : "") + "обновлено " + s.updated.formatted(date: .omitted, time: .shortened))
            .font(.system(size: 10)).foregroundStyle(stale(s) || s.offline ? .orange : .secondary)
    }
}

struct ProblemsHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.personal.grafana.home", provider: SnapProvider()) { e in
            ProblemsHomeView(entry: e).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Проблемы Zabbix")
        .description("Число проблем и самые свежие. Обновляется, когда приложение получает данные.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

#endif

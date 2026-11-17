import SwiftUI

// v2.6: тепловая карта «день × час», пороги по хостам, здоровье приложения,
// комментарий и светлая тема отчёта.

// MARK: Здоровье приложения

@MainActor
final class AppHealth: ObservableObject {
    static let shared = AppHealth()

    struct Fail: Identifiable {
        let id = UUID()
        let date: Date
        let text: String
    }

    @Published var lastOK: Date?
    @Published var lastMs: Int?
    @Published var fails: [Fail] = []

    init() {
        if Launch.demo {
            lastOK = Date().addingTimeInterval(-40)
            lastMs = 182
            fails = [Fail(date: Date().addingTimeInterval(-900), text: "Zabbix отказал: timeout"),
                     Fail(date: Date().addingTimeInterval(-7200), text: "Ошибка сервера (HTTP 502)")]
        }
    }

    func ok(ms: Int) { lastOK = Date(); lastMs = ms }

    func fail(_ text: String) {
        fails.insert(Fail(date: Date(), text: text), at: 0)
        if fails.count > 50 { fails.removeLast(fails.count - 50) }
    }

    var failsLastHour: Int { fails.filter { Date().timeIntervalSince($0.date) < 3600 }.count }
}

struct HealthView: View {
    @ObservedObject private var h = AppHealth.shared

    private var state: (text: String, color: Color) {
        guard let ok = h.lastOK else { return ("Ответов от сервера ещё не было", Level.none.color) }
        if Date().timeIntervalSince(ok) > 600 { return ("Связи нет больше 10 минут", Level.bad.color) }
        if h.failsLastHour > 5 { return ("Много ошибок за час", Level.warn.color) }
        return ("Всё работает", Level.ok.color)
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Circle().fill(state.color).frame(width: 12, height: 12)
                    Text(state.text).font(.headline)
                }
                LabeledContent("Последний успешный ответ") {
                    Text(h.lastOK.map { $0.formatted(date: .omitted, time: .standard) } ?? "—").monospacedDigit()
                }
                LabeledContent("Задержка последнего ответа") {
                    Text(h.lastMs.map { "\($0) мс" } ?? "—").monospacedDigit()
                }
                LabeledContent("Ошибок за час", value: "\(h.failsLastHour)")
                LabeledContent("Ошибок за сессию", value: "\(h.fails.count)")
            } footer: {
                Text("Считается по всем запросам к Grafana и Zabbix с этого телефона. Список ошибок хранится до перезапуска приложения.")
            }
            if !h.fails.isEmpty {
                Section("Последние ошибки") {
                    ForEach(h.fails.prefix(20)) { f in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.text).font(.subheadline)
                            Text(f.date.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Здоровье приложения")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: Пороги по хосту

@MainActor
final class HostThrStore: ObservableObject {
    static let shared = HostThrStore()
    @Published var map: [String: [String: Double]] { didSet { save() } }

    init() {
        if let d = UserDefaults.standard.data(forKey: "hostThr"),
           let v = try? JSONDecoder().decode([String: [String: Double]].self, from: d) {
            map = v
        } else if Launch.demo {
            map = ["HYPER3": ["memWarn": 80, "memBad": 90], "DC2": ["cpuWarn": 60, "cpuBad": 75]]
        } else {
            map = [:]
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(map) { UserDefaults.standard.set(d, forKey: "hostThr") }
    }

    /// metric: "cpu", "mem" или "disk". Для хоста без своих значений действуют общие пороги.
    func thresholds(_ host: String, _ metric: String) -> (warn: Double, bad: Double) {
        let (dw, db): (Double, Double) = metric == "cpu" ? (Thr.cpuWarn, Thr.cpuBad)
            : (metric == "mem" ? (Thr.memWarn, Thr.memBad) : (Thr.diskWarn, Thr.diskBad))
        let o = map[host] ?? [:]
        return (o[metric + "Warn"] ?? dw, o[metric + "Bad"] ?? db)
    }

    func color(_ host: String, _ metric: String, _ v: Double) -> Color {
        let t = thresholds(host, metric)
        return Thr.color(v, warn: t.warn, bad: t.bad)
    }
}

struct HostThresholdsView: View {
    @ObservedObject private var store = HostThrStore.shared
    @State private var adding = false

    private func summary(_ host: String) -> String {
        let c = store.thresholds(host, "cpu"), m = store.thresholds(host, "mem"), d = store.thresholds(host, "disk")
        return "CPU \(Int(c.warn))/\(Int(c.bad))% · RAM \(Int(m.warn))/\(Int(m.bad))% · диск \(Int(d.warn))/\(Int(d.bad))%"
    }

    var body: some View {
        List {
            if store.map.isEmpty {
                Text("Отдельных порогов нет: для всех хостов действуют общие пороги из «Свои пороги». Нажмите «+», чтобы задать свои для одного хоста.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(store.map.keys.sorted(), id: \.self) { h in
                NavigationLink { HostThrDetail(host: h) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(h).lineLimit(1)
                        Text(summary(h)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
            }
            .onDelete { idx in
                let keys = store.map.keys.sorted()
                for i in idx { store.map[keys[i]] = nil }
            }
        }
        .navigationTitle("Пороги по хостам")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button { adding = true } label: { Image(systemName: "plus") } }
        }
        .sheet(isPresented: $adding) {
            HostPicker(chosen: []) { h in
                if store.map[h.name] == nil { store.map[h.name] = [:] }
            }
        }
    }
}

struct HostThrDetail: View {
    let host: String
    @ObservedObject private var store = HostThrStore.shared
    @Environment(\.dismiss) private var dismiss

    private func bind(_ key: String, _ def: Double) -> Binding<Double> {
        Binding(get: { store.map[host]?[key] ?? def },
                set: { v in
                    var m = store.map[host] ?? [:]
                    m[key] = v
                    store.map[host] = m
                })
    }

    private func row(_ title: String, _ key: String, _ def: Double) -> some View {
        Stepper(value: bind(key, def), in: 1...100, step: 1) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(store.map[host]?[key] ?? def))%").foregroundStyle(.orange).monospacedDigit()
            }
        }
    }

    var body: some View {
        Form {
            Section("CPU") {
                row("Внимание", "cpuWarn", Thr.cpuWarn)
                row("Проблема", "cpuBad", Thr.cpuBad)
            }
            Section("Память") {
                row("Внимание", "memWarn", Thr.memWarn)
                row("Проблема", "memBad", Thr.memBad)
            }
            Section("Диски") {
                row("Внимание", "diskWarn", Thr.diskWarn)
                row("Проблема", "diskBad", Thr.diskBad)
            }
            Section {
                Button("Вернуть общие пороги для хоста", role: .destructive) {
                    store.map[host] = nil
                    dismiss()
                }
            } footer: { Text("Значения действуют только для этого хоста на вкладке «Панели»: цвета шкал и значений в легенде CPU.") }
        }
        .navigationTitle(host)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: Когда ломается: день недели × час

struct HourHeatPanel: View {
    let events: [HistEvent]
    @State private var sel: (day: Int, hour: Int)?

    private let rowH: CGFloat = 16
    private let gap: CGFloat = 3
    private let days = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]

    private var grid: [[Int]] {
        var g = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        let cal = Calendar.current
        for e in events where e.severity >= 3 {
            let d = (cal.component(.weekday, from: e.start) + 5) % 7   // понедельник = 0
            let h = cal.component(.hour, from: e.start)
            g[d][h] += 1
        }
        return g
    }

    private func cell(_ p: CGPoint, width: CGFloat) -> (day: Int, hour: Int) {
        let cw = width / 24
        let h = min(23, max(0, Int(p.x / cw)))
        let d = min(6, max(0, Int(p.y / (rowH + gap))))
        return (d, h)
    }

    var body: some View {
        let g = grid
        let mx = Double(max(1, g.flatMap { $0 }.max() ?? 1))
        let total = g.flatMap { $0 }.reduce(0, +)
        PanelCard(title: "Когда ломается", subtitle: "день недели × час · 90 дней") {
            HStack(alignment: .top, spacing: 4) {
                VStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { d in
                        Text(days[d]).font(.system(size: 9)).foregroundStyle(.secondary).frame(height: rowH)
                    }
                }
                .frame(width: 20)
                GeometryReader { geo in
                    Canvas { ctx, size in
                        let cw = size.width / 24
                        for d in 0..<7 {
                            for h in 0..<24 {
                                let v = Double(g[d][h])
                                let a = v == 0 ? 0.07 : 0.2 + 0.8 * (v / mx)
                                let r = CGRect(x: CGFloat(h) * cw + 0.5, y: CGFloat(d) * (rowH + gap), width: cw - 1, height: rowH)
                                ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(Level.bad.color.opacity(a)))
                            }
                        }
                        if let s = sel {
                            let r = CGRect(x: CGFloat(s.hour) * cw, y: CGFloat(s.day) * (rowH + gap) - 1, width: cw, height: rowH + 2)
                            ctx.stroke(Path(roundedRect: r, cornerRadius: 2), with: .color(.white), lineWidth: 1.2)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        sel = cell(v.location, width: geo.size.width)
                    })
                }
                .frame(height: CGFloat(7) * rowH + CGFloat(6) * gap)
            }
            HStack {
                Text("00").font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                Text("12").font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                Text("23").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .padding(.leading, 24)
            if let s = sel {
                Text("\(days[s.day]), \(String(format: "%02d", s.hour)):00–\(String(format: "%02d", (s.hour + 1) % 24)):00 — проблем: \(g[s.day][s.hour])")
                    .font(.caption.weight(.semibold)).foregroundStyle(.orange)
            } else {
                Text("Нажмите на ячейку. Всего проблем важности «средняя» и выше: \(total)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Светлая тема отчёта

private struct ReportLightKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var reportLight: Bool {
        get { self[ReportLightKey.self] }
        set { self[ReportLightKey.self] = newValue }
    }
}

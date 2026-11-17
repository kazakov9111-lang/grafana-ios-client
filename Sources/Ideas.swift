import SwiftUI
import Charts
import UIKit

// MARK: Тактильный отклик

enum Haptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}

// MARK: Заметки к хостам (хранятся на телефоне)

enum Notes {
    static func get(_ id: String) -> String { UserDefaults.standard.string(forKey: "note.\(id)") ?? "" }
    static func set(_ id: String, _ text: String) {
        if text.isEmpty { UserDefaults.standard.removeObject(forKey: "note.\(id)") }
        else { UserDefaults.standard.set(text, forKey: "note.\(id)") }
    }
}

struct HostNoteSection: View {
    let hostId: String
    @State private var text = ""

    var body: some View {
        Section {
            TextField("Например: ждём замену диска", text: $text, axis: .vertical).lineLimit(1...6)
                .onChange(of: text) { Notes.set(hostId, $0) }
        } header: { Text("Заметка") } footer: { Text("Хранится только на этом телефоне.") }
        .onAppear { text = Notes.get(hostId) }
    }
}

// MARK: Поделиться снимком панели

@MainActor
func sharePanel<V: View>(_ view: V) {
    let content = view.frame(width: 390).padding(12).background(Color(white: 0.07)).environment(\.colorScheme, .dark).environment(\.snapshot, true).environmentObject(ChartSync())
    let r = ImageRenderer(content: content)
    r.scale = 3
    guard let img = r.uiImage else { return }
    let vc = UIActivityViewController(activityItems: [img], applicationActivities: nil)
    var top = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow?.rootViewController
    while let p = top?.presentedViewController { top = p }
    top?.present(vc, animated: true)
    Haptics.tap()
}

// MARK: Сравнение хостов

struct CompareView: View {
    @EnvironmentObject var session: Session
    @State private var hosts: [HostMini] = {
        if Launch.screen == "compare" {
            return ["10", "11", "20"].compactMap { id in
                Demo.hosts.first { $0.id == id }.map { HostMini(id: $0.id, name: $0.name) }
            }
        }
        return []
    }()
    @State private var metric = 0
    @State private var range: TimeRange = .h6
    @State private var series: [Series] = []
    @State private var loading = false
    @State private var picking = false

    private let metrics: [(String, String, String?)] = [
        ("CPU", "CPU utilization", "percent"), ("Память", "Memory utilization", "percent"), ("Пинг", "ICMP response time", "s")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Picker("Показатель", selection: $metric) {
                    ForEach(metrics.indices, id: \.self) { Text(metrics[$0].0).tag($0) }
                }.pickerStyle(.segmented)
                Picker("Период", selection: $range) {
                    ForEach(TimeRange.allCases) { Text($0.shortLabel).tag($0) }
                }.pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Хосты (до 5)").font(.caption).foregroundStyle(.secondary)
                    FlowChips(items: hosts.map { $0.name }) { name in
                        hosts.removeAll { $0.name == name }
                    }
                    if hosts.count < 5 {
                        Button { picking = true } label: { Label("Добавить хост", systemImage: "plus.circle.fill") }
                            .buttonStyle(.bordered).tint(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))

                PanelCard(title: metrics[metric].0, subtitle: range.label) {
                    if series.isEmpty {
                        Text(loading ? "Загрузка…" : (hosts.isEmpty ? "Добавьте хотя бы два хоста" : "Нет данных"))
                            .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        TimeSeriesChart(series: series, unit: metrics[metric].2, thresholds: [], showLegend: false).frame(height: 220)
                        ForEach(Array(series.enumerated()), id: \.element.id) { i, s in
                            HStack {
                                Circle().fill(seriesPalette[i % seriesPalette.count]).frame(width: 8, height: 8)
                                Text(s.host.isEmpty ? s.name : s.host).font(.caption).lineLimit(1)
                                Spacer()
                                SeriesStats(series: s, unit: metrics[metric].2)
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
        .background(Color(white: 0.07))
        .navigationTitle("Сравнение хостов")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $picking) { HostPicker(chosen: hosts) { hosts.append($0) } }
        .task(id: "\(metric)|\(range.rawValue)|\(hosts.map { $0.id }.joined(separator: ","))") { await load() }
    }

    private func load() async {
        guard !hosts.isEmpty else { series = []; return }
        loading = true
        defer { loading = false }
        let names = hosts.map { NSRegularExpression.escapedPattern(for: $0.name) }.joined(separator: "|")
        series = (try? await session.hostSeries(host: "/^(\(names))$/", filter: metrics[metric].1, range: range)) ?? []
    }
}

struct FlowChips: View {
    let items: [String]
    let onRemove: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { n in
                HStack {
                    Text(n).font(.subheadline).lineLimit(1)
                    Spacer()
                    Button { onRemove(n) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color(white: 0.17), in: Capsule())
            }
        }
    }
}

struct HostPicker: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let chosen: [HostMini]
    let onPick: (HostMini) -> Void
    @State private var q = Launch.demo ? "DC" : ""
    @State private var found: [HostMini] = []

    var body: some View {
        NavigationStack {
            List(found.filter { f in !chosen.contains { $0.id == f.id } }) { h in
                Button { onPick(h); dismiss() } label: { Text(h.name).foregroundStyle(.primary) }
            }
            .overlay { if found.isEmpty { Text("Введите имя хоста").foregroundStyle(.secondary) } }
            .navigationTitle("Выбор хоста")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $q, placement: .navigationBarDrawer(displayMode: .always), prompt: "Имя хоста")
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } } }
            .task(id: q) {
                guard q.trimmingCharacters(in: .whitespaces).count >= 2 else { found = []; return }
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
                found = (try? await session.searchHosts(q)) ?? []
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: Календарь бэкапов Veeam

struct VeeamCalendarView: View {
    @EnvironmentObject var session: Session
    private struct Day: Identifiable { let id: Int; let date: Date; var fail = 0.0; var warn = 0.0; var ok = 0.0; var has = false }
    @State private var rows: [(host: String, days: [Day])] = []
    @State private var loading = true

    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.locale = Locale(identifier: "ru_RU"); return c }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if rows.isEmpty {
                    Text(loading ? "Загрузка…" : "Нет данных").foregroundStyle(.secondary).padding(.top, 40)
                }
                ForEach(rows, id: \.host) { r in
                    PanelCard(title: r.host, subtitle: "7 дней") {
                        HStack(spacing: 6) {
                            ForEach(r.days) { d in
                                VStack(spacing: 4) {
                                    Text(d.date, format: .dateTime.weekday(.abbreviated).locale(Locale(identifier: "ru_RU")))
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 6).fill(color(d).opacity(d.has ? 0.9 : 0.25))
                                        Text(d.has ? "\(Int(d.fail > 0 ? d.fail : (d.warn > 0 ? d.warn : d.ok)))" : "–")
                                            .font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.white)
                                    }
                                    .frame(height: 40)
                                    Text(d.date, format: .dateTime.day()).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                HStack(spacing: 14) {
                    dot(Level.ok.color, "успешно"); dot(Level.warn.color, "предупреждение"); dot(Level.bad.color, "ошибка")
                }
                .font(.caption2).foregroundStyle(.secondary)
                Text("По дням: число ошибок, предупреждений или успешных заданий — берётся худший результат дня.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(12)
        }
        .background(Color(white: 0.07))
        .navigationTitle("Календарь бэкапов")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func dot(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { Circle().fill(c).frame(width: 8, height: 8); Text(t) }
    }

    private func color(_ d: Day) -> Color {
        d.fail > 0 ? Level.bad.color : (d.warn > 0 ? Level.warn.color : (d.ok > 0 ? Level.ok.color : Color.gray))
    }

    private func load() async {
        loading = true
        defer { loading = false }
        async let f = session.hostSeries(host: "/.*/", filter: "Veeam: Backups finished with Failed (24h)", range: .d7, group: "Veeam")
        async let w = session.hostSeries(host: "/.*/", filter: "Veeam: Backups finished with Warning (24h)", range: .d7, group: "Veeam")
        async let s = session.hostSeries(host: "/.*/", filter: "Veeam: Backups finished with Success (24h)", range: .d7, group: "Veeam")
        let (fs, ws, ss) = ((try? await f) ?? [], (try? await w) ?? [], (try? await s) ?? [])
        let today = cal.startOfDay(for: Date())
        let hosts = Set((fs + ws + ss).map { $0.host.isEmpty ? $0.name : $0.host }).sorted()
        var out: [(host: String, days: [Day])] = []
        for h in hosts {
            var days: [Day] = (0..<7).map { i in
                Day(id: i, date: cal.date(byAdding: .day, value: i - 6, to: today) ?? today)
            }
            func fill(_ list: [Series], _ kp: WritableKeyPath<Day, Double>) {
                for s in list where (s.host.isEmpty ? s.name : s.host) == h {
                    for p in s.points {
                        let ds = cal.startOfDay(for: p.t)
                        if let i = days.firstIndex(where: { $0.date == ds }) {
                            days[i][keyPath: kp] = max(days[i][keyPath: kp], p.v)
                            days[i].has = true
                        }
                    }
                }
            }
            fill(fs, \.fail); fill(ws, \.warn); fill(ss, \.ok)
            out.append((h, days))
        }
        rows = out
    }
}

// MARK: Режим дежурного

struct DutyView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PanelsModel()
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var active: [Problem] {
        model.problems.filter { $0.severity >= 3 }.sorted { ($0.severity, $0.clock) > ($1.severity, $1.clock) }
    }

    private func ratio(_ id: String) -> (ok: Int, total: Int) {
        let r = model.systems.rows[id] ?? []
        return (r.filter { $0.level != .bad }.count, r.count)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                HStack {
                    Text(now, format: .dateTime.hour().minute().second())
                        .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.secondary) }
                }
                HStack(spacing: 10) {
                    ForEach([5, 4, 3], id: \.self) { s in
                        let n = model.problems.filter { $0.severity == s }.count
                        VStack(spacing: 2) {
                            Text("\(n)").font(.system(size: 46, weight: .heavy, design: .rounded))
                                .foregroundStyle(n == 0 ? Color.gray : sevColor(s))
                            Text(["Чрезвыч.", "Высокая", "Средняя"][5 - s]).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(n == 0 ? Color.clear : sevColor(s).opacity(0.6)))
                    }
                }
                HStack(spacing: 10) {
                    tile("Серверы", ratio("servers"))
                    tile("Филиалы", ratio("net"))
                }
                ScrollView {
                    VStack(spacing: 8) {
                        if active.isEmpty {
                            Label("Проблем нет", systemImage: "checkmark.seal.fill")
                                .font(.title3).foregroundStyle(Level.ok.color).padding(.top, 30)
                        }
                        ForEach(active.prefix(12)) { p in
                            HStack(alignment: .top, spacing: 10) {
                                RoundedRectangle(cornerRadius: 2).fill(sevColor(p.severity)).frame(width: 5)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                                    HStack {
                                        Text(p.host).lineLimit(1)
                                        Spacer()
                                        Text(p.clock, style: .relative)
                                    }
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(10)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                            .opacity(p.acked ? 0.55 : 1)
                        }
                    }
                }
            }
            .padding(14)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onReceive(clock) { now = $0 }
        .onReceive(timer) { _ in Task { await model.load(session: session) } }
        .task { await model.load(session: session) }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func tile(_ title: String, _ r: (ok: Int, total: Int)) -> some View {
        let col: Color = r.total == 0 ? .gray : (r.ok == r.total ? Level.ok.color : Level.bad.color)
        return HStack {
            VStack(alignment: .leading) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text("\(r.ok) / \(r.total)").font(.title2.weight(.bold).monospacedDigit()).foregroundStyle(col)
            }
            Spacer()
            ZStack {
                RingGauge(fraction: r.total == 0 ? 0 : Double(r.ok) / Double(r.total), color: col, lineWidth: 6)
            }.frame(width: 40, height: 40)
        }
        .padding(12).frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

import SwiftUI
import Charts
import AppIntents

// v2.4: «Мои панели», карусель, недельный PDF-отчёт, панель времени, Siri.

// MARK: Мои панели

struct CustomPanel: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var hostId: String
    var host: String
    var item: String
    var kind: String   // stat, line, gauge, bars
}

struct CustomKind: Identifiable { let id: String; let title: String; let icon: String }

let customKinds: [CustomKind] = [
    CustomKind(id: "stat", title: "Число", icon: "textformat.123"), CustomKind(id: "line", title: "График", icon: "chart.xyaxis.line"),
    CustomKind(id: "gauge", title: "Шкала", icon: "gauge.with.dots.needle.50percent"), CustomKind(id: "bars", title: "Столбцы", icon: "chart.bar")
]

final class CustomPanelStore: ObservableObject {
    static let shared = CustomPanelStore()
    @Published var items: [CustomPanel] { didSet { save() } }

    init() {
        if let d = UserDefaults.standard.data(forKey: "customPanels"),
           let v = try? JSONDecoder().decode([CustomPanel].self, from: d) {
            items = v
        } else if Launch.demo {
            items = [
                CustomPanel(title: "CPU контроллера DC2", hostId: "11", host: "DC2", item: "CPU utilization", kind: "line"),
                CustomPanel(title: "Память HYPER3", hostId: "32", host: "HYPER3", item: "Memory utilization", kind: "gauge"),
                CustomPanel(title: "Диск C: на MBX3", hostId: "22", host: "MBX3", item: "FS [(C:)]: Space: Used, in %", kind: "stat"),
                CustomPanel(title: "Задержка Иркутск", hostId: "17", host: "Mikrotik - Irkutsk", item: "ICMP response time", kind: "bars")
            ]
        } else {
            items = []
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: "customPanels") }
    }

    func exportJSON() -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(data: e.encode(items), encoding: .utf8)) ?? "[]"
    }

    func importJSON(_ s: String) -> Int {
        guard let d = s.data(using: .utf8), let v = try? JSONDecoder().decode([CustomPanel].self, from: d) else { return -1 }
        var n = 0
        for var p in v where !items.contains(where: { $0.host == p.host && $0.item == p.item && $0.kind == p.kind }) {
            p.id = UUID(); items.append(p); n += 1
        }
        return n
    }
}

struct CustomPanelView: View {
    @EnvironmentObject var session: Session
    let panel: CustomPanel
    let seconds: Double
    let end: Date
    @State private var series: Series?
    @State private var loaded = false

    private var key: String { "\(panel.id)\(Int(seconds))\(Int(end.timeIntervalSince1970 / 60))" }

    var body: some View {
        Group {
            if let s = series, let last = s.points.last {
                let unit = s.unit
                let isPct = unit == "percent"
                let mx = isPct ? 100 : max((s.points.map { $0.v }.max() ?? 1) * 1.25, 0.0001)
                let color: Color = isPct ? Thr.color(last.v, warn: Thr.cpuWarn, bad: Thr.cpuBad) : Level.ok.color
                switch panel.kind {
                case "stat":
                    StatPanel(title: panel.title, value: formatValue(last.v, unit: unit), color: color, spark: s.points)
                case "gauge":
                    PanelCard(title: panel.title, subtitle: panel.host, shareable: true, expandable: false) {
                        HStack {
                            Text(formatValue(last.v, unit: unit)).font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(color)
                            Spacer()
                            Text("из \(formatValue(mx, unit: unit))").font(.caption).foregroundStyle(.secondary)
                        }
                        BarGauge(fraction: last.v / mx, color: color, height: 12)
                    }
                case "bars":
                    PanelCard(title: panel.title, subtitle: panel.host, shareable: true, expandable: false) {
                        let pts = bucket(s.points, 48)
                        Chart(pts) { p in
                            BarMark(x: .value("t", p.t), y: .value("v", p.v), width: .fixed(5)).foregroundStyle(color.opacity(0.85))
                        }
                        .chartXAxis {
                            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                                AxisValueLabel(format: .dateTime.hour().minute().locale(Locale(identifier: "ru_RU")))
                            }
                        }
                        .chartYAxis {
                            AxisMarks(position: .leading) { v in
                                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.white.opacity(0.12))
                                AxisValueLabel { if let d = v.as(Double.self) { Text(formatValue(d, unit: unit)).font(.caption2) } }
                            }
                        }
                        .frame(height: 130)
                    }
                default:
                    PanelCard(title: panel.title, subtitle: panel.host, shareable: true, expandable: true) {
                        TimeSeriesChart(series: [s], unit: unit, showLegend: false).chartH(150)
                    }
                }
            } else {
                PanelCard(title: panel.title, subtitle: panel.host, shareable: false, expandable: false) {
                    Text(loaded ? "Нет данных за период" : "Загрузка…").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
            }
        }
        .task(id: key) {
            let h = NSRegularExpression.escapedPattern(for: panel.host)
            let i = NSRegularExpression.escapedPattern(for: panel.item)
            let r = (try? await session.hostSeries(host: "/^\(h)$/", filter: "/^\(i)$/", seconds: seconds, group: "/.*/",
                                                   maxPoints: 200, to: end)) ?? []
            series = r.first(where: { !$0.points.isEmpty })
            loaded = true
        }
    }

    private func bucket(_ p: [Pt], _ n: Int) -> [Pt] {
        guard p.count > n else { return p }
        let step = Double(p.count) / Double(n)
        return (0..<n).compactMap { i in
            let a = Int(Double(i) * step), b = min(p.count, Int(Double(i + 1) * step))
            guard a < b else { return nil }
            let slice = p[a..<b]
            return Pt(id: i, t: slice[slice.startIndex + slice.count / 2].t, v: slice.map { $0.v }.reduce(0, +) / Double(slice.count))
        }
    }
}

struct CustomPanelsEditor: View {
    @ObservedObject private var store = CustomPanelStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var note: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if store.items.isEmpty {
                        Text("Панелей пока нет. Нажмите «+», выберите хост и показатель — и он появится во вкладке «Панели» в разделе «Мои панели».")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(store.items) { p in
                        HStack(spacing: 10) {
                            Image(systemName: customKinds.first { $0.id == p.kind }?.icon ?? "chart.xyaxis.line").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.title)
                                Text("\(p.host) · \(p.item)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .onMove { store.items.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { store.items.remove(atOffsets: $0) }
                } footer: { Text("Порядок меняется перетаскиванием (кнопка «Изменить»). Панели хранятся на телефоне.") }
                Section("Перенос") {
                    ShareLink(item: store.exportJSON()) { Label("Экспорт в JSON", systemImage: "square.and.arrow.up") }
                    Button {
                        let n = store.importJSON(UIPasteboard.general.string ?? "")
                        note = n < 0 ? "В буфере обмена нет набора панелей." : "Добавлено панелей: \(n)."
                    } label: { Label("Импорт из буфера обмена", systemImage: "square.and.arrow.down") }
                    if let note { Text(note).font(.caption).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Мои панели")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Готово") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack { EditButton(); Button { adding = true } label: { Image(systemName: "plus") } }
                }
            }
            .sheet(isPresented: $adding) { NewCustomPanelSheet { store.items.append($0) } }
        }
    }
}

struct NewCustomPanelSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let onSave: (CustomPanel) -> Void
    @State private var host: HostMini?
    @State private var items: [ItemInfo] = []
    @State private var item: ItemInfo?
    @State private var kind = "line"
    @State private var title = ""
    @State private var pickHost = false
    @State private var filter = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Хост") {
                    Button { pickHost = true } label: { Text(host?.name ?? "Выбрать хост…").foregroundStyle(host == nil ? .orange : .primary) }
                }
                if host != nil {
                    Section("Показатель") {
                        TextField("Поиск по названию", text: $filter)
                        ForEach(items.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }.prefix(60)) { it in
                            Button {
                                item = it
                                if title.isEmpty { title = it.name }
                            } label: {
                                HStack {
                                    Text(it.name).foregroundStyle(.primary).lineLimit(2)
                                    Spacer()
                                    if item?.id == it.id { Image(systemName: "checkmark").foregroundStyle(.orange) }
                                    else { Text(it.value + (it.units.isEmpty ? "" : " " + it.units)).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
                Section("Вид") {
                    Picker("Тип", selection: $kind) {
                        ForEach(customKinds) { Label($0.title, systemImage: $0.icon).tag($0.id) }
                    }
                    TextField("Название панели", text: $title)
                }
            }
            .navigationTitle("Новая панель")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Добавить") {
                        if let h = host, let it = item {
                            onSave(CustomPanel(title: title.isEmpty ? it.name : title, hostId: h.id, host: h.name, item: it.name, kind: kind))
                            dismiss()
                        }
                    }.disabled(host == nil || item == nil)
                }
            }
            .sheet(isPresented: $pickHost) {
                HostPicker(chosen: []) { h in
                    host = h; item = nil
                    Task { items = ((try? await session.hostItems(h.id)) ?? []).filter { $0.numeric != nil } }
                }
            }
        }
    }
}

// MARK: Карусель панелей (режим телевизора)

struct CarouselView<Page: View>: View {
    let ids: [String]
    let page: (String) -> Page
    @Environment(\.dismiss) private var dismiss
    @AppStorage("carouselSec") private var sec = 20
    @State private var index = 0
    @State private var elapsed = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .top) {
            Color(white: 0.07).ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(ids.enumerated()), id: \.offset) { i, id in
                    ScrollView { page(id).padding(.horizontal, 12).padding(.top, 54).padding(.bottom, 30) }.tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .ignoresSafeArea(edges: .bottom)
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary) }
                Spacer()
                Text("Карусель · смена через \(max(0, sec - elapsed)) с").font(.caption).foregroundStyle(.secondary)
                Menu {
                    Picker("Интервал", selection: $sec) {
                        Text("10 секунд").tag(10); Text("15 секунд").tag(15); Text("20 секунд").tag(20)
                        Text("30 секунд").tag(30); Text("60 секунд").tag(60)
                    }
                } label: { Image(systemName: "timer").foregroundStyle(.orange) }
            }
            .padding(.horizontal, 14).padding(.top, 8)
            .background(Color(white: 0.07).opacity(0.85))
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: index) { _ in elapsed = 0 }
        .onReceive(timer) { _ in
            guard Launch.screen != "carousel" else { return }
            elapsed += 1
            if elapsed >= sec {
                elapsed = 0
                withAnimation { index = (index + 1) % max(ids.count, 1) }
            }
        }
    }
}

// MARK: Недельный PDF-отчёт

func presentShare(_ items: [Any]) {
    let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
    var top = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow?.rootViewController
    while let p = top?.presentedViewController { top = p }
    top?.present(vc, animated: true)
}

struct ReportPage: View {
    @ObservedObject var model: PanelsModel
    let sla: [SLARow]
    var comment: String = ""
    var light: Bool = false

    private var sev: [(Int, Int)] { [5, 4, 3].map { s in (s, model.problems.filter { $0.severity == s }.count) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Отчёт по инфраструктуре").font(.title2.weight(.bold))
                    Text("Неделя, сформирован \(ruDate(Date()))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chart.xyaxis.line").font(.title).foregroundStyle(.orange)
            }
            if !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.orange).frame(width: 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Итог недели").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        Text(comment).font(.subheadline)
                    }
                }
            }
            PanelStatsGrid(model: model)
            PanelCard(title: "Доступность филиалов", subtitle: "7 дней", shareable: false, expandable: false) {
                if sla.isEmpty { Text("Нет данных").font(.caption).foregroundStyle(.secondary) }
                else { SLASummary(rows: sla, days: 7, limit: 6) }
            }
            PanelCard(title: "Проблемы сейчас", subtitle: "\(model.problems.count) всего", shareable: false, expandable: false) {
                HStack(spacing: 14) {
                    ForEach(sev, id: \.0) { s in
                        VStack(spacing: 2) {
                            Text("\(s.1)").font(.title2.weight(.bold)).foregroundStyle(sevColor(s.0))
                            Text(sevName(s.0)).font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity)
                    }
                }
                ForEach(model.problems.sorted { $0.severity > $1.severity }.prefix(5)) { p in
                    HStack(alignment: .top, spacing: 6) {
                        Circle().fill(sevColor(p.severity)).frame(width: 7, height: 7).padding(.top, 5)
                        Text(p.name).font(.caption).lineLimit(2)
                    }
                }
            }
            PanelCard(title: "Аномалии", subtitle: "против прошлой недели", shareable: false, expandable: false) {
                AnomalyPanel(items: model.anomalies)
            }
            PanelCard(title: "Диски, где место кончается", subtitle: "прогноз", shareable: false, expandable: false) {
                let d = model.diskFC.filter { $0.daysLeft != nil }.prefix(4)
                if d.isEmpty { Text("Быстро заполняющихся дисков нет").font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(d), id: \.id) { f in
                    HStack {
                        Text("\(f.host) \(f.disk)").font(.caption).lineLimit(1)
                        Spacer()
                        Text("\(Int(f.used))% · ещё ~\(Int(f.daysLeft ?? 0)) дн.").font(.caption.monospacedDigit()).foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(16)
        .background(light ? Color.white : Color(white: 0.07))
        .environment(\.colorScheme, light ? .light : .dark)
        .environment(\.reportLight, light)
    }
}

struct ReportSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PanelsModel()
    @StateObject private var sla = SLAModel()
    @State private var ready = false
    @State private var note: String?
    @State private var comment = ""
    @State private var light = Launch.screen == "report-light"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if ready {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Итог недели для руководителя (необязательно)", text: $comment, axis: .vertical)
                            .lineLimit(1...4).padding(10)
                            .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 8))
                        Toggle("Светлая тема (для печати)", isOn: $light).font(.subheadline)
                    }
                    .padding(12)
                }
                ScrollView {
                    if ready {
                        ReportPage(model: model, sla: sla.rows, comment: comment, light: light).environmentObject(ChartSync())
                    } else {
                        ProgressView("Собираю данные…").padding(60)
                    }
                }
            }
            .background(Color(white: 0.07))
            .navigationTitle("Отчёт за неделю")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { makePDF() } label: { Label("PDF", systemImage: "square.and.arrow.up") }.disabled(!ready)
                }
            }
            .task {
                await model.load(session: session)
                await sla.load(session: session)
                ready = true
            }
        }
    }

    @MainActor private func makePDF() {
        let content = ReportPage(model: model, sla: sla.rows, comment: comment, light: light).frame(width: 560).environment(\.snapshot, true).environmentObject(ChartSync())
        let r = ImageRenderer(content: content)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Otchet-\(f.string(from: Date())).pdf")
        r.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil)
            draw(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
        }
        presentShare([url])
        Haptics.tap()
    }
}

// MARK: Панель времени

struct CustomRangeSheet: View {
    @ObservedObject var model: PanelsModel
    @Environment(\.dismiss) private var dismiss
    @State private var from = Date().addingTimeInterval(-6 * 3600)
    @State private var to = Date()

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("С", selection: $from, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                DatePicker("По", selection: $to, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                if to <= from { Text("Конец должен быть позже начала.").font(.caption).foregroundStyle(.orange) }
                Section {
                    Button("Применить") { model.customRange = from...to; dismiss() }.disabled(to <= from)
                    Button("Вернуть «последние …»", role: .destructive) { model.customRange = nil; dismiss() }
                }
            }
            .navigationTitle("Свой период")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } } }
            .onAppear {
                if let c = model.customRange { from = c.lowerBound; to = c.upperBound }
                else { to = Date(); from = to.addingTimeInterval(-model.range.seconds) }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: Siri и «Быстрые команды»

@MainActor
private func readySession() async -> Session? {
    let s = Session()
    var n = 0
    while s.restoring && n < 150 { try? await Task.sleep(nanoseconds: 100_000_000); n += 1 }
    return s.loggedIn ? s : nil
}

struct ProblemsCountIntent: AppIntent {
    static var title: LocalizedStringResource = "Сколько проблем в Zabbix"
    static var description = IntentDescription("Называет число активных проблем и самую серьёзную.")

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let s = await readySession() else {
            return .result(dialog: IntentDialog(stringLiteral: "Приложение Grafana не подключено. Откройте его и войдите."))
        }
        let p = try await s.loadProblems()
        if p.isEmpty { return .result(dialog: IntentDialog(stringLiteral: "Активных проблем нет.")) }
        let worst = p.max { $0.severity < $1.severity }
        let text = "Активных проблем: \(p.count). Самая серьёзная: \(worst?.name ?? "")."
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

struct BranchStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Состояние филиалов"
    static var description = IntentDescription("Сообщает, какие филиалы сейчас не отвечают.")

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let s = await readySession() else {
            return .result(dialog: IntentDialog(stringLiteral: "Приложение Grafana не подключено. Откройте его и войдите."))
        }
        let ser = try await s.hostSeries(host: "/.*/", filter: "ICMP ping", seconds: 900, group: "Mikrotik", maxPoints: 20)
        let alive = ser.filter { !$0.points.isEmpty }
        let down = alive.filter { ($0.points.last?.v ?? 1) < 0.5 }.map { shortName($0.name) }
        let text = down.isEmpty
            ? "Все \(alive.count) филиалов на связи."
            : "Не отвечают \(down.count) из \(alive.count): \(down.joined(separator: ", "))."
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

struct GrafanaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ProblemsCountIntent(),
                    phrases: ["Сколько проблем в \(.applicationName)", "Проблемы в \(.applicationName)",
                              "How many problems in \(.applicationName)"],
                    shortTitle: "Проблемы", systemImageName: "exclamationmark.triangle")
        AppShortcut(intent: BranchStatusIntent(),
                    phrases: ["Состояние филиалов в \(.applicationName)", "Филиалы в \(.applicationName)",
                              "Branch status in \(.applicationName)"],
                    shortTitle: "Филиалы", systemImageName: "network")
        AppShortcut(intent: SummaryIntent(),
                    phrases: ["Сводка \(.applicationName)", "Сводка мониторинга в \(.applicationName)",
                              "Monitoring summary in \(.applicationName)"],
                    shortTitle: "Сводка", systemImageName: "waveform")
    }
}

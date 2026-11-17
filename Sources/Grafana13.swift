import SwiftUI
import PhotosUI
import MetricKit

// v3.0 (визуальное и техническое): план офиса, карточка проблемы картинкой,
// MetricKit, профили серверов.

// MARK: План офиса с точками-хостами

struct PlanPoint: Codable, Identifiable, Hashable {
    var id = UUID()
    var host: String
    var x: Double   // 0…1
    var y: Double
}

struct FloorPlan: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var points: [PlanPoint] = []
}

final class FloorPlanStore: ObservableObject {
    static let shared = FloorPlanStore()
    @Published var plans: [FloorPlan] { didSet { if let d = try? JSONEncoder().encode(plans) { UserDefaults.standard.set(d, forKey: "floorPlans") } } }

    init() {
        if let d = UserDefaults.standard.data(forKey: "floorPlans"), let v = try? JSONDecoder().decode([FloorPlan].self, from: d) {
            plans = v
        } else if Launch.demo {
            plans = [FloorPlan(name: "Офис, 3 этаж", points: [
                PlanPoint(host: "HYPER3", x: 0.14, y: 0.25), PlanPoint(host: "MSA 2040", x: 0.22, y: 0.25),
                PlanPoint(host: "Коммутатор ядра", x: 0.18, y: 0.42), PlanPoint(host: "Принтер бухгалтерии", x: 0.62, y: 0.3),
                PlanPoint(host: "Точка доступа 3-1", x: 0.5, y: 0.62), PlanPoint(host: "Точка доступа 3-2", x: 0.84, y: 0.62),
                PlanPoint(host: "MBX3", x: 0.26, y: 0.33)
            ])]
        } else { plans = [] }
    }

    static func imageURL(_ id: UUID) -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("plans", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(id.uuidString).jpg")
    }

    static func image(_ id: UUID) -> UIImage? { UIImage(contentsOfFile: imageURL(id).path) }
}

struct FloorPlanListView: View {
    @ObservedObject private var store = FloorPlanStore.shared
    @State private var name = ""

    var body: some View {
        List {
            ForEach(store.plans) { p in
                NavigationLink { FloorPlanView(planId: p.id) } label: {
                    VStack(alignment: .leading) {
                        Text(p.name)
                        Text("точек: \(p.points.count)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { idx in
                for i in idx { try? FileManager.default.removeItem(at: FloorPlanStore.imageURL(store.plans[i].id)) }
                store.plans.remove(atOffsets: idx)
            }
            Section {
                HStack {
                    TextField("Название плана, например «Офис, 2 этаж»", text: $name)
                    Button("Добавить") { store.plans.append(FloorPlan(name: name)); name = "" }.disabled(name.isEmpty)
                }
            } footer: { Text("Загрузите фото или скан плана этажа и расставьте на нём хосты: принтеры, точки доступа, серверную.") }
        }
        .navigationTitle("Планы офиса")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct FloorPlanView: View {
    @EnvironmentObject var session: Session
    @ObservedObject private var store = FloorPlanStore.shared
    let planId: UUID
    @State private var photo: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var levels: [String: Level] = [:]
    @State private var editing = false
    @State private var pending: CGPoint?
    @State private var opened: HostMini?

    private var idx: Int? { store.plans.firstIndex { $0.id == planId } }

    var body: some View {
        VStack(spacing: 0) {
            if let i = idx { canvas(store.plans[i]) }
            Spacer(minLength: 0)
            Text(editing ? "Коснитесь места на плане, чтобы поставить хост. Удерживайте точку — удалить." : "Цвет точки — состояние хоста в Zabbix.")
                .font(.footnote).foregroundStyle(.secondary).padding()
        }
        .background(Color(white: 0.07))
        .navigationTitle(idx.map { store.plans[$0].name } ?? "План")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            PhotosPicker(selection: $photo, matching: .images) { Image(systemName: "photo") }
            Button(editing ? "Готово" : "Править") { editing.toggle() }
        }
        .onChange(of: photo) { _, item in
            Task {
                guard let item, let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d),
                      let jpg = img.jpegData(compressionQuality: 0.8) else { return }
                try? jpg.write(to: FloorPlanStore.imageURL(planId))
                image = img
            }
        }
        .sheet(isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            HostPicker(chosen: []) { h in
                if let p = pending, let i = idx { store.plans[i].points.append(PlanPoint(host: h.name, x: p.x, y: p.y)) }
                pending = nil
            }
        }
        .sheet(item: $opened) { h in NavigationStack { HostExplorerView(host: h) } }
        .task {
            image = FloorPlanStore.image(planId)
            levels = hostLevels((try? await session.loadProblems()) ?? [])
        }
    }

    private func canvas(_ plan: FloorPlan) -> some View {
        let ratio = image.map { $0.size.width / max($0.size.height, 1) } ?? 1.6
        return GeometryReader { g in
            ZStack(alignment: .topLeading) {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit().frame(width: g.size.width, height: g.size.height).opacity(0.85)
                } else {
                    DemoFloor().frame(width: g.size.width, height: g.size.height)
                }
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { loc in if editing { pending = CGPoint(x: loc.x / g.size.width, y: loc.y / g.size.height) } }
                ForEach(plan.points) { p in
                    let l = levels[p.host] ?? .ok
                    VStack(spacing: 2) {
                        Circle().fill(l.color).frame(width: 16, height: 16)
                            .overlay(Circle().stroke(Color.white, lineWidth: 2))
                            .shadow(color: l.color.opacity(l == .ok ? 0 : 0.9), radius: 6)
                        Text(p.host).font(.system(size: 9, weight: .semibold)).padding(.horizontal, 4)
                            .background(Capsule().fill(Color.black.opacity(0.6)))
                    }
                    .position(x: p.x * g.size.width, y: p.y * g.size.height)
                    .onTapGesture { if !editing { Task { opened = (try? await session.searchHosts(p.host))?.first ?? HostMini(id: "", name: p.host) } } }
                    .onLongPressGesture {
                        if editing, let i = idx { store.plans[i].points.removeAll { $0.id == p.id }; Haptics.tap() }
                    }
                }
            }
        }
        .aspectRatio(ratio, contentMode: .fit)
        .padding(10)
    }
}

/// Схематичный план для демо-режима и пока фото не загружено.
struct DemoFloor: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let line = Color.white.opacity(0.35)
            ctx.stroke(Path(CGRect(x: 4, y: 4, width: w - 8, height: h - 8)), with: .color(line), lineWidth: 3)
            let rooms: [(CGRect, String)] = [
                (CGRect(x: 0.03, y: 0.05, width: 0.3, height: 0.45), "Серверная"),
                (CGRect(x: 0.33, y: 0.05, width: 0.4, height: 0.45), "Бухгалтерия"),
                (CGRect(x: 0.73, y: 0.05, width: 0.24, height: 0.45), "Переговорная"),
                (CGRect(x: 0.03, y: 0.5, width: 0.94, height: 0.45), "Open space")
            ]
            for (r, name) in rooms {
                let rr = CGRect(x: r.minX * w, y: r.minY * h, width: r.width * w, height: r.height * h)
                ctx.stroke(Path(rr), with: .color(line), lineWidth: 1.5)
                ctx.draw(Text(name).font(.caption2).foregroundColor(.white.opacity(0.4)), at: CGPoint(x: rr.midX, y: rr.maxY - 12))
            }
        }
        .background(Color(red: 0.08, green: 0.1, blue: 0.14))
    }
}

// MARK: Карточка проблемы картинкой

struct ProblemShareCard: View {
    let problem: Problem
    let spark: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(sevName(problem.severity).uppercased()).font(.caption.weight(.heavy)).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(sevColor(problem.severity))).foregroundStyle(.white)
                Spacer()
                Text(problem.acked ? "подтверждена" : "не подтверждена").font(.caption).foregroundStyle(.secondary)
            }
            Text(problem.name).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Label(problem.host, systemImage: "server.rack")
                Spacer()
                Label(duration(seconds: Date().timeIntervalSince(problem.clock)), systemImage: "clock")
            }
            .font(.subheadline)
            if spark.count > 1 {
                Canvas { ctx, size in
                    let lo = spark.min() ?? 0, hi = max((spark.max() ?? 1), lo + 0.0001)
                    var p = Path()
                    for (i, v) in spark.enumerated() {
                        let pt = CGPoint(x: size.width * CGFloat(i) / CGFloat(spark.count - 1), y: size.height * (1 - CGFloat((v - lo) / (hi - lo))))
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                    ctx.stroke(p, with: .color(sevColor(problem.severity)), lineWidth: 2.5)
                }
                .frame(height: 60)
                Text("показатель за 6 часов").font(.caption2).foregroundStyle(.secondary)
            }
            Text("Началась \(ruDate(problem.clock)) · Grafana для iPhone").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 380)
        .background(LinearGradient(colors: [Color(white: 0.12), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
        .overlay(Rectangle().fill(sevColor(problem.severity)).frame(width: 6), alignment: .leading)
        .environment(\.colorScheme, .dark)
    }
}

@MainActor func shareProblemImage(_ p: Problem) {
    let spark = ProblemSparkStore.shared.data[p.triggerId] ?? []
    let r = ImageRenderer(content: ProblemShareCard(problem: p, spark: spark))
    r.scale = 3
    if let img = r.uiImage { presentShare([img]) }
}

// MARK: MetricKit: сбои и зависания на этом телефоне

final class MetricsSink: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricsSink()

    static func start() { MXMetricManager.shared.add(shared) }

    static var log: [String] { UserDefaults.standard.stringArray(forKey: "mxLog") ?? [] }

    private func append(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        let f = DateFormatter(); f.dateFormat = "dd.MM HH:mm"
        let stamp = f.string(from: Date())
        var l = Self.log
        l.insert(contentsOf: lines.map { "\(stamp) — \($0)" }, at: 0)
        UserDefaults.standard.set(Array(l.prefix(50)), forKey: "mxLog")
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        var out: [String] = []
        for p in payloads {
            if let h = p.applicationResponsivenessMetrics?.histogrammedApplicationHangTime {
                let n = h.bucketEnumerator.allObjects.compactMap { ($0 as? MXHistogramBucket<UnitDuration>)?.bucketCount }.reduce(0, +)
                if n > 0 { out.append("подвисаний интерфейса за сутки: \(n)") }
            }
            if let e = p.applicationExitMetrics?.backgroundExitData {
                let bad = e.cumulativeMemoryResourceLimitExitCount + e.cumulativeAppWatchdogExitCount + e.cumulativeAbnormalExitCount
                if bad > 0 { out.append("аварийных завершений в фоне: \(bad) (память \(e.cumulativeMemoryResourceLimitExitCount), сторож \(e.cumulativeAppWatchdogExitCount))") }
            }
        }
        append(out)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var out: [String] = []
        for p in payloads {
            for c in p.crashDiagnostics ?? [] {
                let sig = c.signal.map { "сигнал \($0)" } ?? ""
                let ex = c.exceptionType.map { "исключение \($0)" } ?? ""
                out.append("падение: " + [c.terminationReason ?? "", ex, sig].filter { !$0.isEmpty }.joined(separator: ", "))
            }
            if let h = p.hangDiagnostics, !h.isEmpty { out.append("зависаний: \(h.count), самое долгое \(h.map { $0.hangDuration.converted(to: .seconds).value }.max().map { String(format: "%.1f с", $0) } ?? "")") }
            if let c = p.cpuExceptionDiagnostics, !c.isEmpty { out.append("перерасход процессора: \(c.count)") }
        }
        append(out)
    }
}

struct MetricKitSection: View {
    @State private var log = MetricsSink.log

    var body: some View {
        Section {
            if log.isEmpty {
                Text("Отчётов пока нет: iOS присылает их не чаще раза в сутки, и только если было что-то необычное.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(log, id: \.self) { Text($0).font(.caption) }
            if !log.isEmpty {
                ShareLink(item: log.joined(separator: "\n")) { Label("Отправить разработчику", systemImage: "square.and.arrow.up") }
                Button("Очистить", role: .destructive) { UserDefaults.standard.removeObject(forKey: "mxLog"); log = [] }
            }
        } header: { Text("Сбои и зависания (MetricKit)") } footer: {
            Text("Собирает сама iOS на этом телефоне. Никуда не отправляется, пока вы не нажмёте «Отправить».")
        }
    }
}

// MARK: Профили серверов

struct ServerProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var server: String
    var user: String
}

final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()
    @Published var items: [ServerProfile] { didSet { if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: "profiles") } } }

    init() {
        if let d = UserDefaults.standard.data(forKey: "profiles"), let v = try? JSONDecoder().decode([ServerProfile].self, from: d) { items = v }
        else if Launch.demo {
            items = [ServerProfile(name: "Рабочий", server: "https://grafana.example.com", user: "admin"),
                     ServerProfile(name: "Тестовый", server: "https://grafana-test.example.com", user: "admin")]
        } else { items = [] }
    }
}

struct ProfilesView: View {
    @EnvironmentObject var session: Session
    @ObservedObject private var store = ProfileStore.shared
    @State private var name = ""
    @State private var switching: ServerProfile?

    var body: some View {
        List {
            Section("Серверы") {
                ForEach(store.items) { p in
                    Button { if p.server != session.server || p.user != session.user { switching = p } } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(p.name).foregroundStyle(.primary)
                                Text("\(p.user) · \(p.server)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if p.server == session.server && p.user == session.user { Image(systemName: "checkmark").foregroundStyle(.orange) }
                        }
                    }
                }
                .onDelete { store.items.remove(atOffsets: $0) }
            }
            Section {
                HStack {
                    TextField("Название текущего, например «Рабочий»", text: $name)
                    Button("Сохранить") {
                        store.items.append(ServerProfile(name: name, server: session.server, user: session.user)); name = ""
                    }
                    .disabled(name.isEmpty)
                }
            } footer: { Text("Пароли в профилях не хранятся: при переключении приложение выйдет и попросит пароль для выбранного сервера.") }
        }
        .navigationTitle("Профили серверов")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Переключиться на «\(switching?.name ?? "")»? Понадобится пароль.",
                            isPresented: Binding(get: { switching != nil }, set: { if !$0 { switching = nil } }), titleVisibility: .visible) {
            Button("Переключиться") {
                guard let p = switching else { return }
                session.logout()
                session.server = p.server
                session.user = p.user
            }
        }
    }
}

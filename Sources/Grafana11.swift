import SwiftUI
import SceneKit
import ARKit
import Vision
import Speech
import AVFoundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// v2.9 (визуальное): 3D-глобус филиалов, стойки, дорожки событий, режим «стена»,
// AR в серверной, голосовой диалог с мониторингом.

// MARK: Уровень хоста по активным проблемам

func hostLevels(_ ps: [Problem]) -> [String: Level] {
    var m: [String: Level] = [:]
    for p in ps {
        let l: Level = p.severity >= 4 ? .bad : .warn
        if m[p.host] != .bad { m[p.host] = l }
    }
    return m
}

// MARK: 3D-глобус

struct GlobeView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var scene: SCNScene?
    @State private var levels: [String: Level] = [:]

    private var branches: [Branch] { BranchStore.shared.items.filter(\.hasCoords) }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color.black.ignoresSafeArea()
                if let scene {
                    SceneView(scene: scene, pointOfView: scene.rootNode.childNode(withName: "cam", recursively: false),
                              options: [.allowsCameraControl])
                        .ignoresSafeArea()
                } else {
                    ProgressView().tint(.white)
                }
                legend
            }
            .navigationTitle("Глобус филиалов")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } } }
            .task {
                levels = hostLevels((try? await session.loadProblems()) ?? [])
                scene = GlobeScene.make(branches: branches, levels: levels)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var legend: some View {
        let bad = branches.filter { levels[$0.host] == .bad }.count, warn = branches.filter { levels[$0.host] == .warn }.count
        return HStack(spacing: 14) {
            Label("\(branches.count - bad - warn)", systemImage: "circle.fill").foregroundStyle(Level.ok.color)
            Label("\(warn)", systemImage: "circle.fill").foregroundStyle(Level.warn.color)
            Label("\(bad)", systemImage: "circle.fill").foregroundStyle(Level.bad.color)
            Text("вращайте пальцем").foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 24)
    }
}

enum GlobeScene {
    static func pos(_ lat: Double, _ lon: Double, _ r: Double = 1) -> SCNVector3 {
        let la = lat * .pi / 180, lo = lon * .pi / 180
        return SCNVector3(Float(r * cos(la) * sin(lo)), Float(r * sin(la)), Float(r * cos(la) * cos(lo)))
    }

    static func lines(_ pts: [[SCNVector3]], color: UIColor) -> SCNNode {
        var verts: [SCNVector3] = [], idx: [Int32] = []
        for line in pts where line.count > 1 {
            let base = Int32(verts.count)
            verts += line
            for i in 0..<(line.count - 1) { idx += [base + Int32(i), base + Int32(i + 1)] }
        }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: verts)], elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.emission.contents = color
        m.lightingModel = .constant
        g.materials = [m]
        return SCNNode(geometry: g)
    }

    static func make(branches: [Branch], levels: [String: Level]) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor.black
        let globe = SCNNode()
        scene.rootNode.addChildNode(globe)

        let sphere = SCNSphere(radius: 0.995)
        sphere.segmentCount = 72
        let sm = SCNMaterial()
        sm.diffuse.contents = UIColor(red: 0.05, green: 0.09, blue: 0.16, alpha: 1)
        sm.lightingModel = .lambert
        sphere.materials = [sm]
        globe.addChildNode(SCNNode(geometry: sphere))

        // сетка широт и долгот
        var grid: [[SCNVector3]] = []
        for lat in stride(from: -60.0, through: 75, by: 15) { grid.append(stride(from: 0.0, through: 360, by: 5).map { pos(lat, $0) }) }
        for lon in stride(from: 0.0, to: 360, by: 15) { grid.append(stride(from: -85.0, through: 85, by: 5).map { pos($0, lon) }) }
        globe.addChildNode(lines(grid, color: UIColor(white: 1, alpha: 0.12)))

        let hub = branches.first { $0.city.localizedCaseInsensitiveContains("ЦОД") || $0.city.localizedCaseInsensitiveContains("Москва") } ?? branches.first
        for b in branches {
            let lvl = levels[b.host] ?? .ok
            let color = UIColor(lvl.color)
            let dot = SCNNode(geometry: SCNSphere(radius: b.id == hub?.id ? 0.022 : 0.014))
            dot.geometry?.firstMaterial?.diffuse.contents = color
            dot.geometry?.firstMaterial?.emission.contents = color
            dot.position = pos(b.lat, b.lon, 1.005)
            globe.addChildNode(dot)
            if lvl != .ok {
                // расходящееся кольцо у проблемного филиала
                let ring = SCNNode(geometry: SCNSphere(radius: 0.02))
                ring.geometry?.firstMaterial?.diffuse.contents = color.withAlphaComponent(0.35)
                ring.geometry?.firstMaterial?.lightingModel = .constant
                ring.position = dot.position
                ring.runAction(.repeatForever(.sequence([
                    .group([.scale(to: 3, duration: 1.4), .fadeOut(duration: 1.4)]),
                    .group([.scale(to: 1, duration: 0), .fadeIn(duration: 0)])
                ])))
                globe.addChildNode(ring)
            }
            if let hub, hub.id != b.id {
                // дуга по большому кругу, приподнятая над поверхностью
                let a = pos(hub.lat, hub.lon), z = pos(b.lat, b.lon)
                var arc: [SCNVector3] = []
                let n = 40
                for i in 0...n {
                    let t = Float(i) / Float(n)
                    var v = SCNVector3(a.x + (z.x - a.x) * t, a.y + (z.y - a.y) * t, a.z + (z.z - a.z) * t)
                    let len = sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
                    let h: Float = 1 + 0.12 * sin(.pi * t) * min(1, sqrt(pow(z.x - a.x, 2) + pow(z.y - a.y, 2) + pow(z.z - a.z, 2)) * 2)
                    v = SCNVector3(v.x / len * h, v.y / len * h, v.z / len * h)
                    arc.append(v)
                }
                globe.addChildNode(lines([arc], color: color.withAlphaComponent(lvl == .ok ? 0.45 : 0.9)))
            }
        }

        // повернуть к хабу и медленно вращать
        if let hub {
            globe.eulerAngles = SCNVector3(Float(hub.lat * .pi / 180) * 0.8, Float(-hub.lon * .pi / 180), 0)
        }
        let cam = SCNNode()
        cam.name = "cam"
        cam.camera = SCNCamera()
        cam.camera?.fieldOfView = 40
        cam.position = SCNVector3(0, 0, 3.4)
        scene.rootNode.addChildNode(cam)
        let light = SCNNode()
        light.light = SCNLight()
        light.light?.type = .omni
        light.position = SCNVector3(2, 3, 4)
        scene.rootNode.addChildNode(light)
        let amb = SCNNode()
        amb.light = SCNLight()
        amb.light?.type = .ambient
        amb.light?.intensity = 500
        scene.rootNode.addChildNode(amb)
        return scene
    }
}

// MARK: Стойки

struct RackSlot: Codable, Identifiable, Hashable {
    var id = UUID()
    var host: String
    var u: Int          // нижний юнит
    var size: Int = 1
}

struct Rack: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var units: Int = 42
    var slots: [RackSlot] = []
}

final class RackStore: ObservableObject {
    static let shared = RackStore()
    @Published var racks: [Rack] { didSet { if let d = try? JSONEncoder().encode(racks) { UserDefaults.standard.set(d, forKey: "racks") } } }

    init() {
        if let d = UserDefaults.standard.data(forKey: "racks"), let v = try? JSONDecoder().decode([Rack].self, from: d) {
            racks = v
        } else if Launch.demo {
            racks = [Rack(name: "Серверная, стойка 1", units: 24, slots: [
                RackSlot(host: "Маршрутизатор ЦОД", u: 23), RackSlot(host: "Коммутатор ядра", u: 21),
                RackSlot(host: "HYPER1", u: 17, size: 2), RackSlot(host: "HYPER2", u: 15, size: 2), RackSlot(host: "HYPER3", u: 13, size: 2),
                RackSlot(host: "MSA 2040", u: 9, size: 2), RackSlot(host: "Synology DS423+", u: 6, size: 2), RackSlot(host: "ИБП", u: 1, size: 3)
            ])]
        } else {
            racks = []
        }
    }
}

struct RackListView: View {
    @ObservedObject private var store = RackStore.shared
    @State private var newName = ""

    var body: some View {
        List {
            ForEach(store.racks) { r in
                NavigationLink { RackView(rackId: r.id) } label: {
                    VStack(alignment: .leading) {
                        Text(r.name)
                        Text("\(r.units)U · устройств: \(r.slots.count)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { store.racks.remove(atOffsets: $0) }
            Section {
                HStack {
                    TextField("Название новой стойки", text: $newName)
                    Button("Добавить") { store.racks.append(Rack(name: newName)); newName = "" }.disabled(newName.isEmpty)
                }
            } footer: { Text("Расставьте серверы по юнитам — цвет показывает их состояние в Zabbix.") }
        }
        .navigationTitle("Стойки")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct RackView: View {
    @EnvironmentObject var session: Session
    @ObservedObject private var store = RackStore.shared
    let rackId: UUID
    @State private var levels: [String: Level] = [:]
    @State private var picking = false
    @State private var editing: RackSlot?

    private var idx: Int? { store.racks.firstIndex { $0.id == rackId } }

    var body: some View {
        ScrollView {
            if let i = idx { rack(store.racks[i]).padding() }
        }
        .background(Color(white: 0.07))
        .navigationTitle(idx.map { store.racks[$0].name } ?? "Стойка")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button { picking = true } label: { Image(systemName: "plus") } }
        .sheet(isPresented: $picking) {
            HostPicker(chosen: []) { h in
                guard let i = idx else { return }
                let used = Set(store.racks[i].slots.flatMap { s in (s.u..<(s.u + s.size)) })
                let free = (1...store.racks[i].units).reversed().first { !used.contains($0) } ?? 1
                store.racks[i].slots.append(RackSlot(host: h.name, u: free))
            }
        }
        .sheet(item: $editing) { s in SlotEditor(rackId: rackId, slotId: s.id).presentationDetents([.medium]) }
        .task { levels = hostLevels((try? await session.loadProblems()) ?? []) }
    }

    private func rack(_ r: Rack) -> some View {
        let unitH: CGFloat = 22
        return VStack(spacing: 0) {
            ForEach((1...r.units).reversed(), id: \.self) { u in
                if let s = r.slots.first(where: { $0.u + $0.size - 1 == u }) {
                    slotView(s, height: unitH * CGFloat(s.size))
                } else if !r.slots.contains(where: { u >= $0.u && u < $0.u + $0.size }) {
                    HStack(spacing: 6) {
                        Text("\(u)").font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary).frame(width: 20)
                        Rectangle().fill(Color.white.opacity(0.04)).frame(height: unitH - 2)
                    }
                    .frame(height: unitH)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.25), lineWidth: 3))
    }

    private func slotView(_ s: RackSlot, height: CGFloat) -> some View {
        let lvl = levels[s.host] ?? .ok
        return HStack(spacing: 6) {
            Text("\(s.u + s.size - 1)").font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary).frame(width: 20)
            HStack {
                Circle().fill(lvl.color).frame(width: 8, height: 8)
                Text(s.host).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer()
                Text("\(s.size)U").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: height - 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(lvl.color.opacity(lvl == .ok ? 0.18 : 0.4)))
            .onTapGesture { editing = s }
        }
        .frame(height: height)
    }
}

struct SlotEditor: View {
    @ObservedObject private var store = RackStore.shared
    @Environment(\.dismiss) private var dismiss
    let rackId: UUID
    let slotId: UUID

    private var path: (Int, Int)? {
        guard let r = store.racks.firstIndex(where: { $0.id == rackId }),
              let s = store.racks[r].slots.firstIndex(where: { $0.id == slotId }) else { return nil }
        return (r, s)
    }

    var body: some View {
        NavigationStack {
            Form {
                if case let (r, s)? = path {
                    Text(store.racks[r].slots[s].host).font(.headline)
                    Stepper("Нижний юнит: \(store.racks[r].slots[s].u)", value: $store.racks[r].slots[s].u, in: 1...store.racks[r].units)
                    Stepper("Высота: \(store.racks[r].slots[s].size)U", value: $store.racks[r].slots[s].size, in: 1...10)
                    Button("Убрать из стойки", role: .destructive) { store.racks[r].slots.remove(at: s); dismiss() }
                }
            }
            .navigationTitle("Место в стойке")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Готово") { dismiss() } }
        }
    }
}

// MARK: Дорожки событий по хостам

struct LanesPanel: View {
    let events: [HistEvent]

    private var window: (from: Date, to: Date) { (Date().addingTimeInterval(-86400), Date()) }

    struct Lane: Identifiable { var id: String { host }; let host: String; let events: [HistEvent] }

    private var lanes: [Lane] {
        let w = window
        let recent = events.filter { ($0.end ?? Date()) > w.from }
        let byHost = Dictionary(grouping: recent, by: \.host)
        return byHost.map { Lane(host: $0.key, events: $0.value) }.sorted { $0.events.count > $1.events.count }.prefix(8).map { $0 }
    }

    var body: some View {
        PanelCard(title: "Дорожки событий", subtitle: "сутки · самые шумные хосты") {
            let ls = lanes
            if ls.isEmpty {
                Text("За сутки событий нет").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(ls) { ln in
                        HStack(spacing: 6) {
                            Text(shortName(ln.host)).font(.caption2).lineLimit(1).frame(width: 76, alignment: .leading)
                            laneView(ln.events)
                        }
                    }
                    HStack {
                        Spacer().frame(width: 82)
                        Text("−24ч"); Spacer(); Text("−12ч"); Spacer(); Text("сейчас")
                    }
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func laneView(_ evs: [HistEvent]) -> some View {
        let w = window
        return Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3), with: .color(.white.opacity(0.05)))
            let span = w.to.timeIntervalSince(w.from)
            for e in evs {
                let x0 = max(0, e.start.timeIntervalSince(w.from) / span) * size.width
                let x1 = min(1, (e.end ?? w.to).timeIntervalSince(w.from) / span) * size.width
                let r = CGRect(x: x0, y: 2, width: max(3, x1 - x0), height: size.height - 4)
                ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(sevColor(e.severity).opacity(e.end == nil ? 1 : 0.7)))
            }
        }
        .frame(height: 16)
    }
}

// MARK: Режим «стена»: альбомная ориентация, крупные плитки + карусель

struct WallView<Page: View>: View {
    @ObservedObject var model: PanelsModel
    let ids: [String]
    let page: (String) -> Page
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var clock = Date()
    @State private var night = Launch.screen == "wall-night"
    @State private var savedBrightness: CGFloat = 0.5
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var worst: Int { model.problems.map(\.severity).max() ?? 0 }
    private var avgCPU: Double? {
        let v = model.cpu.compactMap { $0.points.last?.v }
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }
    private var avgMem: Double? {
        let v = model.mem.compactMap { $0.points.last?.v }
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    var body: some View {
        GeometryReader { g in
            let wide = g.size.width > g.size.height
            let layout = wide ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 12))
            layout {
                tiles(wide: wide).frame(width: wide ? g.size.width * 0.32 : nil)
                VStack(spacing: 6) {
                    if !ids.isEmpty {
                        page(ids[index % ids.count])
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .id(index)
                            .transition(.opacity)
                    }
                    HStack(spacing: 5) {
                        ForEach(ids.indices, id: \.self) { i in
                            Capsule().fill(i == index % max(1, ids.count) ? Color.white : Color.white.opacity(0.25)).frame(width: 14, height: 3)
                        }
                    }
                }
            }
            .padding(12)
        }
        .background(Color(white: 0.05).ignoresSafeArea())
        .colorMultiply(night ? Color(red: 1, green: 0.35, blue: 0.3) : .white)
        .overlay(alignment: .topTrailing) {
            HStack {
                Button { night.toggle(); applyNight() } label: {
                    Image(systemName: night ? "moon.fill" : "moon").font(.title2).foregroundStyle(.white.opacity(0.4))
                }
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.white.opacity(0.4)) }
            }
            .padding(8)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true; savedBrightness = UIScreen.main.brightness; applyNight() }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false; if !Launch.demo { UIScreen.main.brightness = savedBrightness } }
        .onReceive(timer) { t in
            clock = t
            if Int(t.timeIntervalSince1970) % 15 == 0, !ids.isEmpty { withAnimation(.easeInOut(duration: 0.6)) { index += 1 } }
        }
    }

    /// Ночной режим: красноватые тона и минимальная яркость — телефон на тумбочке у дежурного.
    private func applyNight() {
        guard !Launch.demo else { return }
        UIScreen.main.brightness = night ? 0.05 : savedBrightness
    }

    private func tiles(wide: Bool) -> some View {
        let cols = wide ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, spacing: 10) {
            tile("Проблемы", "\(model.problems.count)", worst >= 4 ? Level.bad.color : (worst > 0 ? Level.warn.color : Level.ok.color))
            tile("Высокие и выше", "\(model.problems.filter { $0.severity >= 4 }.count)", Level.bad.color)
            tile("CPU серверов", avgCPU.map { "\(Int($0))%" } ?? "—", .orange)
            tile("Память", avgMem.map { "\(Int($0))%" } ?? "—", .purple)
            Text(clock.formatted(.dateTime.hour().minute().second().locale(Locale(identifier: "ru_RU"))))
                .font(.system(size: wide ? 40 : 28, weight: .thin, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func tile(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(color)
                .minimumScaleFactor(0.5).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(color.opacity(0.12)))
    }
}

// MARK: AR в серверной: QR-наклейки → карточки состояния над ними

struct ARServerRoomView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var problems: [Problem] = []
    @State private var seen: [String] = []

    var body: some View {
        ZStack(alignment: .bottom) {
            if ARWorldTrackingConfiguration.isSupported {
                ARQRView(problems: problems) { name in if !seen.contains(name) { seen.append(name); Haptics.tap() } }
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "arkit").font(.system(size: 50)).foregroundStyle(.secondary)
                    Text("AR недоступна на этом устройстве").font(.headline)
                    Text("На iPhone наведите камеру на QR-наклейки серверов (Настройки → «В серверной» → QR-наклейка хоста): над каждой появится карточка с его состоянием.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    ForEach(["HYPER3", "MSA 2040"], id: \.self) { h in
                        ARCard(host: h, problems: problems.filter { $0.host == h }).frame(width: 260)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(white: 0.07))
            }
            VStack(spacing: 6) {
                Text(seen.isEmpty ? "Наведите камеру на QR-наклейку сервера" : "Найдено: " + seen.joined(separator: ", "))
                    .font(.footnote).padding(10).background(.ultraThinMaterial, in: Capsule())
                Button("Закрыть") { dismiss() }.buttonStyle(.borderedProminent)
            }
            .padding(.bottom, 30)
        }
        .task { problems = (try? await session.loadProblems()) ?? [] }
    }
}

struct ARCard: View {
    let host: String
    let problems: [Problem]

    var body: some View {
        let lvl: Level = problems.contains { $0.severity >= 4 } ? .bad : (problems.isEmpty ? .ok : .warn)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(lvl.color).frame(width: 12, height: 12)
                Text(host).font(.headline).lineLimit(1)
            }
            if problems.isEmpty {
                Text("Проблем нет").font(.subheadline).foregroundStyle(Level.ok.color)
            } else {
                ForEach(problems.sorted { $0.severity > $1.severity }.prefix(3)) { p in
                    Text("• " + p.name).font(.caption).lineLimit(2).foregroundStyle(sevColor(p.severity))
                }
                if problems.count > 3 { Text("и ещё \(problems.count - 3)").font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.8)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(lvl.color, lineWidth: 2))
        .environment(\.colorScheme, .dark)
    }
}

struct ARQRView: UIViewRepresentable {
    let problems: [Problem]
    var onFound: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView(frame: .zero)
        v.automaticallyUpdatesLighting = true
        v.session.delegate = context.coordinator
        context.coordinator.view = v
        let cfg = ARWorldTrackingConfiguration()
        cfg.planeDetection = [.vertical, .horizontal]
        v.session.run(cfg)
        return v
    }

    func updateUIView(_ v: ARSCNView, context: Context) { context.coordinator.problems = problems }

    static func dismantleUIView(_ v: ARSCNView, coordinator: Coordinator) { v.session.pause() }

    final class Coordinator: NSObject, ARSessionDelegate {
        weak var view: ARSCNView?
        var problems: [Problem] = []
        let onFound: (String) -> Void
        private var busy = false
        private var last = Date.distantPast
        private var placed: Set<String> = []

        init(onFound: @escaping (String) -> Void) { self.onFound = onFound }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            guard !busy, Date().timeIntervalSince(last) > 0.6 else { return }
            let viewport: CGSize? = MainActor.assumeIsolated { view?.bounds.size }
            guard let viewport else { return }
            busy = true
            last = Date()
            let buffer = frame.capturedImage
            let transform = frame.displayTransform(for: .portrait, viewportSize: viewport)
            let req = VNDetectBarcodesRequest()
            req.symbologies = [.qr]
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([req])
                let found: [(String, CGPoint)] = (req.results ?? []).compactMap { o in
                    guard let s = o.payloadStringValue else { return nil }
                    let c = CGPoint(x: o.boundingBox.midX, y: 1 - o.boundingBox.midY).applying(transform)
                    return (s, CGPoint(x: c.x * viewport.width, y: c.y * viewport.height))
                }
                Task { @MainActor in
                    guard let self else { return }
                    for (payload, pt) in found { self.place(payload, at: pt) }
                    self.busy = false
                }
            }
        }

        private func hostName(_ payload: String) -> String? {
            guard let u = URL(string: payload), u.scheme == "grafanaapp", u.host == "host" else { return nil }
            let id = u.pathComponents.filter { $0 != "/" }.first ?? ""
            return URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "name" }?.value ?? id
        }

        @MainActor private func place(_ payload: String, at pt: CGPoint) {
            guard let view, let name = hostName(payload), !placed.contains(name),
                  let q = view.raycastQuery(from: pt, allowing: .estimatedPlane, alignment: .any),
                  let hit = view.session.raycast(q).first else { return }
            placed.insert(name)
            onFound(name)
            let r = ImageRenderer(content: ARCard(host: name, problems: problems.filter { $0.host == name }))
            r.scale = 3
            guard let img = r.uiImage else { return }
            let w: CGFloat = 0.22
            let plane = SCNPlane(width: w, height: w * img.size.height / img.size.width)
            plane.firstMaterial?.diffuse.contents = img
            plane.firstMaterial?.lightingModel = .constant
            plane.firstMaterial?.isDoubleSided = true
            let node = SCNNode(geometry: plane)
            let c = hit.worldTransform.columns.3
            node.simdPosition = SIMD3(c.x, c.y + Float(plane.height / 2) + 0.06, c.z)
            node.constraints = [SCNBillboardConstraint()]
            view.scene.rootNode.addChildNode(node)
        }
    }
}

// MARK: Голосовой диалог с мониторингом

struct ChatMsg: Identifiable {
    let id = UUID()
    let me: Bool
    let text: String
    var action: ChatAction?
}

struct ChatAction {
    enum Kind { case ack, close }
    let kind: Kind
    let problem: Problem
}

final class SpeechInput: ObservableObject {
    @Published var text = ""
    @Published var running = false
    @Published var error: String?
    private let engine = AVAudioEngine()
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))

    func toggle() { running ? stop() : start() }

    func start() {
        SFSpeechRecognizer.requestAuthorization { st in
            DispatchQueue.main.async {
                guard st == .authorized else { self.error = "Нет доступа к распознаванию речи (Настройки iOS → Grafana)."; return }
                self.begin()
            }
        }
    }

    private func begin() {
        guard let recognizer, recognizer.isAvailable else { error = "Распознавание речи сейчас недоступно"; return }
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try s.setActive(true, options: .notifyOthersOnDeactivation)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            request = req
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in req.append(buf) }
            engine.prepare()
            try engine.start()
            text = ""
            running = true
            error = nil
            task = recognizer.recognitionTask(with: req) { [weak self] r, e in
                let t = r?.bestTranscription.formattedString
                let done = e != nil || (r?.isFinal ?? false)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let t { self.text = t }
                    if done { self.stop() }
                }
            }
        } catch {
            self.error = error.localizedDescription
            stop()
        }
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        running = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

#if canImport(FoundationModels)
@available(iOS 26, *)
final class LLMChat {
    private let s: LanguageModelSession?

    init() {
        if case .available = SystemLanguageModel.default.availability {
            s = LanguageModelSession(instructions: "Ты помощник дежурного системного администратора. Отвечай по-русски, коротко, по пунктам, только на основе данных мониторинга, которые приходят в сообщениях. Помни предыдущие вопросы разговора.")
        } else { s = nil }
    }

    var available: Bool { s != nil }

    func ask(_ q: String, context: String) async -> String? {
        guard let s else { return nil }
        return try? await s.respond(to: "Свежие данные мониторинга:\n\(context)\n\nВопрос: \(q)").content
    }
}
#endif

struct ChatAskView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speech = SpeechInput()
    @State private var msgs: [ChatMsg] = []
    @State private var q = ""
    @State private var busy = false
    @State private var speak = UserDefaults.standard.object(forKey: "chatSpeak") as? Bool ?? true
    @State private var synth = AVSpeechSynthesizer()
    @State private var llm: AnyObject?
    @State private var lastKeys: [String] = []
    @State private var pending: ChatAction?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if msgs.isEmpty {
                                Text("Спросите голосом или текстом: «что с почтой?», «а с Казанью?», «подтверди её». Я помню, о чём шла речь.")
                                    .font(.footnote).foregroundStyle(.secondary).padding()
                            }
                            ForEach(msgs) { m in bubble(m).id(m.id) }
                            if busy { ProgressView().padding(.leading) }
                        }
                        .padding(12)
                    }
                    .onChange(of: msgs.count) { _, _ in if let l = msgs.last { withAnimation { proxy.scrollTo(l.id, anchor: .bottom) } } }
                }
                inputBar
            }
            .navigationTitle("Разговор с мониторингом")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { speech.stop(); synth.stopSpeaking(at: .immediate); dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { speak.toggle(); UserDefaults.standard.set(speak, forKey: "chatSpeak"); if !speak { synth.stopSpeaking(at: .immediate) } } label: {
                        Image(systemName: speak ? "speaker.wave.2.fill" : "speaker.slash")
                    }
                }
            }
            .confirmationDialog(pendingTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
                Button(pending?.kind == .close ? "Закрыть проблему" : "Подтвердить") { if let a = pending { Task { await perform(a) } } }
            }
            .onChange(of: speech.running) { was, now in
                if was && !now && !speech.text.isEmpty { q = speech.text; Task { await send() } }
            }
            .task {
                if Launch.screen == "chat" {
                    q = "Что сейчас с почтой?"; await send()
                    q = "А что из этого самое серьёзное?"; await send()
                }
            }
        }
    }

    private var pendingTitle: String {
        guard let a = pending else { return "" }
        return (a.kind == .close ? "Закрыть: " : "Подтвердить: ") + a.problem.name
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Button { speech.toggle() } label: {
                Image(systemName: speech.running ? "stop.circle.fill" : "mic.circle.fill").font(.title)
                    .foregroundStyle(speech.running ? Level.bad.color : Color.accentColor)
            }
            TextField(speech.running ? "Слушаю…" : "Вопрос", text: speech.running ? .constant(speech.text) : $q, axis: .vertical)
                .lineLimit(1...3).textFieldStyle(.roundedBorder)
            Button { Task { await send() } } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                .disabled(busy || q.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(10)
        .background(.bar)
        .overlay(alignment: .top) { if let e = speech.error { Text(e).font(.caption2).foregroundStyle(.orange).offset(y: -16) } }
    }

    private func bubble(_ m: ChatMsg) -> some View {
        VStack(alignment: m.me ? .trailing : .leading, spacing: 6) {
            Text(m.text).font(.subheadline).textSelection(.enabled)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 14).fill(m.me ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.15)))
            if let a = m.action {
                Button { pending = a } label: {
                    Label(a.kind == .close ? "Закрыть «\(a.problem.name)»" : "Подтвердить «\(a.problem.name)»",
                          systemImage: a.kind == .close ? "xmark.seal" : "checkmark.seal")
                        .font(.caption).lineLimit(1)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: m.me ? .trailing : .leading)
    }

    private func send() async {
        let text = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        q = ""
        msgs.append(ChatMsg(me: true, text: text))
        busy = true
        defer { busy = false }
        let probs = (try? await session.loadProblems()) ?? []
        let cpu = MonitorContext.lastLine((try? await session.hostSeries(host: "/.*/", filter: "CPU utilization", seconds: 3600, group: serverGroups, maxPoints: 20)) ?? [], unit: "percent")
        let mem = MonitorContext.lastLine((try? await session.hostSeries(host: "/.*/", filter: "Memory utilization", seconds: 3600, group: serverGroups, maxPoints: 20)) ?? [], unit: "percent")
        let rtt = MonitorContext.lastLine((try? await session.hostSeries(host: "/.*/", filter: "ICMP response time", seconds: 3600, group: "Mikrotik", maxPoints: 20)) ?? [], unit: "s")

        // ключевые слова: новые или из прошлого вопроса («а она?», «подтверди её»)
        var keys = MonitorContext.keys(for: text)
        if keys.isEmpty { keys = lastKeys } else { lastKeys = keys }
        let low = text.lowercased()
        let related = probs.filter { p in keys.contains { p.name.lowercased().contains($0) || p.host.lowercased().contains($0) } }
            .sorted { $0.severity > $1.severity }
        var action: ChatAction?
        if let top = related.first ?? (keys.isEmpty ? nil : probs.max { $0.severity < $1.severity }) {
            if low.contains("подтверд") { action = ChatAction(kind: .ack, problem: top) }
            if low.contains("закро") || low.contains("закрой") { action = ChatAction(kind: .close, problem: top) }
        }

        var reply: String?
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            if llm == nil { llm = LLMChat() }
            if let c = llm as? LLMChat, c.available {
                let probText = MonitorContext.text(problems: probs, cpu: cpu, mem: mem, rtt: rtt)
                reply = await c.ask(text, context: probText)
            }
        }
        #endif
        if reply == nil {
            reply = MonitorContext.fallback(question: keys.joined(separator: " ") + " " + text, problems: probs, cpu: cpu, mem: mem, rtt: rtt)
        }
        if action != nil { reply = (reply ?? "") + "\n\nНажмите кнопку ниже — перед действием спрошу подтверждение и Face ID." }
        msgs.append(ChatMsg(me: false, text: reply ?? "", action: action))
        if speak, let r = reply {
            let u = AVSpeechUtterance(string: String(r.prefix(400)))
            u.voice = AVSpeechSynthesisVoice(language: "ru-RU")
            synth.speak(u)
        }
    }

    private func perform(_ a: ChatAction) async {
        guard await FaceGate.ok(a.kind == .close ? "Закрыть проблему в Zabbix" : "Подтвердить проблему в Zabbix") else { return }
        do {
            if a.kind == .close { try await session.closeProblem(a.problem) }
            else { try await session.acknowledge(eventId: a.problem.id, message: "Подтверждено голосом из приложения") }
            msgs.append(ChatMsg(me: false, text: a.kind == .close ? "Закрыл: \(a.problem.name)" : "Подтвердил: \(a.problem.name)"))
            Haptics.success()
        } catch {
            msgs.append(ChatMsg(me: false, text: "Не получилось: " + explainZabbixWrite(error)))
            Haptics.error()
        }
    }
}

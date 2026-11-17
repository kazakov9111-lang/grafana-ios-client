import SwiftUI
import Charts
import CoreHaptics
import ActivityKit
import MapKit

// v2.7: оформление и анимации — стекло iOS 26, фон по состоянию, конфетти, своя вибрация,
// вращение значка обновления, зум-переход, прокрутка графиков, пульс на карте, 3D CPU, Live Activity.

// MARK: Признак «рисуется в картинку» (PDF/поделиться): там без стекла и анимаций

private struct SnapshotKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var snapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}

// MARK: Фон карточки

struct CardBackground: ViewModifier {
    var radius: CGFloat = 10
    @Environment(\.reportLight) private var reportLight
    @Environment(\.snapshot) private var snapshot
    @AppStorage("glassCards") private var glass = false

    func body(content: Content) -> some View {
        if reportLight {
            content.background(Color.white, in: RoundedRectangle(cornerRadius: radius))
        } else if glass && !snapshot {
            glassy(content)
        } else {
            content.background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: radius))
        }
    }

    @ViewBuilder private func glassy(_ content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
        }
    }
}

// MARK: Фон «Обзора» по состоянию

struct StateBackground: View {
    let severity: Int
    @State private var phase = false

    private var tint: Color {
        switch severity {
        case 5...: return Color(red: 0.55, green: 0.05, blue: 0.08)
        case 4: return Color(red: 0.5, green: 0.18, blue: 0.05)
        case 3: return Color(red: 0.45, green: 0.32, blue: 0.02)
        default: return Color(red: 0.02, green: 0.28, blue: 0.16)
        }
    }

    var body: some View {
        ZStack {
            Color(white: 0.07)
            mesh.opacity(0.55)
        }
        .ignoresSafeArea()
        .onAppear { withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) { phase = true } }
        .animation(.easeInOut(duration: 1.2), value: severity)
    }

    @ViewBuilder private var mesh: some View {
        if #available(iOS 18, *) {
            let d: Float = phase ? 0.12 : -0.08
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.5 + d, 0.45 - d], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1]
            ], colors: [
                tint, .black, tint.opacity(0.6),
                .black, tint.opacity(0.35), .black,
                .black, .black, tint.opacity(0.3)
            ])
        } else {
            LinearGradient(colors: [tint, .black, .black], startPoint: phase ? .topLeading : .top, endPoint: .bottom)
        }
    }
}

// MARK: Конфетти, когда проблем стало 0

struct ConfettiView: View {
    var seconds: Double = 3.5
    var onDone: () -> Void = {}

    private struct Piece {
        let x: Double, speed: Double, spin: Double, size: Double, sway: Double, color: Color, delay: Double
    }

    @State private var pieces: [Piece] = (0..<90).map { _ in
        Piece(x: .random(in: 0...1), speed: .random(in: 0.25...0.55), spin: .random(in: 1...6),
              size: .random(in: 5...10), sway: .random(in: 8...30),
              color: [Color.green, .orange, .yellow, .mint, .cyan, .pink].randomElement()!, delay: .random(in: 0...0.6))
    }
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSince(start)
                let fade = max(0, min(1, (seconds - t) / 0.8))
                for p in pieces {
                    let lt = t - p.delay
                    guard lt > 0 else { continue }
                    let y = (lt * p.speed).truncatingRemainder(dividingBy: 1.15) * size.height - 20
                    let x = p.x * size.width + sin(lt * p.spin) * p.sway
                    var c = ctx
                    c.translateBy(x: x, y: y)
                    c.rotate(by: .radians(lt * p.spin))
                    c.opacity = fade
                    c.fill(Path(CGRect(x: -p.size / 2, y: -p.size / 4, width: p.size, height: p.size / 2)), with: .color(p.color))
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .onAppear {
            start = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { onDone() }
        }
    }
}

// MARK: Своя вибрация для новой чрезвычайной проблемы

final class CriticalHaptic {
    static let shared = CriticalHaptic()
    private var engine: CHHapticEngine?

    func play() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { Haptics.error(); return }
        do {
            if engine == nil { engine = try CHHapticEngine(); engine?.resetHandler = { [weak self] in try? self?.engine?.start() } }
            try engine?.start()
            var events: [CHHapticEvent] = []
            // три резких удара, затем нарастающий гул — отличается от обычных уведомлений
            for i in 0..<3 {
                events.append(CHHapticEvent(eventType: .hapticTransient, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 1)
                ], relativeTime: Double(i) * 0.12))
            }
            events.append(CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.4),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2)
            ], relativeTime: 0.45, duration: 0.6))
            let curve = CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [
                .init(relativeTime: 0, value: 0.3), .init(relativeTime: 0.6, value: 1)
            ], relativeTime: 0.45)
            let pattern = try CHHapticPattern(events: events, parameterCurves: [curve])
            try engine?.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            Haptics.error()
        }
    }
}

extension Haptics {
    static func critical() { CriticalHaptic.shared.play() }
}

// MARK: Значок обновления крутится, пока идёт загрузка

struct LoadingSpin: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.symbolEffect(.rotate, options: .repeat(.continuous), isActive: active)
        } else {
            content.symbolEffect(.pulse, options: .repeating, isActive: active)
        }
    }
}

// MARK: Зум-переход карточки на весь экран (iOS 18)

struct ZoomSource: ViewModifier {
    let id: String
    let ns: Namespace.ID?

    func body(content: Content) -> some View {
        if #available(iOS 18, *), let ns {
            content.matchedTransitionSource(id: id, in: ns)
        } else {
            content
        }
    }
}

struct ZoomDest: ViewModifier {
    let id: String
    let ns: Namespace.ID?

    func body(content: Content) -> some View {
        if #available(iOS 18, *), let ns {
            content.navigationTransition(.zoom(sourceID: id, in: ns))
        } else {
            content
        }
    }
}

private struct ZoomNSKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }

extension EnvironmentValues {
    var zoomNS: Namespace.ID? {
        get { self[ZoomNSKey.self] }
        set { self[ZoomNSKey.self] = newValue }
    }
}

// MARK: Прокрутка графика пальцем (последний час на экране)

struct ScrollableChart: ViewModifier {
    let enabled: Bool
    let range: ClosedRange<Date>

    func body(content: Content) -> some View {
        let total = range.upperBound.timeIntervalSince(range.lowerBound)
        if enabled && total > 2 * 3600 {
            let visible = max(3600, total / 6)
            content
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: visible)
                .chartScrollPosition(initialX: range.upperBound.addingTimeInterval(-visible))
        } else {
            content
        }
    }
}

// MARK: Пульс на карте для лежащих филиалов

func addPulse(to view: UIView, color: UIColor) {
    view.layer.sublayers?.filter { $0.name == "pulse" }.forEach { $0.removeFromSuperlayer() }
    let size: CGFloat = 46
    let l = CAShapeLayer()
    l.name = "pulse"
    l.path = UIBezierPath(ovalIn: CGRect(x: -size / 2, y: -size / 2, width: size, height: size)).cgPath
    l.position = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    l.fillColor = color.withAlphaComponent(0.35).cgColor
    l.strokeColor = color.cgColor
    l.lineWidth = 1.5
    let scale = CABasicAnimation(keyPath: "transform.scale")
    scale.fromValue = 0.3; scale.toValue = 1.3
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0.9; fade.toValue = 0
    let g = CAAnimationGroup()
    g.animations = [scale, fade]
    g.duration = 1.6
    g.repeatCount = .infinity
    g.timingFunction = CAMediaTimingFunction(name: .easeOut)
    g.isRemovedOnCompletion = false
    l.add(g, forKey: "pulse")
    view.layer.insertSublayer(l, at: 0)
}

// MARK: 3D: CPU × память × время (iOS 26)

@available(iOS 26, *)
struct CPU3DPanel: View {
    let cpu: [Series]
    let mem: [Series]

    private struct P3: Identifiable {
        let id = UUID()
        let host: String
        let t: Double
        let cpu: Double
        let mem: Double
    }

    private var points: [P3] {
        var out: [P3] = []
        let t0 = cpu.flatMap { $0.points }.map { $0.t }.min() ?? Date()
        for s in cpu.prefix(6) {
            guard let m = mem.first(where: { $0.name == s.name }) else { continue }
            let step = max(1, s.points.count / 30)
            for (i, p) in s.points.enumerated() where i % step == 0 {
                let mv = m.points.min { abs($0.t.timeIntervalSince(p.t)) < abs($1.t.timeIntervalSince(p.t)) }?.v ?? 0
                out.append(P3(host: shortName(s.name), t: p.t.timeIntervalSince(t0) / 3600, cpu: p.v, mem: mv))
            }
        }
        return out
    }

    var body: some View {
        PanelCard(title: "CPU × память × время", subtitle: "3D · крутите пальцем") {
            let pts = points
            if pts.isEmpty {
                Text("Нет данных памяти для этих хостов").font(.caption).foregroundStyle(.secondary).frame(height: 80)
            } else {
                Chart3D(pts) { p in
                    PointMark(x: .value("Часы", p.t), y: .value("CPU %", p.cpu), z: .value("RAM %", p.mem))
                        .foregroundStyle(by: .value("Хост", p.host))
                }
                .frame(height: 300)
            }
        }
    }
}

// MARK: Live Activity / Dynamic Island

@MainActor
enum LiveStatus {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "liveActivity") }

    static func update(problems: [Problem]) {
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let worst = problems.max { ($0.severity, $1.clock) < ($1.severity, $0.clock) }
        let state = ProblemActivityAttributes.ContentState(
            count: problems.count,
            critical: problems.filter { $0.severity >= 4 }.count,
            worst: worst?.name ?? "Проблем нет",
            worstHost: worst?.host ?? "",
            severity: worst?.severity ?? 0,
            since: worst?.clock ?? Date(),
            updated: Date())
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(15 * 60))
        if let a = Activity<ProblemActivityAttributes>.activities.first {
            Task { await a.update(content) }
        } else {
            _ = try? Activity.request(attributes: ProblemActivityAttributes(title: "Zabbix"), content: content, pushType: nil)
        }
    }

    static func stop() {
        for a in Activity<ProblemActivityAttributes>.activities {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }
}

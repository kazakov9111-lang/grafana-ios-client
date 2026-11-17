import SwiftUI

// v2.5: «Беру в работу», резервная копия настроек, имена филиалов.

func branchName(_ n: String) -> String {
    String(n.replacingOccurrences(of: "Mikrotik - ", with: "").prefix(15))
}

// MARK: Беру в работу (хранится только на телефоне)

final class ClaimStore: ObservableObject {
    static let shared = ClaimStore()
    @Published var claims: [String: Date] { didSet { save() } }

    init() {
        if let d = UserDefaults.standard.data(forKey: "claims"),
           let v = try? JSONDecoder().decode([String: Date].self, from: d) {
            claims = v
        } else {
            claims = [:]
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(claims) { UserDefaults.standard.set(d, forKey: "claims") }
    }

    func toggle(_ id: String) {
        if claims[id] != nil { claims[id] = nil }
        else {
            claims[id] = Date()
            if claims.count > 200 {
                let old = claims.sorted { $0.value < $1.value }.prefix(claims.count - 200).map { $0.key }
                old.forEach { claims[$0] = nil }
            }
        }
    }
}

struct ClaimSection: View {
    let problem: Problem
    @ObservedObject private var store = ClaimStore.shared

    var body: some View {
        let at = store.claims[problem.id]
        Section {
            Button {
                let taking = at == nil
                store.toggle(problem.id)
                if taking {
                    Annotations.shared.add(key: "panels", date: Date(), text: "В работе: " + String(problem.name.prefix(36)))
                }
                Haptics.tap()
            } label: {
                if let at {
                    Label("В работе у вас с \(at.formatted(date: .omitted, time: .shortened)) — снять",
                          systemImage: "person.fill.checkmark").foregroundStyle(.orange)
                } else {
                    Label("Взять в работу", systemImage: "person.badge.plus")
                }
            }
        } footer: {
            Text("Отметка хранится только на этом телефоне и в Zabbix не пишется. Чтобы записать её в Zabbix, подтвердите проблему.")
        }
    }
}

// MARK: Резервная копия настроек

struct SettingsBackup: Codable {
    var panels: [CustomPanel]
    var annotations: [Annotation]
    var branches: [Branch]
    var thr: [String: Double]
    var style: String
    var zero: Bool
}

enum BackupIO {
    static func export() -> String {
        var thr: [String: Double] = [:]
        for k in Thr.keys { if let v = UserDefaults.standard.object(forKey: k) as? Double { thr[k] = v } }
        let b = SettingsBackup(panels: CustomPanelStore.shared.items, annotations: Annotations.shared.items,
                               branches: BranchStore.shared.items, thr: thr,
                               style: UserDefaults.standard.string(forKey: "chartStyle") ?? "line",
                               zero: UserDefaults.standard.bool(forKey: "chartZero"))
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return (try? String(data: e.encode(b), encoding: .utf8)) ?? ""
    }

    static func restore(_ s: String) -> Bool {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let data = s.data(using: .utf8), let b = try? d.decode(SettingsBackup.self, from: data) else { return false }
        CustomPanelStore.shared.items = b.panels
        Annotations.shared.items = b.annotations
        BranchStore.shared.items = b.branches
        Thr.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        for (k, v) in b.thr where Thr.keys.contains(k) { UserDefaults.standard.set(v, forKey: k) }
        UserDefaults.standard.set(b.style, forKey: "chartStyle")
        UserDefaults.standard.set(b.zero, forKey: "chartZero")
        return true
    }
}

struct BackupView: View {
    @State private var note: String?
    @State private var confirm = false

    var body: some View {
        Form {
            Section {
                ShareLink(item: BackupIO.export()) { Label("Выгрузить настройки", systemImage: "square.and.arrow.up") }
            } footer: { Text("Мои панели, метки, филиалы на карте, пороги и вид графиков одним текстом. Пароли и токены в выгрузку не попадают.") }
            Section {
                Button { confirm = true } label: { Label("Загрузить из буфера обмена", systemImage: "square.and.arrow.down") }
                if let note { Text(note).font(.caption).foregroundStyle(.orange) }
            } footer: { Text("Скопируйте выгруженный текст на этом или другом телефоне, затем нажмите кнопку. Текущие панели, метки, филиалы и пороги будут заменены.") }
        }
        .navigationTitle("Резервная копия")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Заменить текущие настройки данными из буфера?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Заменить", role: .destructive) {
                note = BackupIO.restore(UIPasteboard.general.string ?? "") ? "Настройки загружены." : "В буфере обмена нет выгрузки настроек."
            }
            Button("Отмена", role: .cancel) {}
        }
    }
}

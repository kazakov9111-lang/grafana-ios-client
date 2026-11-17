import SwiftUI
import CoreLocation

// Список филиалов для карты хранится на телефоне и редактируется в настройках.

struct Branch: Codable, Identifiable, Hashable {
    var id = UUID()
    var host: String   // имя хоста в Zabbix, например «Mikrotik - Piter»
    var city: String   // подпись на карте
    var lat: Double
    var lon: Double
    var hasCoords: Bool { !(lat == 0 && lon == 0) }
}

final class BranchStore: ObservableObject {
    static let shared = BranchStore()
    @Published var items: [Branch] { didSet { save() } }

    init() {
        if let d = UserDefaults.standard.data(forKey: "branches"), let v = try? JSONDecoder().decode([Branch].self, from: d) {
            items = v
        } else {
            items = Launch.demo ? BranchStore.demo : []
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: "branches") }
    }

    static let demo: [Branch] = [
        Branch(host: "Mikrotik - Moscow DC", city: "Москва · ЦОД", lat: 55.7, lon: 37.3),
        Branch(host: "Mikrotik - Moscow", city: "Москва · офис", lat: 55.8, lon: 37.85),
        Branch(host: "Mikrotik - Piter", city: "Санкт-Петербург", lat: 59.94, lon: 30.31),
        Branch(host: "Mikrotik - Nizhny Novgorod", city: "Нижний Новгород", lat: 56.33, lon: 44.0),
        Branch(host: "Mikrotik - Kaliningrad", city: "Калининград", lat: 54.71, lon: 20.51),
        Branch(host: "Mikrotik - Murmansk", city: "Мурманск", lat: 68.97, lon: 33.08),
        Branch(host: "Mikrotik - Voronezh", city: "Воронеж", lat: 51.67, lon: 39.18),
        Branch(host: "Mikrotik - Rostov", city: "Ростов-на-Дону", lat: 47.23, lon: 39.72),
        Branch(host: "Mikrotik - Sochi", city: "Сочи", lat: 43.6, lon: 39.73),
        Branch(host: "Mikrotik - Volgograd", city: "Волгоград", lat: 48.71, lon: 44.51),
        Branch(host: "Mikrotik - Saratov", city: "Саратов", lat: 51.53, lon: 46.03),
        Branch(host: "Mikrotik - Kazan", city: "Казань", lat: 55.79, lon: 49.12),
        Branch(host: "Mikrotik - Samara", city: "Самара", lat: 53.2, lon: 50.15),
        Branch(host: "Mikrotik - Vladivostok", city: "Владивосток", lat: 43.12, lon: 131.89),
        Branch(host: "Mikrotik - Irkutsk", city: "Иркутск", lat: 52.29, lon: 104.3)
    ]
}

enum Branches {
    static var list: [Branch] { BranchStore.shared.items.filter { $0.hasCoords } }
}

/// Координаты по названию города (геокодер iOS, нужен интернет).
func geocodeCity(_ city: String) async -> CLLocationCoordinate2D? {
    let q = city.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return nil }
    let marks = try? await CLGeocoder().geocodeAddressString(q + ", Россия")
    return marks?.first?.location?.coordinate
}

struct BranchEditorView: View {
    @EnvironmentObject var session: Session
    @ObservedObject private var store = BranchStore.shared
    @State private var editing: Branch?
    @State private var adding = false
    @State private var importing = false
    @State private var progress = ""
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Button { Task { await importAll() } } label: {
                    HStack {
                        Label("Добавить все филиалы из Zabbix", systemImage: "square.and.arrow.down")
                        Spacer()
                        if importing { ProgressView() }
                    }
                }
                .disabled(importing)
                if !progress.isEmpty { Text(progress).font(.caption).foregroundStyle(.secondary) }
                if let message { Text(message).font(.caption).foregroundStyle(.orange) }
            } footer: {
                Text("Берёт все хосты группы с маршрутизаторами и ищет координаты по названию. Неточные названия можно поправить вручную: нажмите на строку.")
            }
            Section("Филиалы (\(store.items.count))") {
                if store.items.isEmpty {
                    Text("Список пуст. Добавьте филиалы, и они появятся на карте.").foregroundStyle(.secondary)
                }
                ForEach(store.items) { b in
                    Button { editing = b } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(b.city.isEmpty ? "(без названия)" : b.city).foregroundStyle(.primary)
                                Text(b.host).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if b.hasCoords {
                                Text(String(format: "%.2f, %.2f", b.lat, b.lon)).font(.caption2).foregroundStyle(.secondary)
                            } else {
                                Label("нет координат", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2).foregroundStyle(.orange).labelStyle(.titleAndIcon)
                            }
                        }
                    }
                }
                .onDelete { store.items.remove(atOffsets: $0) }
            }
        }
        .navigationTitle("Филиалы на карте")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button { adding = true } label: { Image(systemName: "plus") } }
        }
        .sheet(item: $editing) { b in
            BranchForm(branch: b) { if let i = store.items.firstIndex(where: { $0.id == b.id }) { store.items[i] = $0 } }
        }
        .sheet(isPresented: $adding) {
            BranchForm(branch: Branch(host: "", city: "", lat: 0, lon: 0)) { store.items.append($0) }
        }
    }

    private func importAll() async {
        importing = true; message = nil
        defer { importing = false; progress = "" }
        guard let net = systemScreens.first(where: { $0.id == "net" }) else { return }
        do {
            let hosts = try await session.matchedHosts(group: net.group, host: "/.*/")
            let known = Set(store.items.map { $0.host })
            let fresh = hosts.filter { !known.contains($0.name) }
            if fresh.isEmpty { message = "Новых хостов нет."; return }
            for (i, h) in fresh.enumerated() {
                progress = "Ищу координаты: \(i + 1) из \(fresh.count)…"
                let city = h.name.components(separatedBy: " - ").last ?? h.name
                let c = await geocodeCity(city)
                store.items.append(Branch(host: h.name, city: city, lat: c?.latitude ?? 0, lon: c?.longitude ?? 0))
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
            let bad = store.items.filter { !$0.hasCoords }.count
            message = bad == 0 ? "Добавлено: \(fresh.count)." : "Добавлено: \(fresh.count). Для \(bad) не нашлись координаты, поправьте названия."
        } catch {
            message = error.localizedDescription
        }
    }
}

struct BranchForm: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State var branch: Branch
    let onSave: (Branch) -> Void
    @State private var searching = false
    @State private var hint: String?
    @State private var zbxHosts: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Хост в Zabbix, например Mikrotik - Piter", text: $branch.host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !zbxHosts.isEmpty {
                        Menu("Выбрать из Zabbix") {
                            ForEach(zbxHosts, id: \.self) { h in Button(h) { branch.host = h } }
                        }
                    }
                } header: { Text("Хост") }
                Section {
                    TextField("Город, например Санкт-Петербург", text: $branch.city)
                    Button {
                        Task {
                            searching = true; hint = nil
                            if let c = await geocodeCity(branch.city) { branch.lat = c.latitude; branch.lon = c.longitude }
                            else { hint = "Город не найден. Уточните название или введите координаты." }
                            searching = false
                        }
                    } label: {
                        HStack { Label("Найти координаты по названию", systemImage: "magnifyingglass"); Spacer(); if searching { ProgressView() } }
                    }
                    if let hint { Text(hint).font(.caption).foregroundStyle(.orange) }
                } header: { Text("Город") }
                Section("Координаты") {
                    LabeledContent("Широта") { TextField("0", value: $branch.lat, format: .number.precision(.fractionLength(0...5))).multilineTextAlignment(.trailing).keyboardType(.numbersAndPunctuation) }
                    LabeledContent("Долгота") { TextField("0", value: $branch.lon, format: .number.precision(.fractionLength(0...5))).multilineTextAlignment(.trailing).keyboardType(.numbersAndPunctuation) }
                }
            }
            .navigationTitle("Филиал")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Сохранить") { onSave(branch); dismiss() }.disabled(branch.host.isEmpty)
                }
            }
            .task {
                guard let net = systemScreens.first(where: { $0.id == "net" }) else { return }
                zbxHosts = ((try? await session.matchedHosts(group: net.group, host: "/.*/")) ?? []).map { $0.name }.sorted()
            }
        }
    }
}

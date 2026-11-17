import SwiftUI

@main
struct GrafanaApp: App {
    @StateObject private var session = Session()
    @StateObject private var lock = AppLock()
    @StateObject private var router = Router()
    @StateObject private var pins = Pins()
    @StateObject private var chartSync = ChartSync()
    @Environment(\.scenePhase) private var phase

    init() { Badge.register() }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                if lock.locked || phase != .active { cover }
            }
            .environmentObject(session)
            .environmentObject(lock)
            .environmentObject(router)
            .environmentObject(pins)
            .environmentObject(chartSync)
            .environment(\.locale, Locale(identifier: "ru_RU"))
            .preferredColorScheme(.dark)
            .onChange(of: phase) { newPhase in
                if newPhase == .background { lock.lockIfNeeded(); Badge.schedule() }
                if newPhase == .active { Task { await lock.unlock() } }
            }
            .task { Badge.session = session; if !Launch.demo { await Badge.requestAccess() }; await lock.unlock() }
        }
    }

    private var cover: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "chart.xyaxis.line").font(.system(size: 54)).foregroundStyle(.orange)
                if lock.locked {
                    Button("Разблокировать") { Task { await lock.unlock() } }
                        .buttonStyle(.borderedProminent).tint(.orange)
                }
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var session: Session

    var body: some View {
        if session.restoring {
            ProgressView("Подключение…")
        } else if session.loggedIn {
            MainTabs()
        } else {
            LoginView()
        }
    }
}

struct MainTabs: View {
    @EnvironmentObject var router: Router

    var body: some View {
        TabView(selection: $router.tab) {
            OverviewView()
                .tabItem { Label("Обзор", systemImage: "gauge.with.dots.needle.67percent") }.tag(0)
            ProblemsView()
                .tabItem { Label("Проблемы", systemImage: "exclamationmark.triangle") }.tag(1)
            SystemsView()
                .tabItem { Label("Системы", systemImage: "square.grid.2x2") }.tag(2)
            PanelsView()
                .tabItem { Label("Панели", systemImage: "chart.xyaxis.line") }.tag(4)
            SettingsView()
                .tabItem { Label("Настройки", systemImage: "gearshape") }.tag(3)
        }
        .tint(.orange)
    }
}

// MARK: Вход

struct LoginView: View {
    @EnvironmentObject var session: Session
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Сервер") {
                    TextField("https://…", text: $session.server)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Section("Учётная запись Grafana") {
                    TextField("Логин", text: $session.user)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Пароль", text: $password)
                }
                if let e = error ?? session.loginError {
                    Section { Text(e).foregroundStyle(.red).font(.footnote) }
                }
                Section {
                    Button {
                        busy = true; error = nil
                        Task {
                            do { try await session.login(user: session.user, password: password) }
                            catch { self.error = error.localizedDescription }
                            busy = false
                        }
                    } label: {
                        HStack { Spacer(); if busy { ProgressView() } else { Text("Войти").bold() }; Spacer() }
                    }
                    .disabled(busy || session.user.isEmpty || password.isEmpty)
                }
            }
            .navigationTitle("Grafana")
        }
    }
}

// MARK: Настройки

struct SettingsView: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var lock: AppLock
    @State private var zbxURL = UserDefaults.standard.string(forKey: "zbxURL") ?? ""
    @State private var zbxToken = Keychain.load(account: "zbxToken") ?? ""
    @State private var showBranches = Launch.screen == "branches"
    @State private var showHealth = Launch.screen == "health"

    var body: some View {
        NavigationStack {
            Form {
                Section("Подключение") {
                    LabeledContent("Сервер", value: session.baseURL).font(.footnote)
                    LabeledContent("Пользователь", value: session.user)
                }
                Section {
                    TextField("Адрес Zabbix, например https://zabbix.company.ru", text: $zbxURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("API-токен Zabbix", text: $zbxToken)
                } header: { Text("Подтверждение проблем") } footer: {
                    Text("Нужно, если пользователь Zabbix в Grafana только читает. Создайте в Zabbix токен для учётки с правом подтверждать проблемы. Пусто — подтверждение идёт через Grafana.")
                }
                Section {
                    NavigationLink { BranchEditorView() } label: {
                        Label("Филиалы на карте", systemImage: "map")
                    }
                } footer: { Text("Города для карты филиалов: добавьте все свои вручную или одной кнопкой из Zabbix.") }
                Section("Панели и графики") {
                    NavigationLink { ThresholdsView() } label: { Label("Свои пороги", systemImage: "slider.horizontal.3") }
                    NavigationLink { AnnotationsListView() } label: { Label("Мои метки на графиках", systemImage: "pin") }
                    NavigationLink { BackupView() } label: { Label("Резервная копия настроек", systemImage: "externaldrive") }
                    NavigationLink { HostThresholdsView() } label: { Label("Пороги по хостам", systemImage: "server.rack") }
                    NavigationLink { HealthView() } label: { Label("Здоровье приложения", systemImage: "heart.text.square") }
                }
                Section("Безопасность") {
                    Toggle(isOn: $lock.enabled) { Label("Блокировка Face ID", systemImage: "faceid") }
                }
                Section {
                    Button("Выйти", role: .destructive) { session.logout() }
                }
                Section { Text("Версия 2.6").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("Настройки")
            .navigationDestination(isPresented: $showBranches) { BranchEditorView() }
            .navigationDestination(isPresented: $showHealth) { HealthView() }
            .onChange(of: zbxURL) { UserDefaults.standard.set($0, forKey: "zbxURL") }
            .onChange(of: zbxToken) { Keychain.save($0, account: "zbxToken") }
        }
    }
}

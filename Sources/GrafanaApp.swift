import CoreSpotlight
import SwiftUI

@main
struct GrafanaApp: App {
    @StateObject private var session = Session()
    @StateObject private var lock = AppLock()
    @StateObject private var router = Router()
    @StateObject private var pins = Pins()
    @StateObject private var chartSync = ChartSync()
    @Environment(\.scenePhase) private var phase

    init() { Badge.register(); NotifActions.register(); MetricsSink.start() }

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
                if newPhase == .active { lock.checkTimeout(); Task { await lock.unlock() } }
            }
            .task {
                Badge.session = session
                if !Launch.demo { await Badge.requestAccess(); SignInfo.scheduleReminder() }
                await lock.unlock()
            }
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
    @EnvironmentObject var session: Session
    @ObservedObject private var link = DeepLink.shared

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
        .sheet(item: $link.host) { h in
            NavigationStack {
                HostExplorerView(host: h)
                    .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { link.host = nil } } }
            }
        }
        .sheet(item: $link.problem) { r in
            ProblemLinkView(eventId: r.id) { link.problem = nil }
        }
        .onOpenURL { url in
            if url.scheme == "grafanaapp", url.host == "problems" { router.tab = 1 } else { DeepLink.shared.open(url: url) }
        }
        .task {
            await session.indexSpotlight()
            await session.syncAnnotations()
        }
        .onContinueUserActivity(CSSearchableItemActionType) { a in
            if let id = a.userInfo?[CSSearchableItemActivityIdentifier] as? String { DeepLink.shared.openSpotlight(id) }
        }
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
    @State private var showQR = Launch.screen == "qr"
    @State private var showScan = false
    @AppStorage("liveActivity") private var liveActivity = false
    @AppStorage("glassCards") private var glassCards = false
    @AppStorage("notifyNew") private var notifyNew = true
    @AppStorage("faceIdWrites") private var faceIdWrites = true
    @AppStorage("annoToGrafana") private var annoToGrafana = true
    @AppStorage("pushMetrics") private var pushMetrics = false
    @AppStorage("foldDeps") private var foldDeps = true

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
                Section {
                    Button { showScan = true } label: { Label("Сканировать QR на сервере", systemImage: "qrcode.viewfinder") }
                    Button { showQR = true } label: { Label("Напечатать QR-наклейки", systemImage: "printer") }
                } header: { Text("В серверной") } footer: {
                    Text("Наклейка на стойке открывает карточку хоста: метрики, проблемы, плановые работы и скрипты. Подойдёт и обычная камера iPhone.")
                }
                Section {
                    Toggle(isOn: $notifyNew) { Label("Уведомлять о новых высоких", systemImage: "bell.badge") }
                    Toggle(isOn: $liveActivity) { Label("Проблемы на экране блокировки", systemImage: "platter.filled.bottom.iphone") }
                    Toggle(isOn: $glassCards) { Label("Стеклянные карточки", systemImage: "square.on.square.intersection.dashed") }
                } header: { Text("Оформление") } footer: {
                    Text("Экран блокировки и Dynamic Island показывают число проблем и самую серьёзную. Обновляется, пока приложение запущено или в фоне (без push-сервера). Стекло — только на iOS 26. Уведомления о новых высоких проблемах приходят при фоновом обновлении (iOS запускает его сама, раз в 15–60 минут); если их нет — включите баннеры в Настройках iOS → Grafana → Уведомления.")
                }
                Section {
                    Toggle(isOn: $lock.enabled) { Label("Блокировка Face ID", systemImage: "faceid") }
                    if lock.enabled {
                        Picker(selection: $lock.timeout) {
                            Text("Сразу").tag(0); Text("Через 1 мин").tag(1); Text("Через 5 мин").tag(5); Text("Через 15 мин").tag(15)
                        } label: { Label("Блокировать в фоне", systemImage: "timer") }
                    }
                    Toggle(isOn: $faceIdWrites) { Label("Face ID перед изменениями в Zabbix", systemImage: "lock.shield") }
                } header: { Text("Безопасность") } footer: {
                    Text("Закрыть, отложить, сменить важность, массово подтвердить, обслуживание и скрипты — только после Face ID.")
                }
                Section {
                    NavigationLink { QuietHoursView() } label: { Label("Тихие часы", systemImage: "moon.zzz") }
                    NavigationLink { ProfilesView() } label: { Label("Профили серверов", systemImage: "server.rack") }
                    NavigationLink { NtfySetupView() } label: { Label("Мгновенные уведомления (ntfy)", systemImage: "bell.and.waves.left.and.right") }
                    Toggle(isOn: $annoToGrafana) { Label("Метки ↔ аннотации Grafana", systemImage: "pin.circle") }
                    Toggle(isOn: $foldDeps) { Label("Сворачивать зависимые проблемы", systemImage: "arrow.turn.down.right") }
                    Toggle(isOn: $pushMetrics) { Label("Метрики приложения в Zabbix", systemImage: "arrow.up.doc") }
                } header: { Text("Связь с Zabbix и Grafana") } footer: {
                    Text("Метки с графиков уходят в Grafana с тегом mobile-app, а аннотации из Grafana видны на графиках здесь. Зависимости задаются в карточке хоста. Метрики приложения (задержка, ошибки, время до подтверждения) отправляются в хост «mobile-app» через history.push — сначала на сервере нужен такой хост с элементами-ловушками.")
                }
                Section {
                    Button("Выйти", role: .destructive) { session.logout() }
                }
                Section { Text("Версия 3.0" + (SignInfo.expiry.map { " · подпись до " + ruDate($0) } ?? "")).font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("Настройки")
            .navigationDestination(isPresented: $showBranches) { BranchEditorView() }
            .navigationDestination(isPresented: $showHealth) { HealthView() }
            .sheet(isPresented: $showQR) { QRStickerSheet() }
            .fullScreenCover(isPresented: $showScan) { QRScanSheet() }
            .onChange(of: liveActivity) { on in
                if on { Task { if let p = try? await session.loadProblems() { LiveStatus.update(problems: p) } } }
                else { LiveStatus.stop() }
            }
            .onChange(of: zbxURL) { UserDefaults.standard.set($0, forKey: "zbxURL") }
            .onChange(of: zbxToken) { Keychain.save($0, account: "zbxToken") }
        }
    }
}

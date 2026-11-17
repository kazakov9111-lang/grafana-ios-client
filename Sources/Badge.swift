import Foundation
import UserNotifications
import BackgroundTasks

/// Число открытых проблем на иконке приложения (без push: обновляется при открытии
/// и по фоновому обновлению, которое iOS запускает сама, примерно раз в 15–60 минут).
enum Badge {
    static let taskId = "com.personal.grafana.refresh"
    @MainActor static weak var session: Session?

    static func count(_ ps: [Problem]) -> Int { ps.filter { $0.severity >= 3 && !$0.acked }.count }

    static func requestAccess() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.badge])
    }

    static func set(_ n: Int) {
        UNUserNotificationCenter.current().setBadgeCount(n) { _ in }
    }

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
            schedule()
            let work = Task {
                let s = await MainActor.run { session ?? Session() }
                if await MainActor.run(body: { !s.loggedIn }) { await s.restore() }
                if let ps = try? await s.loadProblems() { set(count(ps)) }
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let r = BGAppRefreshTaskRequest(identifier: taskId)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }
}

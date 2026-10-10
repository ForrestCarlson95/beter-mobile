import SwiftUI
import BackgroundTasks
import UserNotifications

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

@main
struct BETERApp: App {
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var phase
    private let notificationDelegate = NotificationDelegate()
    static let refreshID = "com.forrest.betermobile.refresh"

    init() {
        UNUserNotificationCenter.current().delegate = notificationDelegate
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshID, using: nil) { task in
            Self.handleRefresh(task as! BGAppRefreshTask)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onAppear { model.start() }
                .onOpenURL { url in model.pendingPairURL = url }
        }
        .onChange(of: phase) { _, p in
            model.foreground = (p == .active)
            if p == .active { model.poke() }
            if p == .background { Self.scheduleRefresh() }
        }
    }

    /// iOS decides when this runs (usually every so often while the phone is idle); it catches up with the PC and shows any
    /// notifications. A suspended app cannot keep a live connection, so this is how alerts arrive without a push service.
    static func scheduleRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: refreshID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    static func handleRefresh(_ task: BGAppRefreshTask) {
        scheduleRefresh()
        let work = Task { @MainActor in
            AppModel.shared.start()
            for _ in 0..<20 where AppModel.shared.tailnet != .running {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            _ = try? await AppModel.shared.syncOnce(wait: 0)
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }
}

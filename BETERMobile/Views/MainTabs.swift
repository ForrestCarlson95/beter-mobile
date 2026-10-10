import SwiftUI
import UIKit

struct MainTabs: View {
    @EnvironmentObject var model: AppModel

    var pendingApprovals: Int { model.s.approvals.values.filter { $0.status == "pending" }.count }

    var body: some View {
        TabView {
            ChatsView().tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            TasksView().tabItem { Label("Tasks", systemImage: "checklist") }
            ApprovalsView().tabItem { Label("Approvals", systemImage: "checkmark.seal") }
                .badge(pendingApprovals)
            PCView().tabItem { Label("PC", systemImage: "desktopcomputer") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

/// One line that always says how current the phone is - never "up to date" while something is unacknowledged.
struct SyncBadge: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let open = model.s.ops.filter(\.isOpen).count
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(model.status.rawValue + (open > 0 ? " · \(open) waiting to send" : ""))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    var color: Color {
        switch model.status {
        case .upToDate: return .green
        case .synchronizing, .connecting: return .orange
        case .offline, .notPaired: return .gray
        case .failed, .updateRequired: return .red
        }
    }
}

struct NeedsUpdateView: View {
    let feature: String
    var body: some View {
        ContentUnavailableView("Needs a newer app", systemImage: "arrow.down.app",
                               description: Text("Your PC has \(feature), but this version of the app can't show it yet. Install the newest build."))
    }
}

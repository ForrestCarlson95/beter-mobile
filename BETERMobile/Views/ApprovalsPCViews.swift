import SwiftUI
import UIKit
import Combine

struct ApprovalsView: View {
    @EnvironmentObject var model: AppModel

    var pending: [Approval] { model.s.approvals.values.filter { $0.status == "pending" }.sorted { $0.id > $1.id } }
    var recent: [Approval] { model.s.approvals.values.filter { $0.status != "pending" }.sorted { $0.id > $1.id }.prefix(20).map { $0 } }

    var body: some View {
        NavigationStack {
            Group {
                if !model.can("approvals") { NeedsUpdateView(feature: "approvals") } else {
                    List {
                        Section("Waiting for you") {
                            if pending.isEmpty { Text("Nothing to approve.").foregroundStyle(.secondary) }
                            ForEach(pending) { a in NavigationLink(value: a.id) { ApprovalRow(a: a) } }
                        }
                        if !recent.isEmpty {
                            Section("Decided") { ForEach(recent) { a in ApprovalRow(a: a) } }
                        }
                    }
                }
            }
            .navigationTitle("Approvals")
            .navigationDestination(for: Int.self) { ApprovalDetail(approvalId: $0) }
        }
    }
}

struct ApprovalRow: View {
    let a: Approval
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { Text("#\(a.id)").font(.caption.monospaced()).foregroundStyle(.secondary); StatusChip(status: a.status) }
            Text(a.kind.replacingOccurrences(of: "_", with: " ").capitalized).font(.headline)
            Text(a.detail.pretty.prefix(140)).font(.caption).foregroundStyle(.secondary).lineLimit(3)
        }
    }
}

struct ApprovalDetail: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let approvalId: Int
    @State private var feedback = ""
    @State private var busy = false
    @State private var error: String?

    var a: Approval? { model.s.approvals[approvalId] }

    var body: some View {
        Form {
            if let a {
                Section(a.kind.replacingOccurrences(of: "_", with: " ").capitalized) {
                    Text(a.detail.pretty).font(.footnote.monospaced()).textSelection(.enabled)
                }
                if a.status == "pending" {
                    Section {
                        TextField("Note for B.E.T.E.R. (optional)", text: $feedback, axis: .vertical)
                        Button { Task { await decide(a, true) } } label: { Label("Approve", systemImage: "checkmark.circle.fill") }
                            .disabled(busy)
                        Button(role: .destructive) { Task { await decide(a, false) } } label: { Label("Decline", systemImage: "xmark.circle") }
                            .disabled(busy)
                    } footer: {
                        Text("Your PC checks that this is exactly what you are looking at; if it changed meanwhile, it asks again.")
                    }
                } else {
                    Section { StatusChip(status: a.status) }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
        }
        .navigationTitle("Approval #\(approvalId)")
    }

    private func decide(_ a: Approval, _ yes: Bool) async {
        busy = true
        do {
            try await model.decide(a, approve: yes, feedback: feedback)
            dismiss()
        } catch {
            self.error = "Approving needs a connection to your PC (to check it is unchanged). " +
                ((error as? LocalizedError)?.errorDescription ?? "")
        }
        busy = false
    }
}

/// Live state of the PC. Shows when the numbers were taken; nothing is queued while offline.
struct PCView: View {
    @EnvironmentObject var model: AppModel
    @State private var timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var t: JSON { model.telemetry }
    var fresh: Bool { Date().timeIntervalSince1970 - model.telemetryTime < 20 }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Circle().fill(fresh ? .green : .gray).frame(width: 8, height: 8)
                        Text(fresh ? "Live" : (model.telemetryTime > 0 ? "Last seen " : "No data yet")).font(.caption)
                        if !fresh && model.telemetryTime > 0 {
                            Text(Date(timeIntervalSince1970: model.telemetryTime), style: .relative).font(.caption)
                        }
                    }
                }
                Section("Computer") {
                    meter("CPU", t["cpu_pct"].double, unit: "%")
                    meter("RAM", t["ram_pct"].double, unit: "%", extra: "\(t["ram_used_gb"].str) / \(t["ram_total_gb"].str) GB")
                    meter("GPU", t["gpu"]["util_pct"].double, unit: "%", extra: t["gpu"]["name"].string)
                    if let used = t["gpu"]["vram_used_mb"].double, let total = t["gpu"]["vram_total_mb"].double, total > 0 {
                        meter("VRAM", used / total * 100, unit: "%", extra: String(format: "%.1f / %.1f GB", used / 1024, total / 1024))
                    }
                    LabeledContent("Free disk", value: "\(t["disk_free_gb"].str) GB")
                    LabeledContent("B.E.T.E.R. storage", value: "\(t["beter_storage_gb"].str) GB")
                }
                Section("B.E.T.E.R.") {
                    LabeledContent("Workers", value: t["health"]["worker"].str)
                    LabeledContent("Version", value: "\(t["health"]["version"].str) (\(t["health"]["commit"].str.prefix(7)))")
                    if let up = t["health"]["uptime_s"].double { LabeledContent("Up for", value: Duration.seconds(up).formatted(.units(allowed: [.hours, .minutes]))) }
                    LabeledContent("Models loaded", value: t["models_loaded"].array.map(\.str).joined(separator: ", ").isEmpty ? "none" :
                                    t["models_loaded"].array.map(\.str).joined(separator: ", "))
                }
                Section("Active tasks") {
                    let active = t["tasks_active"].array
                    if active.isEmpty { Text("None").foregroundStyle(.secondary) }
                    ForEach(Array(active.enumerated()), id: \.offset) { _, x in
                        HStack { Text("#\(x["id"].str)").monospaced(); StatusChip(status: x["status"].str); Text(x["title"].str).lineLimit(1) }
                    }
                }
                Section("Connection") {
                    LabeledContent("Remote Access", value: model.tailnet == .running ? "Connected" : "Offline")
                    LabeledContent("PC", value: model.s.host)
                }
            }
            .navigationTitle("Your PC")
            .refreshable { await model.refreshTelemetry() }
            .task { await model.refreshTelemetry() }
            .onReceive(timer) { _ in
                if model.foreground && model.can("telemetry") { Task { await model.refreshTelemetry() } }
            }
        }
    }

    @ViewBuilder
    private func meter(_ name: String, _ v: Double?, unit: String, extra: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                Spacer()
                Text(v.map { String(format: "%.0f\(unit)", $0) } ?? "-").monospacedDigit()
            }
            if let v { ProgressView(value: min(max(v, 0), 100), total: 100) }
            if let extra, !extra.isEmpty { Text(extra).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

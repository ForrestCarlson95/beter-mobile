import SwiftUI
import UIKit

struct TasksView: View {
    @EnvironmentObject var model: AppModel
    @State private var showAll = false
    @State private var creating = false

    var tasks: [TaskItem] {
        model.s.tasks.values.filter { showAll || $0.isActive }.sorted { ($0.isActive ? 1 : 0, $0.id) > ($1.isActive ? 1 : 0, $1.id) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !model.can("tasks") { NeedsUpdateView(feature: "tasks") } else {
                    List {
                        Section { SyncBadge() }
                        Picker("Show", selection: $showAll) {
                            Text("Active").tag(false)
                            Text("All").tag(true)
                        }.pickerStyle(.segmented)
                        ForEach(tasks) { t in
                            NavigationLink(value: t.id) { TaskRow(t: t) }
                        }
                        if tasks.isEmpty { Text(showAll ? "No tasks yet." : "Nothing running.").foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle("Tasks")
            .navigationDestination(for: Int.self) { TaskDetailView(taskId: $0) }
            .toolbar { Button { creating = true } label: { Image(systemName: "plus") } }
            .sheet(isPresented: $creating) { NewTaskSheet() }
        }
    }
}

struct StatusChip: View {
    let status: String
    var color: Color {
        switch status {
        case "running": return .blue
        case "queued": return .gray
        case "waiting_approval": return .orange
        case "done": return .green
        case "failed", "blocked": return .red
        case "paused": return .yellow
        default: return .secondary
        }
    }
    var body: some View {
        Text(status.replacingOccurrences(of: "_", with: " ")).font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule()).foregroundStyle(color)
    }
}

struct TaskRow: View {
    let t: TaskItem
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("#\(t.id)").font(.caption.monospaced()).foregroundStyle(.secondary)
                StatusChip(status: t.status)
                if !t.stage.isEmpty { Text(t.stage).font(.caption2).foregroundStyle(.secondary) }
            }
            Text(t.title).lineLimit(2)
        }
    }
}

struct TaskDetailView: View {
    @EnvironmentObject var model: AppModel
    let taskId: Int
    @State private var events: [JSON] = []
    @State private var loadingLog = false
    @State private var logError: String?

    var t: TaskItem? { model.s.tasks[taskId] }

    var body: some View {
        List {
            if let t {
                Section {
                    Text(t.title).font(.headline)
                    HStack { StatusChip(status: t.status); Text(t.stage).foregroundStyle(.secondary) }
                    if !t.result.isEmpty { Text(t.result).font(.callout) }
                    Stepper("Priority \(t.priority)", value: Binding(get: { t.priority }, set: { v in
                        model.enqueue("task.priority", ["id": .number(Double(t.id)), "priority": .number(Double(v))], summary: "priority #\(t.id)")
                    }), in: 0...100, step: 10)
                }
                Section("Control") {
                    if ["queued", "running", "waiting_approval"].contains(t.status) { action("Pause", "pause.fill", "task.pause") }
                    if t.status == "paused" { action("Resume", "play.fill", "task.resume") }
                    if ["failed", "cancelled", "paused", "blocked", "waiting_approval"].contains(t.status) { action("Retry", "arrow.clockwise", "task.retry") }
                    if !["done", "cancelled"].contains(t.status) { action("Cancel", "xmark.circle", "task.cancel", role: .destructive) }
                    ForEach(model.s.ops.filter { $0.args["id"].int == t.id && $0.kind.hasPrefix("task.") }.suffix(3)) { op in
                        Text("\(op.kind.replacingOccurrences(of: "task.", with: "")): \(op.state)\(op.error.map { " - \($0)" } ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Log") {
                    if !model.can("task_log") { Text("Needs a newer app.").foregroundStyle(.secondary) }
                    if loadingLog { ProgressView() }
                    if let logError { Text(logError).foregroundStyle(.secondary).font(.caption) }
                    ForEach(Array(events.suffix(150).reversed().enumerated()), id: \.offset) { _, e in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(e["type"].str).font(.caption.bold())
                                Spacer()
                                Text(Date(timeIntervalSince1970: e["ts"].double ?? 0), style: .time).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(e["data"].pretty.prefix(600)).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(8)
                        }
                    }
                }
            } else {
                Text("Task not found")
            }
        }
        .navigationTitle("Task #\(taskId)")
        .refreshable { await loadLog() }
        .task { await loadLog() }
    }

    private func action(_ title: String, _ icon: String, _ kind: String, role: ButtonRole? = nil) -> some View {
        Button(role: role) {
            model.enqueue(kind, ["id": .number(Double(taskId))], summary: "\(title) #\(taskId)")
        } label: { Label(title, systemImage: icon) }
    }

    private func loadLog() async {
        loadingLog = true
        do {
            events = try await model.get("/m/v1/tasks/\(taskId)/events?after=0&limit=300").array
            logError = nil
        } catch {
            logError = "Log needs a connection to your PC."
        }
        loadingLog = false
    }
}

struct NewTaskSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var details = ""
    @State private var priority = 50.0

    var body: some View {
        NavigationStack {
            Form {
                TextField("What should B.E.T.E.R. do?", text: $title)
                TextField("Details (optional)", text: $details, axis: .vertical).lineLimit(3...10)
                VStack(alignment: .leading) {
                    Text("Priority \(Int(priority))")
                    Slider(value: $priority, in: 0...100, step: 5)
                }
                Text("Self-development tasks change B.E.T.E.R. itself; nothing is integrated until you approve it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("New task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        model.enqueue("task.create", ["title": .string(title), "description": .string(details.isEmpty ? title : details),
                                                      "priority": .number(priority)], summary: title)
                        dismiss()
                    }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

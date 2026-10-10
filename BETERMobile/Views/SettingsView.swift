import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmDisconnect = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Synchronization") {
                    LabeledContent("Status", value: model.status.rawValue)
                    LabeledContent("Last sync", value: model.s.lastSync > 0
                                   ? Date(timeIntervalSince1970: model.s.lastSync).formatted(date: .abbreviated, time: .standard) : "never")
                    LabeledContent("Applied / acknowledged", value: "\(model.s.seq) / \(model.s.ackedSeq)")
                    LabeledContent("Waiting to send", value: "\(model.s.ops.filter(\.isOpen).count)")
                    if let e = model.lastError { Text(e).font(.caption).foregroundStyle(.red) }
                    Button("Retry now") { model.retryNow() }
                    NavigationLink("Recent actions") { OpsView() }
                }
                Section("Remote Access") {
                    LabeledContent("Status", value: model.tailnet == .running ? "Connected" : model.tailnet == .needsLogin ? "Sign-in needed" : "Connecting")
                    LabeledContent("PC", value: model.s.host)
                    if let e = model.tailnetError { Text(e).font(.caption).foregroundStyle(.secondary) }
                    NavigationLink("Connection diagnostics") { DiagnosticsView() }
                }
                if model.can("settings") { BeterSettingsSection() }
                if model.can("personality") && !model.s.profiles.isEmpty { PersonalitySection() }
                Section("Your PC") {
                    if model.can("models") { NavigationLink("Models") { ModelsView() } }
                    if model.can("memory") { NavigationLink("What B.E.T.E.R. remembers") { MemoryView() } }
                    NavigationLink("Notifications (\(model.s.notifications.filter { !$0.read }.count) new)") { NotificationsView() }
                    NavigationLink("Features") { FeaturesView() }
                }
                Section("About") {
                    LabeledContent("App", value: BeterAPI.appVersion)
                    LabeledContent("PC", value: "\(model.s.desktop["desktop_version"].string ?? "?") \(model.s.desktop["commit"].str.prefix(7))")
                    LabeledContent("Phone API", value: model.s.desktop["api"].string ?? "1.0")
                    Text("Private networking by TailscaleKit / libtailscale (BSD-3-Clause, © Tailscale Inc & AUTHORS), running inside this app only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("Disconnect this phone", role: .destructive) { confirmDisconnect = true }
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Disconnect from your PC? You can pair again later.", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { model.unpair() }
            }
        }
    }
}

struct BeterSettingsSection: View {
    @EnvironmentObject var model: AppModel

    func value(_ k: String) -> JSON { model.pendingSetting(k) ?? model.s.settings[k] ?? .null }
    func pending(_ k: String) -> Bool { model.pendingSetting(k) != nil }

    var body: some View {
        Section {
            toggle("Autonomous mode", "autonomous")
            toggle("Long-term memory", "long_memory")
            toggle("PC notifications", "notifications")
            picker("Effort", "effort", ["low", "medium", "high"])
            picker("Quality", "quality_level", ["fast", "balanced", "thorough", "maximum"])
            picker("QA", "qa_level", ["minimal", "balanced", "thorough", "maximum"])
            VStack(alignment: .leading) {
                Text("PC resources: \(value("resource_percent").int ?? 100)%" + (pending("resource_percent") ? " (pending)" : ""))
                Slider(value: Binding(get: { Double(value("resource_percent").int ?? 100) },
                                      set: { model.setSetting("resource_percent", .number($0.rounded())) }), in: 10...100, step: 10)
            }
        } header: {
            Text("B.E.T.E.R.")
        } footer: {
            Text("Changes are applied on the PC; \"pending\" means your PC has not confirmed them yet. If the setting changed on the PC meanwhile, the PC's value wins.")
        }
    }

    func toggle(_ title: String, _ k: String) -> some View {
        Toggle(isOn: Binding(get: { value(k).bool ?? false }, set: { model.setSetting(k, .bool($0)) })) {
            Text(title + (pending(k) ? " (pending)" : ""))
        }
    }

    func picker(_ title: String, _ k: String, _ options: [String]) -> some View {
        Picker(title + (pending(k) ? " (pending)" : ""), selection: Binding(get: { value(k).str }, set: { model.setSetting(k, .string($0)) })) {
            ForEach(options, id: \.self) { Text($0.capitalized).tag($0) }
        }
    }
}

struct PersonalitySection: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Section("Personality") {
            Picker("Profile", selection: Binding(get: { model.s.profileScopes["global"] ?? "" }, set: { pid in
                model.enqueue("personality.select", ["scope": "global", "profile_id": .number(Double(Int(pid) ?? 0))], summary: "personality")
            })) {
                ForEach(model.s.profiles.values.sorted { $0.id < $1.id }) { p in Text(p.name).tag(p.id) }
            }
        }
    }
}

struct ModelsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List {
            Section("Used for") {
                ForEach(model.s.roleModels.keys.sorted(), id: \.self) { r in LabeledContent(r, value: model.s.roleModels[r] ?? "") }
            }
            Section("Installed") {
                ForEach(model.s.models.values.sorted { $0.id < $1.id }) { m in
                    VStack(alignment: .leading) {
                        Text(m.name)
                        Text(m.extra["status"].str).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.navigationTitle("Models")
    }
}

struct MemoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var q = ""
    var body: some View {
        List(model.s.facts.values.filter { q.isEmpty || $0.text.localizedCaseInsensitiveContains(q) }.sorted { $0.id > $1.id }) { f in
            VStack(alignment: .leading) {
                Text(f.text)
                Text(f.kind).font(.caption).foregroundStyle(.secondary)
            }
        }
        .searchable(text: $q)
        .navigationTitle("Memory")
    }
}

struct NotificationsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List(model.s.notifications) { n in
            VStack(alignment: .leading, spacing: 2) {
                Text(n.title).font(.headline)
                Text(n.body).font(.callout)
                Text(Date(timeIntervalSince1970: n.ts), style: .relative).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Notifications")
        .onAppear { model.markNotificationsRead() }
    }
}

struct FeaturesView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List(model.s.features) { f in
            HStack {
                Text(f.title)
                Spacer()
                Text(f.planned ? "coming" : f.available ? "available" : f.needsAppUpdate ? "needs newer app" : "off")
                    .font(.caption).foregroundStyle(f.available ? .green : .secondary)
            }
        }
        .navigationTitle("Features")
    }
}

struct OpsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List(Array(model.s.ops.reversed())) { op in
            VStack(alignment: .leading, spacing: 2) {
                HStack { Text(op.kind).font(.caption.monospaced()); Spacer(); Text(op.state).font(.caption.bold()) }
                if !op.summary.isEmpty { Text(op.summary).font(.caption) }
                if let e = op.error { Text(e).font(.caption2).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Recent actions")
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject var model: AppModel
    @State private var hello: String = ""
    var body: some View {
        Form {
            LabeledContent("Network", value: "\(model.tailnet)")
            LabeledContent("PC address", value: model.s.host)
            LabeledContent("Device id", value: model.s.deviceId)
            LabeledContent("Journal head (PC)", value: "\(model.s.head)")
            LabeledContent("Applied", value: "\(model.s.seq)")
            LabeledContent("Acknowledged", value: "\(model.s.ackedSeq)")
            if let e = model.tailnetError { Text("Network: \(e)").font(.caption) }
            if let e = model.lastError { Text("Sync: \(e)").font(.caption) }
            Button("Test connection") {
                Task {
                    do { hello = try await model.get("/m/v1/hello").pretty } catch { hello = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
                }
            }
            if !hello.isEmpty { Text(hello).font(.caption.monospaced()) }
            Button("Sign out of the private network", role: .destructive) { Task { await Tailnet.shared.logout() } }
        }
        .navigationTitle("Diagnostics")
    }
}

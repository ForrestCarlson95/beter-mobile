import Foundation
import SwiftUI
import UIKit
import UserNotifications

enum SyncStatus: String {
    case notPaired = "Not paired"
    case connecting = "Connecting"
    case synchronizing = "Synchronizing"
    case upToDate = "Up to date"
    case offline = "Offline"
    case updateRequired = "Update required"
    case failed = "Synchronization failed"
}

/// The phone's single source of truth: state on disk, the sync loop with the PC, and the queue of actions to send.
///
/// Sync protocol (PC: beter/mobile.py): GET /m/v1/sync?since=<seq> returns the journal events after seq (or a full snapshot when
/// the phone was away longer than the PC keeps history). Events are applied in order and SAVED, then acknowledged - the PC
/// knows exactly what the phone has applied, and keeps everything else until it is acknowledged.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var s = AppState()
    @Published var status: SyncStatus = .notPaired
    @Published var lastError: String?
    @Published var tailnet: TailnetState = .stopped
    @Published var loginURL: String?
    @Published var tailnetError: String?
    @Published var telemetry: JSON = .null
    @Published var telemetryTime: Double = 0
    @Published var foreground = true
    @Published var pendingPairURL: URL?

    private var token: String? { didSet { Keychain.set(token, for: "device-token") } }
    private var loopTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var wake = AsyncStream<Void>.makeStream()
    private let api = BeterAPI.shared

    var paired: Bool { token != nil && !s.host.isEmpty }

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("beter-state.json")
    }

    init() {
        token = Keychain.get("device-token")
        if let d = try? Data(contentsOf: Self.fileURL), let st = try? JSONDecoder().decode(AppState.self, from: d) {
            s = st
        }
        status = paired ? .connecting : .notPaired
    }

    // MARK: - lifecycle

    func start() {
        Task {
            _ = await Tailnet.shared.observe { st, url, err in
                Task { @MainActor in
                    AppModel.shared.tailnet = st
                    AppModel.shared.loginURL = url
                    AppModel.shared.tailnetError = err
                    if st == .running { AppModel.shared.poke() }
                }
            }
            await Tailnet.shared.start()
        }
        if loopTask == nil {
            loopTask = Task { await self.loop() }
        }
    }

    /// Wake the sync loop now (new op queued, app came to the foreground, network came back).
    func poke() { wake.continuation.yield() }

    private func sleep(_ seconds: Double) async {
        await withTaskGroup(of: Void.self) { g in
            g.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
            g.addTask { [stream = wake.stream] in for await _ in stream { break } }
            await g.next()
            g.cancelAll()
        }
    }

    private func loop() async {
        var backoff = 2.0
        while !Task.isCancelled {
            guard paired else { status = .notPaired; await sleep(30); continue }
            guard tailnet == .running else { status = .connecting; await sleep(5); continue }
            do {
                try await flushOps()
                let more = try await syncOnce(wait: foreground ? 25 : 0)
                backoff = 2
                if !more && !foreground { await sleep(60) }
            } catch APIError.unauthorized {
                unpair(reason: "This phone was removed on the PC. Pair again.")
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                status = (error as? APIError)?.isNetwork == true ? .offline : .failed
                await sleep(backoff)
                backoff = min(backoff * 2, 60)
            }
        }
    }

    /// One sync round (also used by background refresh). Returns true when the PC has more to send.
    @discardableResult
    func syncOnce(wait: Double = 0) async throws -> Bool {
        guard let token else { throw APIError.unauthorized }
        if status != .upToDate { status = .synchronizing }
        let r = try await api.request("GET", "/m/v1/sync?since=\(s.seq)&limit=500&wait=\(Int(wait))", host: s.host,
                                      token: token, timeout: wait + 30)
        if r["reset"].bool == true {
            applySnapshot(r["snapshot"])
        } else {
            for e in r["events"].array { apply(e) }
            if let seq = r["seq"].int { s.seq = max(s.seq, seq) }
        }
        s.head = r["head"].int ?? r["seq"].int ?? s.head
        s.lastSync = Date().timeIntervalSince1970
        saveNow()                                            // applied AND saved -> only now acknowledge
        if s.ackedSeq != s.seq {
            let a = try await api.request("POST", "/m/v1/ack", host: s.host, body: ["seq": .number(Double(s.seq))], token: token)
            s.ackedSeq = a["acked"].int ?? s.seq
            saveSoon()
        }
        lastError = nil
        let needUpdate = s.features.contains { $0.needsAppUpdate } && isOlder(BeterAPI.appVersion, than: s.requiredClient)
        let more = r["more"].bool == true
        status = needUpdate ? .updateRequired : (more ? .synchronizing : .upToDate)
        return more
    }

    func retryNow() {
        lastError = nil
        Task { await BeterAPI.shared.reset() }
        poke()
    }

    // MARK: - applying the PC's changes

    private func applySnapshot(_ snap: JSON) {
        var n = AppState()
        n.host = s.host
        n.deviceId = s.deviceId
        n.ops = s.ops
        n.notifications = s.notifications
        for c in snap["conversations"].array {
            let id = c["conv_id"].str
            var conv = Conversation(id: id, title: c["title"].str, projectId: c["project_id"].int, created: c["created"].double ?? 0)
            conv.messages = c["messages"].array.compactMap(Self.message)
            conv.complete = c["complete"].bool ?? true
            n.conversations[id] = conv
        }
        // keep messages the phone wrote that the PC has not confirmed yet
        for conv in s.conversations.values {
            for m in conv.messages where m.pending {
                if n.conversations[conv.id] == nil { n.conversations[conv.id] = Conversation(id: conv.id, title: conv.title, created: conv.created) }
                n.conversations[conv.id]?.messages.append(m)
            }
        }
        for t in snap["tasks"].array { if let x = TaskItem.from(t) { n.tasks[x.id] = x } }
        for a in snap["approvals"].array { if let x = Approval.from(a) { n.approvals[x.id] = x } }
        for p in snap["projects"].array { n.projects[p["id"].str] = Named(id: p["id"].str, name: p["name"].str, extra: p) }
        for p in snap["profiles"].array { n.profiles[p["id"].str] = Named(id: p["id"].str, name: p["name"].str) }
        for p in snap["profile_scopes"].array { n.profileScopes[p["scope"].str] = p["profile_id"].str }
        for m in snap["models"].array { n.models[m["id"].str] = Named(id: m["id"].str, name: m["name"].str, extra: m) }
        for r in snap["role_models"].array { n.roleModels[r["role"].str] = r["model"].str }
        for r in snap["requirements"].array { n.requirements[r["id"].str] = Named(id: r["id"].str, name: r["original"].str, extra: r) }
        for f in snap["memory_facts"].array { if let id = f["id"].int { n.facts[id] = Fact(id: id, kind: f["kind"].str, text: f["text"].str) } }
        n.settings = snap["settings"].object
        applyCaps(snap["capabilities"], into: &n)
        n.seq = snap["seq"].int ?? 0
        n.settingsSeq = n.seq
        n.ackedSeq = s.ackedSeq
        s = n
    }

    private static func message(_ m: JSON) -> ChatMessage? {
        guard let id = m["id"].int else { return nil }
        return ChatMessage(id: String(id), serverId: id, convId: m["conv_id"].str, role: m["role"].str, content: m["content"].str,
                           ts: m["ts"].double ?? 0)
    }

    private func applyCaps(_ c: JSON, into n: inout AppState) {
        guard !c.isNull else { return }
        n.features = c["features"].array.map {
            Feature(id: $0["id"].str, title: $0["title"].str, available: $0["available"].bool ?? false,
                    needsAppUpdate: $0["needs_app_update"].bool ?? false, planned: $0["status"].str == "planned")
        }
        n.requiredClient = c["required_client"].str
    }

    private func apply(_ e: JSON) {
        let kind = e["kind"].str, key = e["key"].str, op = e["op"].str, d = e["data"]
        let seq = e["seq"].int ?? s.seq
        switch kind {
        case "message":
            guard let m = Self.message(d) else { break }
            var conv = s.conversations[m.convId] ?? Conversation(id: m.convId, title: String(m.content.prefix(60)), created: m.ts)
            if !conv.messages.contains(where: { $0.serverId == m.serverId }) {
                if m.role == "user", let i = conv.messages.firstIndex(where: { $0.pending && $0.role == "user" && $0.content == m.content }) {
                    conv.messages[i] = m                        // our own message, now confirmed by the PC
                } else {
                    conv.messages.append(m)
                }
            }
            s.conversations[m.convId] = conv
        case "conversation":
            if op == "delete" { s.conversations[key] = nil; break }
            var conv = s.conversations[key] ?? Conversation(id: key, title: "", created: d["created"].double ?? 0)
            conv.title = d["title"].str
            conv.projectId = d["project_id"].int
            s.conversations[key] = conv
        case "task":
            if op == "delete" { s.tasks[Int(key) ?? -1] = nil } else if let t = TaskItem.from(d) { s.tasks[t.id] = t }
        case "approval":
            if let a = Approval.from(d) { s.approvals[a.id] = a }
        case "project":
            s.projects[key] = Named(id: key, name: d["name"].str, extra: d)
        case "profile":
            s.profiles[key] = Named(id: key, name: d["name"].str)
        case "profile_scope":
            s.profileScopes[key] = d["profile_id"].str
        case "model":
            s.models[key] = Named(id: key, name: d["name"].str, extra: d)
        case "role_model":
            if op == "delete" { s.roleModels[key] = nil } else { s.roleModels[key] = d["model"].str }
        case "requirement":
            s.requirements[key] = Named(id: key, name: d["original"].str, extra: d)
        case "memory_fact":
            if let id = d["id"].int {
                if d["active"].int == 0 { s.facts[id] = nil } else { s.facts[id] = Fact(id: id, kind: d["kind"].str, text: d["text"].str) }
            }
        case "settings":
            s.settings = d.object
            s.settingsSeq = seq
        case "capabilities":
            applyCaps(d, into: &s)
        case "app_update":
            s.desktop = d
        case "notification":
            let n = PCNotification(id: key, title: d["title"].str, body: d["body"].str, level: d["level"].str, ts: e["ts"].double ?? 0)
            if !s.notifications.contains(where: { $0.id == n.id }) {
                s.notifications.insert(n, at: 0)
                if s.notifications.count > 200 { s.notifications.removeLast(s.notifications.count - 200) }
                Notifier.post(n)
            }
        case "op":
            if let i = s.ops.firstIndex(where: { $0.id == key }) {
                s.ops[i].state = d["status"].str == "done" ? "done" : (d["status"].str == "failed" ? "failed" : s.ops[i].state)
                s.ops[i].error = d["error"].string
            }
        case "device":
            if op == "delete" && key == s.deviceId { unpair(reason: "This phone was removed on the PC.") }
        default:
            break       // a kind this app version does not know yet: ignored, still acknowledged
        }
        s.seq = max(s.seq, seq)
    }

    // MARK: - actions (queued, sent in order, idempotent)

    @discardableResult
    func enqueue(_ kind: String, _ args: JSON, summary: String = "") -> String {
        let id = "op-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).lowercased()
        s.ops.append(PendingOp(id: id, kind: kind, args: args, created: Date().timeIntervalSince1970, summary: summary))
        saveNow()
        poke()
        return id
    }

    private func flushOps() async throws {
        guard let token else { return }
        for op in s.ops where op.isOpen {
            guard let i = s.ops.firstIndex(where: { $0.id == op.id }) else { continue }
            s.ops[i].attempts += 1
            s.ops[i].state = "sent"
            saveSoon()
            let r: JSON
            do {
                r = try await api.request("POST", "/m/v1/ops", host: s.host,
                                          body: ["op_id": .string(op.id), "kind": .string(op.kind), "args": op.args], token: token, timeout: 60)
            } catch let e as APIError where e.isNetwork {
                s.ops[i].state = "queued"                       // stays queued; the same op_id is sent again later
                throw e
            } catch let APIError.http(code, msg) where code >= 400 && code < 500 {
                s.ops[i].state = "rejected"
                s.ops[i].error = msg
                continue
            }
            let st = r["status"].str
            s.ops[i].state = st == "accepted" ? "accepted" : st == "done" ? "done" : st == "rejected" ? "rejected" : "failed"
            s.ops[i].error = r["result"]["error"].string
            if st == "rejected", op.kind == "chat.send" { markMessageFailed(opId: op.id, error: s.ops[i].error ?? "rejected") }
        }
        // forget finished operations after a day
        let cutoff = Date().timeIntervalSince1970 - 86400
        s.ops.removeAll { !$0.isOpen && $0.state != "accepted" && $0.created < cutoff }
        saveSoon()
    }

    private func markMessageFailed(opId: String, error: String) {
        for (cid, conv) in s.conversations {
            if let i = conv.messages.firstIndex(where: { $0.opId == opId }) {
                s.conversations[cid]?.messages[i].content += "\n\n⚠️ not sent: \(error)"
                s.conversations[cid]?.messages[i].pending = false
            }
        }
    }

    func send(text: String, convId: String?, attachments: [String] = []) -> String {
        let cid = convId ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        var args: JSON = ["conv_id": .string(cid), "text": .string(text)]
        if !attachments.isEmpty, case .object(var o) = args {
            o["attachments"] = .array(attachments.map { .string($0) })
            args = .object(o)
        }
        let opId = enqueue("chat.send", args, summary: String(text.prefix(40)))
        let now = Date().timeIntervalSince1970
        var conv = s.conversations[cid] ?? Conversation(id: cid, title: String(text.prefix(60)), created: now)
        conv.messages.append(ChatMessage(id: "local-\(opId)", convId: cid, role: "user", content: text, ts: now, pending: true, opId: opId))
        s.conversations[cid] = conv
        saveNow()
        return cid
    }

    func isWaitingForReply(_ convId: String) -> Bool {
        guard let conv = s.conversations[convId], let last = conv.messages.last else { return false }
        if last.role != "user" { return false }
        if last.pending { return true }
        return s.ops.contains { $0.kind == "chat.send" && $0.args["conv_id"].str == convId && $0.state == "accepted" }
            && Date().timeIntervalSince1970 - last.ts < 1800
    }

    /// Approvals are bound to exactly what the phone showed: the PC refuses if it changed since.
    func decide(_ a: Approval, approve: Bool, feedback: String) async throws {
        guard let token else { throw APIError.unauthorized }
        let fresh = try await api.request("GET", "/m/v1/approvals/\(a.id)", host: s.host, token: token)
        enqueue("approval.decide", ["id": .number(Double(a.id)), "approve": .bool(approve), "feedback": .string(feedback),
                                    "expect_hash": fresh["hash"]], summary: "\(approve ? "approve" : "decline") #\(a.id)")
    }

    func setSetting(_ key: String, _ value: JSON) {
        enqueue("settings.set", ["values": .object([key: value]), "base_seq": .number(Double(s.settingsSeq))], summary: "set \(key)")
    }

    func pendingSetting(_ key: String) -> JSON? {
        s.ops.last(where: { $0.kind == "settings.set" && $0.isOpen && !$0.args["values"][key].isNull })?.args["values"][key]
    }

    // MARK: - direct reads (online only)

    func get(_ path: String) async throws -> JSON {
        guard let token else { throw APIError.unauthorized }
        return try await api.request("GET", path, host: s.host, token: token)
    }

    func upload(name: String, data: Data) async throws -> String {
        guard let token else { throw APIError.unauthorized }
        let r = try await api.request("POST", "/m/v1/upload", host: s.host,
                                      body: ["name": .string(name), "data_b64": .string(data.base64EncodedString())], token: token, timeout: 120)
        guard let id = r["id"].string ?? r["name"].string ?? r["file"].string else { throw APIError.bad("upload failed") }
        return id
    }

    func refreshTelemetry() async {
        do {
            telemetry = try await get("/m/v1/telemetry")
            telemetryTime = Date().timeIntervalSince1970
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func loadOlder(_ convId: String) async {
        guard let first = s.conversations[convId]?.messages.first(where: { $0.serverId != nil })?.serverId else { return }
        do {
            let older = try await get("/m/v1/messages?conv_id=\(convId)&before=\(first)&limit=60").array.compactMap(Self.message)
            s.conversations[convId]?.messages.insert(contentsOf: older, at: 0)
            if older.count < 60 { s.conversations[convId]?.complete = true }
            saveSoon()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    // MARK: - pairing

    func pair(host: String, code: String) async throws {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let r = try await api.request("POST", "/m/v1/pair", host: h,
                                      body: ["code": .string(code), "name": .string(UIDevice.current.name),
                                             "client_version": .string(BeterAPI.appVersion), "platform": "ios"])
        guard let tok = r["token"].string else { throw APIError.bad("pairing failed") }
        var n = AppState()
        n.host = h
        n.deviceId = r["device_id"].str
        s = n
        token = tok
        saveNow()
        let snap = try await api.request("GET", "/m/v1/snapshot", host: h, token: tok, timeout: 60)
        applySnapshot(snap)
        saveNow()
        status = .synchronizing
        Notifier.requestPermission()
        poke()
    }

    func unpair(reason: String? = nil) {
        let h = s.host, tok = token
        token = nil
        s = AppState()
        saveNow()
        status = .notPaired
        lastError = reason
        if let tok, reason == nil {
            Task { _ = try? await BeterAPI.shared.request("POST", "/m/v1/logout", host: h, token: tok) }
        }
    }

    // MARK: - persistence

    func saveSoon() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !Task.isCancelled { saveNow() }
        }
    }

    func saveNow() {
        guard let d = try? JSONEncoder().encode(s) else { return }
        try? d.write(to: Self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func markNotificationsRead() {
        for i in s.notifications.indices { s.notifications[i].read = true }
        saveSoon()
    }

    // MARK: - helpers

    func isOlder(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }, pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    func feature(_ id: String) -> Feature? { s.features.first { $0.id == id } }

    func can(_ id: String) -> Bool { s.features.isEmpty || feature(id)?.available == true }
}

enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func post(_ n: PCNotification) {
        let c = UNMutableNotificationContent()
        c.title = n.title
        c.body = n.body
        c.threadIdentifier = n.level
        let req = UNNotificationRequest(identifier: n.id, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

import Foundation

struct ChatMessage: Codable, Identifiable, Hashable, Sendable {
    var id: String                // server id as text, or "local-<uuid>" while it is waiting to be sent
    var serverId: Int?
    var convId: String
    var role: String
    var content: String
    var ts: Double
    var pending: Bool = false     // written on the phone, not yet confirmed by the PC
    var opId: String?
}

struct Conversation: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var projectId: Int?
    var created: Double
    var messages: [ChatMessage] = []
    var complete: Bool = true      // false: older messages exist on the PC (loaded on demand)
    var lastTs: Double { messages.last?.ts ?? created }
}

struct TaskItem: Codable, Identifiable, Hashable, Sendable {
    var id: Int
    var title: String
    var status: String
    var stage: String
    var priority: Int
    var kind: String
    var projectId: Int?
    var result: String
    var updated: Double

    var isActive: Bool { ["running", "queued", "waiting_approval", "paused", "blocked"].contains(status) }

    static func from(_ j: JSON) -> TaskItem? {
        guard let id = j["id"].int else { return nil }
        return TaskItem(id: id, title: j["title"].str, status: j["status"].str, stage: j["stage"].str, priority: j["priority"].int ?? 50,
                        kind: j["kind"].str, projectId: j["project_id"].int, result: j["result"].str,
                        updated: j["updated"].double ?? j["created"].double ?? 0)
    }
}

struct Approval: Codable, Identifiable, Hashable, Sendable {
    var id: Int
    var kind: String
    var detail: JSON
    var status: String
    var created: Double

    static func from(_ j: JSON) -> Approval? {
        guard let id = j["id"].int else { return nil }
        return Approval(id: id, kind: j["kind"].str, detail: j["detail"], status: j["status"].str, created: j["created"].double ?? 0)
    }
}

struct Named: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var extra: JSON = .null
}

struct Fact: Codable, Identifiable, Hashable, Sendable {
    var id: Int
    var kind: String
    var text: String
}

struct PCNotification: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var body: String
    var level: String
    var ts: Double
    var read: Bool = false
}

/// A user action waiting to reach the PC. Kept on disk, sent in order, never run twice (the PC answers a repeated op_id from
/// its record).
struct PendingOp: Codable, Identifiable, Hashable, Sendable {
    var id: String               // op_id
    var kind: String
    var args: JSON
    var created: Double
    var state: String = "queued" // queued | sent | accepted | done | rejected | failed
    var error: String?
    var attempts: Int = 0
    var summary: String = ""

    var isOpen: Bool { state == "queued" || state == "sent" }
}

struct Feature: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var available: Bool
    var needsAppUpdate: Bool
    var planned: Bool
}

/// Everything the phone knows. Saved as one file; replaced by a PC snapshot when the phone was away too long.
struct AppState: Codable, Sendable {
    var host: String = ""
    var deviceId: String = ""
    var seq: Int = 0                 // last journal sequence APPLIED and saved (acknowledged to the PC after saving)
    var ackedSeq: Int = 0
    var head: Int = 0
    var lastSync: Double = 0
    var conversations: [String: Conversation] = [:]
    var tasks: [Int: TaskItem] = [:]
    var approvals: [Int: Approval] = [:]
    var projects: [String: Named] = [:]
    var profiles: [String: Named] = [:]
    var profileScopes: [String: String] = [:]
    var models: [String: Named] = [:]
    var roleModels: [String: String] = [:]
    var requirements: [String: Named] = [:]
    var facts: [Int: Fact] = [:]
    var settings: [String: JSON] = [:]
    var settingsSeq: Int = 0
    var features: [Feature] = []
    var requiredClient: String = ""
    var desktop: JSON = .null
    var notifications: [PCNotification] = []
    var ops: [PendingOp] = []
}

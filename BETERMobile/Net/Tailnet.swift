import Foundation
import TailscaleKit

/// The app's own Tailscale node (TailscaleKit, userspace): only this app's requests go through it - no VPN profile, no
/// separate Tailscale app. It signs in once (in Safari, with the owner's Tailscale account) and keeps its identity on disk.
struct TSLogger: LogSink {
    var logFileHandle: Int32? = nil
    func log(_ message: String) {
        #if DEBUG
        print("tailscale: \(message)")
        #endif
    }
}

enum TailnetState: String, Sendable {
    case starting, needsLogin, running, stopped, failed
}

actor TailnetWatcher: MessageConsumer {
    private let onUpdate: @Sendable (TailnetState?, String?, String?) -> Void

    init(onUpdate: @escaping @Sendable (TailnetState?, String?, String?) -> Void) {
        self.onUpdate = onUpdate
    }

    func notify(_ notify: Ipn.Notify) {
        var st: TailnetState?
        if let s = notify.State {
            switch s {
            case .Running: st = .running
            case .NeedsLogin, .NeedsMachineAuth: st = .needsLogin
            case .Stopped: st = .stopped
            default: st = .starting
            }
        }
        onUpdate(st, notify.BrowseToURL, notify.ErrMessage)
    }

    func error(_ error: Error) {
        onUpdate(nil, nil, "\(error)")
    }
}

actor Tailnet {
    static let shared = Tailnet()

    private var node: TailscaleNode?
    private var client: LocalAPIClient?
    private var processor: MessageProcessor?
    private var config: URLSessionConfiguration?
    private var starting = false

    private(set) var state: TailnetState = .stopped
    private(set) var loginURL: String?
    private(set) var lastError: String?
    private var listeners: [UUID: @Sendable (TailnetState, String?, String?) -> Void] = [:]

    func observe(_ fn: @escaping @Sendable (TailnetState, String?, String?) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = fn
        fn(state, loginURL, lastError)
        return id
    }

    private func publish() {
        for fn in listeners.values { fn(state, loginURL, lastError) }
    }

    private func update(_ st: TailnetState?, _ url: String?, _ err: String?) {
        if let st { state = st }
        if let url, !url.isEmpty { loginURL = url }
        if state == .running { loginURL = nil }
        if let err, !err.isEmpty { lastError = err }
        publish()
    }

    private static func dataDir() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("tailscale", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// Starts the node (idempotent). Returns at once; state changes arrive through observe().
    func start() {
        guard node == nil, !starting else { return }
        starting = true
        state = .starting
        publish()
        Task { await self.bringUp() }
    }

    private func bringUp() async {
        do {
            let cfg = Configuration(hostName: "beter-iphone", path: Self.dataDir(), authKey: nil,
                                    controlURL: kDefaultControlURL, ephemeral: false)
            let n = try TailscaleNode(config: cfg, logger: TSLogger())
            node = n
            // watch the node's events first: up() waits until sign-in is done, and the sign-in link arrives as an event
            let c = LocalAPIClient(localNode: n, logger: TSLogger())
            client = c
            let watcher = TailnetWatcher { [weak self] st, url, err in
                Task { await self?.update(st, url, err) }
            }
            Task {
                do {
                    let p = try await c.watchIPNBus(mask: [.initialState, .prefs], consumer: watcher)
                    await self.setProcessor(p)
                } catch {
                    await self.update(nil, nil, "watch: \(error)")
                }
            }
            try await n.up()
            update(.running, nil, nil)
        } catch {
            update(.failed, nil, "\(error)")
        }
        starting = false
    }

    private func setProcessor(_ p: MessageProcessor) { processor = p }

    /// Asks for a fresh sign-in link (when the node needs login and no link has arrived).
    func requestLogin() async {
        guard let client else { return }
        do { try await client.startLoginInteractive() } catch { update(nil, nil, "login: \(error)") }
    }

    func logout() async {
        guard let client else { return }
        do { try await client.resetAuth() } catch { update(nil, nil, "logout: \(error)") }
        update(.needsLogin, nil, nil)
    }

    /// URLSession settings that send requests through this app's Tailscale node (cached once the node is up).
    func sessionConfiguration() async throws -> URLSessionConfiguration {
        if let config { return config }
        guard let node, state == .running else { throw APIError.offline("private network not connected") }
        let (cfg, _) = try await URLSessionConfiguration.tailscaleSession(node)
        cfg.timeoutIntervalForRequest = 75
        cfg.timeoutIntervalForResource = 600
        cfg.waitsForConnectivity = false
        config = cfg
        return cfg
    }

    func resetSession() { config = nil }
}

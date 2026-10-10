import Foundation
import Network
import TailscaleKit

final class OnceFlag: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func set() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

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
    private var generation = 0

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
    func start(authKey: String? = nil) {
        guard node == nil, !starting else { return }
        starting = true
        state = .starting
        publish()
        Task { await self.bringUp(authKey: authKey) }
    }

    private func bringUp(authKey: String?) async {
        do {
            let key = authKey?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cfg = Configuration(hostName: "beter-iphone", path: Self.dataDir(), authKey: (key?.isEmpty ?? true) ? nil : key,
                                    controlURL: kDefaultControlURL, ephemeral: false)
            let n = try TailscaleNode(config: cfg, logger: TSLogger())
            node = n
            // 1. start the engine (its local control API and proxy) - up() itself waits until sign-in is done
            _ = try await n.loopback()
            let c = LocalAPIClient(localNode: n, logger: TSLogger())
            client = c
            // 2. bring the node up in the background; it returns once signed in
            Task.detached {
                do { try await n.up() } catch { await self.update(.failed, nil, "up: \(error)") }
            }
            // 3. ask the engine for its state and sign-in link until it is running (the same way the PC does)
            generation += 1
            let gen = generation
            Task { await self.poll(gen) }
            // 4. live events too, when the bus works (faster state changes)
            let watcher = TailnetWatcher { [weak self] st, url, err in
                Task { await self?.update(st, url, err) }
            }
            Task {
                if let p = try? await c.watchIPNBus(mask: [.initialState, .prefs], consumer: watcher) { await self.setProcessor(p) }
            }
        } catch {
            update(.failed, nil, "\(error)")
        }
        starting = false
    }

    private func poll(_ gen: Int) async {
        var askedForLink = Date.distantPast
        while gen == generation {
            if let client {
                do {
                    let st = try await client.backendStatus()
                    let mapped: TailnetState
                    switch st.BackendState {
                    case "Running": mapped = .running
                    case "NeedsLogin", "NeedsMachineAuth": mapped = .needsLogin
                    case "Stopped": mapped = .stopped
                    default: mapped = .starting
                    }
                    update(mapped, st.AuthURL.isEmpty ? nil : st.AuthURL, nil)
                    if mapped == .needsLogin && st.AuthURL.isEmpty && Date().timeIntervalSince(askedForLink) > 10 {
                        askedForLink = Date()
                        try? await client.startLoginInteractive()
                    }
                    if mapped == .running {
                        try? await Task.sleep(nanoseconds: 15_000_000_000)     // running: check now and then
                        continue
                    }
                } catch {
                    lastError = "status: \(error)"
                    publish()
                }
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    /// Throws away the node and starts again (Retry on the connect screen).
    func restart(authKey: String? = nil) async {
        generation += 1
        if let node { try? await node.close() }
        node = nil
        client = nil
        processor = nil
        config = nil
        starting = false
        loginURL = nil
        lastError = nil
        start(authKey: authKey)
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

    func waitUntilRunning(seconds: Double) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if state == .running && node != nil { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return state == .running
    }

    /// Back in the foreground: if iOS took the local proxy away while suspended, rebuild the node now (before the user taps).
    func checkAfterResume() async {
        guard state == .running, let node else { return }
        do {
            let lb = try await node.loopback()
            guard let ip = lb.ip, let port = lb.port else { await restart(); return }
            if !(await Self.portOpen(ip, port)) { await restart() }
        } catch {
            await restart()
        }
    }

    private static func portOpen(_ ip: String, _ port: Int) async -> Bool {
        await withCheckedContinuation { cont in
            let conn = NWConnection(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
            let once = OnceFlag()
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready: if once.set() { conn.cancel(); cont.resume(returning: true) }
                case .failed, .waiting: if once.set() { conn.cancel(); cont.resume(returning: false) }
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if once.set() { conn.cancel(); cont.resume(returning: false) } }
        }
    }
}

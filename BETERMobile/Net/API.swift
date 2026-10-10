import Foundation
import Security

enum APIError: Error, LocalizedError {
    case offline(String)
    case unauthorized
    case http(Int, String)
    case bad(String)

    var errorDescription: String? {
        switch self {
        case .offline(let s): return "Can't reach your PC: \(s)"
        case .unauthorized: return "This phone is not paired (or was removed on the PC). Pair again."
        case .http(let code, let s): return "PC answered \(code): \(s)"
        case .bad(let s): return s
        }
    }

    var isNetwork: Bool { if case .offline = self { return true }; return false }
}

enum Keychain {
    private static let service = "com.forrest.betermobile"

    static func set(_ value: String?, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard let value else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

/// Talks to the B.E.T.E.R. phone gateway (/m/v1) on the PC, through the app's Tailscale node.
actor BeterAPI {
    static let shared = BeterAPI()

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    private var session: URLSession?

    private func urlSession() async throws -> URLSession {
        if let session { return session }
        let s = URLSession(configuration: try await Tailnet.shared.sessionConfiguration())
        session = s
        return s
    }

    func reset() async {
        session = nil
        await Tailnet.shared.resetSession()
    }

    func request(_ method: String, _ path: String, host: String, body: JSON? = nil, token: String? = nil,
                 timeout: TimeInterval = 30) async throws -> JSON {
        guard !host.isEmpty, let url = URL(string: "http://\(host)\(path)") else { throw APIError.bad("no PC address") }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue(Self.appVersion, forHTTPHeaderField: "X-Beter-Client")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body.data()
        }
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await urlSession().data(for: req)
        } catch let e as APIError {
            throw e
        } catch {
            await reset()
            throw APIError.offline(error.localizedDescription)
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let j = JSON.parse(data)
        if code == 401 { throw APIError.unauthorized }
        if code == 502 || code == 503 || code == 504 { throw APIError.offline("B.E.T.E.R. is not running on the PC") }
        guard (200..<300).contains(code) else {
            throw APIError.http(code, j["detail"].string ?? String(data: data, encoding: .utf8) ?? "")
        }
        return j
    }
}

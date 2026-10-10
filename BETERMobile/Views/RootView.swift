import SwiftUI
import UIKit
import SafariServices

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if !model.paired {
                if model.tailnet != .running {
                    ConnectView()
                } else {
                    PairView()
                }
            } else {
                MainTabs()
            }
        }
        .animation(.default, value: model.paired)
    }
}

/// Step 1: this app joins the owner's private network (its own Tailscale node, nothing system-wide).
struct ConnectView: View {
    @EnvironmentObject var model: AppModel
    @State private var signInURL: URL?
    @State private var showKey = false
    @State private var authKey = ""

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "lock.shield").font(.system(size: 56)).foregroundStyle(.tint)
            Text("Connect to your private network").font(.title2.bold()).multilineTextAlignment(.center)
            Text("B.E.T.E.R. Mobile talks to your PC over your own Tailscale network. Sign in once with the same account you used on the PC.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            switch model.tailnet {
            case .needsLogin:
                if let url = model.loginURL.flatMap(URL.init(string:)) {
                    Button { signInURL = url } label: {
                        Label("Sign in to Tailscale", systemImage: "person.badge.key").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                    Text("Sign in, then tap Connect on the page that names beter-iphone. This closes by itself once it's connected.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                } else {
                    ProgressView("Getting the sign-in link…")
                    Button("Ask again") { Task { await Tailnet.shared.requestLogin() } }
                }
            case .failed:
                Text(model.tailnetError ?? "The private network could not start.").foregroundStyle(.red).multilineTextAlignment(.center)
                Button("Try again") { Task { await Tailnet.shared.restart() } }
            default:
                ProgressView("Starting the private network…")
                if let e = model.tailnetError {
                    Text(e).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                Button("Retry") { Task { await Tailnet.shared.restart() } }.padding(.top, 8)
            }
            DisclosureGroup("Use an auth key instead", isExpanded: $showKey) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("On the PC, open login.tailscale.com/admin/settings/keys → Generate auth key (defaults are fine) → copy it, and paste it here.")
                        .font(.caption).foregroundStyle(.secondary)
                    SecureField("tskey-auth-…", text: $authKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(8).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    Button("Connect with key") {
                        let k = authKey
                        authKey = ""
                        Task { await Tailnet.shared.restart(authKey: k) }
                    }.disabled(!authKey.hasPrefix("tskey-"))
                }.padding(.top, 6)
            }
            .font(.footnote)
            Spacer()
            Text("Remote Access: \(label)").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(24)
        .sheet(item: $signInURL) { url in SafariView(url: url).ignoresSafeArea() }
        .onChange(of: model.tailnet) { _, st in if st == .running { signInURL = nil } }
    }

    var label: String {
        switch model.tailnet {
        case .running: return "Connected"
        case .needsLogin: return "Sign-in needed"
        case .failed, .stopped: return "Offline"
        case .starting: return "Connecting"
        }
    }
}


extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// Sign-in inside the app: the app stays in the foreground, so its network engine is awake when the sign-in completes
/// (with Safari, iOS pauses the app and the engine misses it).
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let c = SFSafariViewController.Configuration()
        c.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: c)
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

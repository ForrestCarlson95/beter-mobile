import SwiftUI
import UIKit

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
    @Environment(\.openURL) private var openURL

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
                    Button { openURL(url) } label: {
                        Label("Sign in to Tailscale", systemImage: "person.badge.key").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                    Text("After signing in, come back here.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    ProgressView("Getting the sign-in link…")
                    Button("Ask again") { Task { await Tailnet.shared.requestLogin() } }
                }
            case .failed:
                Text(model.tailnetError ?? "The private network could not start.").foregroundStyle(.red).multilineTextAlignment(.center)
                Button("Try again") { Task { await Tailnet.shared.requestLogin() } }
            default:
                ProgressView("Starting the private network…")
            }
            Spacer()
            Text("Remote Access: \(label)").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(24)
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

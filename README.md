# B.E.T.E.R. Mobile

iPhone companion for B.E.T.E.R., a private AI assistant that runs on its owner's own PC. The phone does no AI work: it pairs
once with the PC and talks to it over the owner's private Tailscale network, with the network built into the app
(TailscaleKit, userspace) - no VPN profile and no separate Tailscale app.

This repository holds only the phone app. The PC side is not here.

- Build: GitHub Actions (`.github/workflows/ios.yml`) builds an unsigned `BETER-unsigned.ipa` into the `latest` release.
- Install: sign and install the .ipa with Sideloadly and a free Apple ID (re-sign every 7 days).

Third-party: TailscaleKit / libtailscale (BSD-3-Clause, Copyright (c) Tailscale Inc & AUTHORS).

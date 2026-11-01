# DuoRemote

An iOS app for controlling a Mac at home, built for the iPhone Duo.

Two things, nothing else:

1. **SSH terminal** — a real interactive shell on your Mac, with a proper
   terminal emulator (SwiftTerm) and an SSH client (Citadel, pure Swift).
2. **Remote desktop** — live control of the Mac's screen over VNC
   (macOS Screen Sharing), with touch, drag, right-click, scroll, and a
   keyboard + modifier toolbar.

LAN only, by design. The app refuses any host that isn't a private IP
(`10.x`, `172.16–31.x`, `192.168.x`) or a `.local` Bonjour name, so it
cannot be pointed at a machine over the internet. There is no cloud relay,
no account, and no telemetry. Passwords live in the Keychain, never in
the host list.

## Duo layout

The layout is width-based, not device-name-based, so it also behaves on
iPad and in Split View:

- **Folded (compact width):** tabs — Terminal, Desktop, Hosts. One pane
  at a time, full-bleed.
- **Unfolded (width ≥ 700pt):** terminal and desktop side by side, both
  live at once, with a draggable divider (clamped to 30–70%). Watch a
  build in the terminal while clicking around the desktop, no tab switching.

## Mac setup (once)

On the Mac you want to control:

1. **System Settings → General → Sharing → Remote Login: on.**
   This enables SSH on port 22. Note which users are allowed.
2. **System Settings → General → Sharing → Screen Sharing: on.**
3. In Screen Sharing, turn on **“VNC viewers may control screen with
   password”** and set a password you use nowhere else.
   - This is the v1 requirement: DuoRemote speaks RFB VNC-password auth
     (security type 2). It does *not* yet speak Apple's ARD auth
     (type 30, the macOS-account login), so a Mac with only macOS-account
     Screen Sharing will be refused with a message saying so.
4. Put the phone and the Mac on the same Wi-Fi.

Then in the app: Hosts → add the Mac (or pick it from “Found on this
network”), enter the macOS password for SSH and the VNC password, and
connect. Terminal and desktop connect independently, so if VNC is
misconfigured the terminal still works and tells you exactly that.

## Build

Requires Xcode on a Mac (this repo was assembled without Xcode, so the
first build is the verification step — see Status below).

1. Open `DuoRemote.xcodeproj` in Xcode.
2. Select the DuoRemote target → Signing & Capabilities → pick your
   team, and set a bundle identifier you own
   (the project ships `com.duoremote.DuoRemote` as a placeholder).
3. Xcode resolves the Swift Package dependencies on first build:
   - [Citadel](https://github.com/orlandos-nl/Citadel) 0.12 — SSH
   - [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.12 — terminal emulation
   - [swift-nio](https://github.com/apple/swift-nio) 2.x — ByteBuffer, via Citadel
4. Run on a physical Duo (the simulator has no LAN Mac to talk to, and
   Bonjour discovery needs the local-network permission, which the app
   requests with the explanation in `Info.plist`).

## How it works

| Piece | Implementation |
|---|---|
| SSH | `Services/SSHSession.swift` — Citadel `SSHClient.connect` + `withPTY`, xterm-256color, fed into SwiftTerm |
| Terminal UI | `Views/TerminalViewWrapper.swift` — SwiftTerm `TerminalView` bridged to SwiftUI; keystrokes return via `TerminalViewDelegate.send` |
| Desktop | `VNC/VNCClient.swift` — a from-scratch RFB 3.8 client: None + VNC-password auth (DES challenge/response), Raw + CopyRect encodings, forced 32bpp true-colour pixel format |
| Desktop input | `VNC/DesktopInputView.swift` — UIKit view: direct-touch or trackpad mouse, tap / drag / long-press right-click, two-finger scroll, `UIKeyInput` keyboard |
| Discovery | `Services/DiscoveryService.swift` — Bonjour `_ssh._tcp.` + `_rfb._tcp.` |
| Secrets | `Models/KeychainStore.swift` — Keychain, per-host, SSH and VNC kept separate |
| LAN guard | `Models/HostProfile.swift` — `LANValidation`, checked on save and again before every connect |

## Status and honest limitations (v1)

- **Not yet compiled.** This project was written on a Linux VM with no
  Xcode, so it has not been through a real build. The first Xcode build
  is the check. If Citadel or SwiftTerm have drifted from the APIs used
  here, the two files to adjust are `Services/SSHSession.swift`
  (the `withPTY` closure's writer type) and
  `Views/TerminalViewWrapper.swift` (SwiftTerm delegate/feed calls).
  Everything else — VNC, discovery, layout, Keychain — depends on
  Foundation/UIKit/Network only.
- **Host-key trust:** SSH currently uses Citadel's `.acceptAnything()`
  host-key validator. That is only defensible because of the LAN-only
  guard. Before removing that guard, add trust-on-first-use pinning:
  show the host-key fingerprint on first connect, store it, and refuse
  on change. This is the top hardening item.
- **SSH auth is password-only.** Key auth is not wired yet.
- **No live PTY resize.** The terminal reports its size, and it is used
  on the next connect, but resizing mid-session does not yet resize the
  remote PTY.
- **VNC is Raw + CopyRect only.** Fast enough on a LAN; ZRLE/Tight
  would help on slower links. No clipboard sync yet, and the VNC session
  itself is unencrypted by RFB — another reason this stays LAN-only.
- **No Apple ARD auth (type 30).** See Mac setup step 3.

## Project layout

```
DuoRemote.xcodeproj/
DuoRemote/
  App/            DuoRemoteApp.swift, ContentView.swift (Duo layout)
  Models/         HostProfile.swift (LAN guard), KeychainStore.swift
  Services/       SSHSession.swift, SessionStore.swift, DiscoveryService.swift
  Views/          TerminalPane.swift, TerminalViewWrapper.swift,
                  DesktopPane.swift, HostListView.swift
  VNC/            VNCClient.swift, VNCKeys.swift, DesktopInputView.swift
  Info.plist
```

## License

MIT for this app's own code. Citadel, SwiftTerm, and swift-nio keep
their own licenses (see their repos).

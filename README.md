# Home Row

SSH and Screen Sharing for the Macs at home, designed for iPhone Duo.
Implements the Claude Design project **Home Row** (`Home Row.dc.html`).

- **Folded (5.4″ outer display):** find Macs over Bonjour, verify and pair,
  pick a Mac, settings. Sessions still work here with the system keyboard.
- **Half-open, portrait (7.6″ inner display):** the session sits above the
  crease; the lower half becomes a MacBook deck: a full keyboard under the
  terminal, or a key strip and trackpad under the remote screen.
- **Flat, landscape:** the remote screen goes full-bleed with direct touch
  and a floating key strip.

The posture comes from the iOS 27.1 hinge API (`UIHingeInteraction`) plus the
window size. See `Posture` in `HomeRow/App/AppModel.swift`.

LAN only. Every connection resolves the name first and refuses anything that
isn't a private, link-local or `.local` address. No cloud relay, no account,
no telemetry.

## Mac setup (once)

1. **System Settings → General → Sharing → Remote Login: on** (terminal).
2. **Screen Sharing: on.** Home Row signs in with your macOS username and
   password (Apple's RFB security type 30). It doesn't need a separate VNC password.
   If you've also turned on “VNC viewers may control screen with password”,
   that works as a fallback.
3. Optional: **Energy → Wake for network access**, so the Hosts screen can
   wake the Mac.

## Security

- **Host keys are pinned on first use.** The Pair screen shows the SHA256
  fingerprint along with the exact `ssh-keygen -lf /etc/ssh/…` command that
  prints the same value on the Mac. A changed key is refused with an explanation.
  You can forget a pinned key under Hosts → (long-press) → Edit.
- **SSH key sign-in** uses an ED25519 key (`home-row-ed25519`) generated on
  the phone. It's stored in the Keychain behind `.userPresence`, so Face ID /
  Touch ID / passcode gates every use. When you pair, Home Row asks for your Mac password once to
  append the public key to `~/.ssh/authorized_keys`, and that password is not kept.
- Account passwords for Screen Sharing (and password-auth SSH, if you choose
  it) live in the Keychain, this-device-only.
- The RFB stream itself is not encrypted (that's true of macOS Screen
  Sharing to third-party clients). This is a big part of why Home Row is LAN-only.

## Build

Requires Xcode 27.1+ (iOS 27.1 SDK, for the hinge API). The project is
generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from
`project.yml`. The generated `HomeRow.xcodeproj` is committed too.

```sh
xcodegen generate
open HomeRow.xcodeproj
```

Signing uses team `2592SJ8QAU` and bundle id `com.charlieliu.homerow`. Change them in
`project.yml` if needed.

Dependencies (Swift Package Manager): Citadel (SSH), SwiftTerm (terminal
emulation), swift-nio-ssh / swift-nio (host keys, buffers), BigInt
(Diffie-Hellman for Apple sign-in).

## Tests

```sh
xcodebuild test -project HomeRow.xcodeproj -scheme HomeRow \
  -destination 'platform=iOS Simulator,name=iPhone Duo'
```

The unit tests (ZRLE decoding, VNC DES, fingerprints, LAN guard, sticky
modifiers, keysyms, posture) always run. The integration tests run only when
pointed at real servers via `TEST_RUNNER_` environment variables:

| Test | Variables |
|---|---|
| `SSHIntegrationTests` | `HOMEROW_SSH_HOST`, `_PORT`, `_USER`, `_AUTHKEYS`, `_HOSTKEY_FP` |
| `RFBIntegrationTests` | `HOMEROW_RFB_PORT` (a server speaking Apple DH auth as `tester` / `s3cret`) |
| `LayoutSnapshotTests` | both of the above + `HOMEROW_SSH_CLIENT_KEY`, `HOMEROW_SNAPSHOT_DIR` |

For example, prefix each with `TEST_RUNNER_` on the `xcodebuild test` command line.
A non-root `sshd -D -f <config>` on a high port with key-only auth is enough
for the SSH tests.

## How it works

| Piece | File |
|---|---|
| Hinge → posture, sessions, connect flow | `App/AppModel.swift`, `App/HomeRowApp.swift` |
| Keycaps, LEDs, wells, caps-lock toggles | `Design/Theme.swift` |
| Saved Macs, LAN guard, Keychain, SSH identity | `Model/` |
| SSH: TOFU validator, key install, PTY, live resize | `Net/SSH.swift`, `Net/TerminalSession.swift` |
| Bonjour (`_ssh._tcp`, `_rfb._tcp`), Wake-on-LAN | `Net/Discovery.swift` |
| RFB 3.8 client: Apple DH + VNC auth, ZRLE / CopyRect / Raw, cursor, desktop resize, adaptive 16-bit | `VNC/` |
| Screen session, `caffeinate` keep-awake | `Net/ScreenSession.swift` |
| Deck keyboard (sticky modifiers, caps LED, fn layer, key repeat) | `Views/Open/DeckKeys.swift`, `KeyTargets.swift` |
| Remote screen (direct touch, pinch zoom) and trackpad | `Views/Shared/RemoteScreen.swift` |

## Known limitations

- **Wake-on-LAN is best effort.** iOS only allows broadcast packets for apps
  with Apple's multicast entitlement, which Home Row doesn't have. It sends the
  magic packet to the Mac's last address and pokes its SSH port, which
  wakes a Mac through a Bonjour Sleep Proxy (Apple TV / HomePod) if one is on the network.
- **Screen Sharing auth:** types 30 (Apple account) and 2 (VNC password).
  If a future macOS stops offering both, connecting fails with a message
  naming the offered types.
- **Scroll direction** follows the touch ("natural"). If your Mac also
  inverts wheel events, it will feel reversed. That isn't configurable yet.
- Tested against a local `sshd` and a scripted RFB server. It has not yet been
  tested against a real Mac's Screen Sharing or on Duo hardware.

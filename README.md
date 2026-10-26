# UW VPN

A small native macOS menu bar wrapper around the Homebrew OpenConnect you already
have. Connect, disconnect, edit a JSON file, save a password in the login Keychain.
No third-party GUI framework or downloaded app code.

Requires an Apple Silicon Mac running macOS 13+, Xcode Command Line Tools, and:

```sh
brew install openconnect
./scripts/build.sh
./scripts/test.sh --ui
./scripts/install.sh
open "$HOME/Applications/UW VPN.app"
```

`build.sh` uses only the system Swift compiler and ad-hoc code signing. No package
manager, remote build step, developer account, system extension, or persistent
privileged helper is needed. `test.sh` uses Python 3 to drive a fake tunnel.
Quit the app before replacing an installed build. An ad-hoc signed rebuild can
require granting Keychain access again because its code identity changes.

## Plaintext config

Edit `~/.config/uw-vpn/config.json`, or choose **Edit Config…** in the menu:

```json
{
  "server": "https://vpn.uwaterloo.ca",
  "authgroup": "UW-General-Campus",
  "username": "YOUR_WATIAM_USERNAME",
  "duo": "push",
  "reconnectTimeout": 3600
}
```

All five keys are required. Unknown keys are rejected. `duo` accepts `push`,
`push1`, `push2`, etc. The app reloads the file each time you connect; editing it
does not alter an active connection. Passwords do not belong in this file.
Homebrew's `/opt/homebrew/bin/openconnect` and
`/opt/homebrew/etc/vpnc/vpnc-script` are explicit constants in `Core.swift`.

Choose **Connect**, approve the standard macOS administrator dialog when it
appears, enter your WatIAM password in the app's secure field on first use, and
approve Duo on your phone. Subsequent connects use the saved password. The
macOS administrator password is handled by macOS, never by this app. You may
still get Keychain authorization/unlock prompts under your local Keychain policy.

**Set Password…** replaces the saved password for the current config.
**Forget Password** deletes it. Items are scoped to the server, group and username;
changing any of those gives a different Keychain item. Diagnostics are bounded,
redacted, and held only in memory. There is no launch-at-login or auto-connect.

## What runs with privilege

1. The app launches the bundled `uw-vpn-runner` with `osascript`'s standard
   `with administrator privileges` dialog. The AppleScript contains executable
   and socket paths plus your local UID; it contains no password or cookie.
2. The runner connects to a fresh Unix socket in a random 0700 directory, with
   a 0600 socket. The app checks that its peer is root; the runner checks the
   user's UID. Authentication starts only after this handshake.
3. The app reads its own Keychain item, runs **unprivileged** OpenConnect with
   `--authenticate --non-inter --passwd-on-stdin`, and fills
   `main:secondary_password=push`. The password goes over an anonymous pipe.
4. OpenConnect's returned assignments are parsed as strings, never evaluated as
   shell code. The session cookie, final gateway URL, certificate fingerprint,
   and address override are handed to the runner over the private socket. Cookies
   are never cached to disk or placed in process arguments.
5. The runner starts OpenConnect with fixed argument construction and a minimal
   environment. Only its stdin receives the cookie. Homebrew's `vpnc-script`
   applies the gateway's routes and DNS settings. No guessed Waterloo route list.
6. Disconnect, Quit, or a lost app connection sends **SIGINT** to that specific
   child, waits for its cleanup, then ends the runner. It never uses `killall`.

No sudoers edits, root service installation, or automatic login retry loop. A new
connection can ask for administrator approval. OpenConnect retries a network
outage for `reconnectTimeout` seconds; Waterloo's session lifetime and MFA rules
still apply. The green icon follows OpenConnect's tunnel-configuration messages;
it is not an independent campus reachability probe.

## Review map and trust boundary

| File | Responsibility |
| --- | --- |
| `Sources/App.swift` | Native menu, password dialog, connection lifecycle |
| `Sources/Core.swift` | Config, argument construction, auth output parser, redaction |
| `Sources/Keychain.swift` | The three Keychain operations |
| `Sources/IPC.swift` | Private per-session control channel and peer UID checks |
| `Sources/Runner.swift` | The complete per-session privileged launcher |
| `Sources/Capture.swift` | Bounded subprocess output capture |

This app trusts macOS, the local Swift build, and the installed Homebrew
OpenConnect, its libraries, and `vpnc-script`. Those Homebrew files and the local
app bundle can be edited by your account; this is not a boundary against malware
already running as you. There is no new permanent elevation capability. There
is no telemetry, app update mechanism, or network client besides OpenConnect.

Passwords and cookies necessarily exist in process memory while used; this code
does not promise secure erasure of Swift strings. Diagnostic filtering is
defensive, and the app never enables HTTP traffic dumps. Abruptly killing the
root runner, OpenConnect, or the OS can prevent graceful routing/DNS cleanup.

## Validation

The automated checks exercise config rejection, account isolation, session parsing,
certificate handoff, secret-free arguments, diagnostic redaction, shell quoting,
Unix socket permissions, and cancellation. Integration tests use the same runner
and IPC source compiled with `TESTING`: a harmless fake tunnel runs as your user.
The release runner has no test executable override and refuses to run without
root. Tests cover disconnect, GUI EOF/crash, pre-auth cancellation, natural child
failure, malformed sessions, and cleanup completion. `--ui` additionally creates
the native menu bar item and checks that it is on screen, without authenticating.

Live Waterloo authentication, campus reachability, split routing/DNS, sleep/wake,
and teardown require a user-approved login test. A passing fake-tunnel test is
not evidence that those live behaviors work.

Protocol references: [OpenConnect manual](https://www.infradead.org/openconnect/manual.html),
[separating authentication from tunnel privilege](https://www.infradead.org/openconnect/nonroot.html).

# UW VPN

A small native macOS menu bar wrapper around the Homebrew OpenConnect you already
have. Connect, disconnect, edit a JSON file, save a password in the login Keychain.
No third-party GUI framework or downloaded app code.

The menu bar uses connection-node SF Symbols:
`point.3.filled.connected.trianglepath.dotted` when connected and
`point.3.connected.trianglepath.dotted` otherwise. Filled versus outlined nodes
show connection state. AppKit chooses their contrast against the menu bar;
status is also available in the tooltip and menu.

Requires an Apple Silicon Mac running macOS 13+, Xcode 27+ for building, and:

```sh
brew install openconnect
./scripts/build.sh
./scripts/test.sh --ui
./scripts/install.sh
open "$HOME/Applications/UW VPN.app"
```

`build.sh` uses Apple's Swift compiler, asset compiler, and ad-hoc code signing. No package
manager, remote build step, developer account, system extension, or persistent
privileged helper is needed. `test.sh` uses Python 3 to drive a fake tunnel.
Quit the app before replacing an installed build. An ad-hoc signed rebuild can
require granting Keychain access again because its code identity changes.

## Application icon

`Resources/AppIcon.icon` is an editable Apple Icon Composer document, started from
Xcode's bundled macOS Icon Composer template. Its original SVG artwork depicts
two terminals joined by a tunnel; it does not reuse an SF Symbol. Apple supplies
the icon mask, glass treatment, and default/dark/tinted appearances. Open the
document in Icon Composer to edit it. `actool` compiles it into `Assets.car` and
an `.icns` fallback for older macOS releases; neither tool is needed at runtime.
On 2026-10-27 the release build, code signature, icon metadata, and compiled
appearance stacks were checked; macOS returned the new icon for the installed app.

References: [Apple Icon Composer](https://developer.apple.com/icon-composer/),
[Apple's app icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons),
and [SF Symbols usage guidance](https://developer.apple.com/design/human-interface-guidelines/sf-symbols).

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

Choose **Connect**, approve Touch ID (or the macOS administrator password dialog
if Touch ID is unavailable or unsuccessful), enter your WatIAM password in the app's secure field on first use, and
approve Duo on your phone. Subsequent connects use the saved password. The
macOS administrator password is handled by macOS, never by this app. You may
still get Keychain authorization/unlock prompts under your local Keychain policy.

**Set Password…** replaces the saved password for the current config.
**Forget Password** deletes it. Items are scoped to the server, group and username;
changing any of those gives a different Keychain item. Diagnostics are bounded,
redacted, and held only in memory. There is no launch-at-login or auto-connect.

## What runs with privilege

1. The app first launches the bundled `uw-vpn-runner` using `/usr/bin/sudo -k -S`
   with stdin connected to `/dev/null`. On Macs with Apple's `pam_tid` enabled
   for sudo, this offers Touch ID; it cannot collect a password from the app.
   It deliberately avoids `sudo -A`, which disables Touch ID in Apple's PAM module.
   If this attempt fails before a runner connects, the app falls back once to
   `osascript`'s standard `with administrator privileges` dialog. Its AppleScript
   contains executable and socket paths plus your local UID, with no password or
   cookie. Cancelling the connection in the app suppresses the fallback.
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
connection asks for administrator approval. Touch ID uses your existing sudo PAM
policy; the app does not edit it. Macs without `pam_tid` use the password dialog.
OpenConnect retries a network
outage for `reconnectTimeout` seconds; Waterloo's session lifetime and MFA rules
still apply. The connected icon follows OpenConnect's tunnel-configuration messages;
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
| `Resources/AppIcon.icon` | Icon Composer source and original vector artwork |

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

Verified locally on 2026-10-26: release build and code signature validation,
42 core checks, six integration scenarios, and the native menu bar smoke test.
The user completed a real WatIAM/Keychain/Duo login and confirmed Connected.
Waterloo's `checkvpn.uwaterloo.ca` independently reported campus connectivity;
the advertised Waterloo route used the tunnel while a public Internet destination
still used `en0`. Gateway-provided Waterloo DNS servers were installed as both
default and supplemental resolvers; DNS is not restricted to Waterloo queries.

The user also confirmed the updated Touch ID-first connection flow on 2026-10-26.
Between the earlier and updated sessions, the campus route and Waterloo DNS
entries were absent and the local DNS servers were restored. Sleep/wake remains
untested; the controlled disconnect and EOF integration scenarios use a fake
tunnel. The one-time password fallback has automated decision checks; a forced
Touch ID failure followed by the fallback dialog has not been tested live.

Protocol references: [OpenConnect manual](https://www.infradead.org/openconnect/manual.html),
[separating authentication from tunnel privilege](https://www.infradead.org/openconnect/nonroot.html).
Apple's [Touch ID PAM implementation](https://github.com/apple-oss-distributions/pam_modules/blob/main/modules/pam_tid/pam_tid.c)
documents the Aqua session requirement and the askpass exclusion.

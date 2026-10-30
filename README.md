# UWaterloo VPN Tool

A small native macOS menu bar app for the University of Waterloo VPN, powered by
[OpenConnect](https://www.infradead.org/openconnect/).

## Why?

The Cisco client sucks.

## Install

Requires **Apple Silicon**, **macOS 13+**, and **Xcode 27+** to build.

```sh
git clone https://github.com/kcajc/uw-vpn.git
cd uw-vpn
brew install openconnect
./scripts/install.sh
open "$HOME/Applications/UW VPN.app"
```

Builds locally with Apple's tools; no developer account is needed. Quit the app
before reinstalling. A rebuilt app may ask for Keychain access again.

## Use

On first launch, choose **Edit Config…** from the menu bar and set your WatIAM
username in `~/.config/uw-vpn/config.json`:

```json
{
  "server": "https://vpn.uwaterloo.ca",
  "authgroup": "UW-General-Campus",
  "username": "YOUR_WATIAM_USERNAME",
  "duo": "push",
  "reconnectTimeout": 3600
}
```

Choose **Connect**, approve administrator access, enter your WatIAM password on
first use, and approve Duo on your phone. Later connections reuse the saved
password. Touch ID uses your existing sudo setup, with a macOS administrator
password dialog as fallback. The app does not change your sudo configuration.

The config reloads on each connection. Keep all five keys; `push2`, etc. selects
another Duo device, and `reconnectTimeout` is in seconds. Use **Set Password…**
after changing your password, **Forget Password** to remove the saved credential,
and **Diagnostics…** if a connection fails.

## Trust & security

- **Credentials:** your WatIAM password is stored in the macOS login Keychain.
- **Admin access:** each connection needs approval. A temporary root
  runner manages the tunnel and exits after disconnecting. Your Mac's
  admin password is handled by macOS.
- **Privacy:** no telemetry or updater, obviously.
- **Dependencies:** you trust this code, macOS, and your Homebrew OpenConnect,
  its libraries, and `vpnc-script`.
- **Network settings:** OpenConnect applies Waterloo's routes and DNS settings.
  DNS may use Waterloo's servers even for non-campus queries. Normal disconnect
  restores settings; forcibly killing tunnel processes can prevent cleanup.

This is an unofficial personal project, not affiliated with UWaterloo or Cisco.
It has not had an independent security audit.

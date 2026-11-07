# NeoNode

macOS 27 menu bar app (SwiftUI, Liquid Glass) for smart-home devices: Tuya / Smart Life (cloud, including live cameras), Philips WiZ lights and Samsung TVs / Smart Monitors (local Wi‑Fi only).

## Sign in (Smart Life or Tuya Smart account)

1. In Smart Life: Me › Settings › Account and Security › User Code.
2. Paste it into NeoNode, then scan the QR code with Smart Life (scan icon on the Me tab) and confirm.

This is Tuya's QR login from `tuya-device-sharing-sdk`, ported to Swift (`Tuya/SmartLifeClient.swift`).
Tuya only issues it to partners, so NeoNode uses Home Assistant's client ID: Smart Life lists the
authorization as Home Assistant, and it stops working if Tuya revokes that ID. The session is kept in
the login keychain and refreshed automatically.

Fallback: "Use a Cloud project" takes Access ID/Secret from a Tuya Cloud project at platform.tuya.com
with the app account linked (Devices › Link App Account).

## Build

```sh
xcodegen generate
xcodebuild -project NeoNode.xcodeproj -scheme NeoNode -derivedDataPath build build
open build/Build/Products/Debug/NeoNode.app
```

Launch arguments: `-demo` (fake devices, no account), `-window` (show the menu content in a regular window).

## Notes

- Tap a tile to toggle power, `…` for details (brightness, warmth, mode, extra switches, from the device's function spec).
- Devices refresh when the menu opens (at most every 10 s) — no background polling, to stay inside the Cloud project's free API quota.
- The free Cloud trial must be extended every few months on the Tuya platform, or API calls stop.

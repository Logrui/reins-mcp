# Deploying Reins (Flutter) to iOS from Windows using AltStore

This guide shows how to ship the app to your iPhone without a Mac by using:
- GitHub Actions (macOS runner) to build an unsigned IPA
- AltServer/AltStore on Windows to sideload the IPA to your device

## Prerequisites
- Windows PC
- iPhone + USB cable (or same Wi‑Fi network for wireless install)
- Apple ID (free is fine; free certs last 7 days)
- Installed on Windows:
  - iTunes for Windows (from Apple site)
  - iCloud for Windows (from Apple site)
  - AltServer for Windows (installs AltStore onto your device)
- A GitHub repository for this project (to run Actions on macOS)
- Flutter project builds/runs on other platforms locally

## 1) Build unsigned IPA on GitHub Actions
The repository contains a workflow at `.github/workflows/ios-ips.yml` which:
- Sets up Flutter
- Installs CocoaPods
- Builds an unsigned IPA: `flutter build ipa --release --no-codesign`
- Uploads the resulting IPA as a workflow artifact

Trigger it via:
- Push to `main`, or
- Manually: GitHub → Actions → iOS IPA (AltStore) → Run workflow

Output artifact: `reins-mcp-ipa` with one or more `*.ipa` files.

Notes:
- No signing keys are needed. AltServer will re‑sign the IPA using your Apple ID when installing.
- Ensure your target iOS version is compatible (typically iOS 13+).
- Bundle Identifier must be unique; AltStore re-signs but identifier helps avoid conflicts.

## 2) Download the IPA artifact
- Open the workflow run page → Artifacts → download `reins-mcp-ipa`.
- Extract the `.ipa` file locally.

## 3) Install on iPhone using AltStore (Windows)
- Launch AltServer (system tray). Ensure iTunes and iCloud are installed and you are signed in.
- Connect your iPhone via USB (first time recommended) and trust the computer on the phone.
- In AltServer (tray) → Install AltStore → choose your iPhone → enter Apple ID credentials.
- On the iPhone, open AltStore → My Apps → tap "+" → select your `.ipa`.
- AltStore will re-sign and install the app. For free Apple IDs, you must re‑sign every 7 days from AltStore.

## Networking configuration for MCP Gateway
Your iPhone cannot reach `http://localhost:7999` on your PC. Use the PC’s LAN IP instead.
- In the app’s Settings (MCP Server URL), set `http://<PC-LAN-IP>:7999` (e.g., `http://192.168.1.20:7999`).
- Ensure Docker forwards the port (`-p 7999:7999`) and Windows Firewall allows inbound TCP 7999.

### iOS ATS (App Transport Security)
If using plain HTTP, add an ATS exception in `ios/Runner/Info.plist` before building on CI.

Allow all (development only):
```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsArbitraryLoads</key>
  <true/>
</dict>
```

Target just your LAN IP (preferred for dev):
```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSExceptionDomains</key>
  <dict>
    <key>192.168.1.20</key>
    <dict>
      <key>NSExceptionAllowsInsecureHTTPLoads</key>
      <true/>
      <key>NSIncludesSubdomains</key>
      <true/>
    </dict>
  </dict>
</dict>
```
Replace `192.168.1.20` with your PC’s LAN IP.

If you use HTTPS with a self‑signed certificate, either install/trust the cert on the device or use a trusted cert. Remove broad ATS relaxations for production apps.

## Troubleshooting
- AltStore cannot install:
  - Use iTunes + iCloud from Apple’s website (not Microsoft Store versions).
  - Ensure the same Apple ID is used in AltServer and AltStore.
  - Try USB connection first; then enable Wi‑Fi install in AltServer.
- Workflow fails at `pod install`:
  - Ensure `ios/Podfile` and `ios/Runner.xcodeproj` are valid; try `pod repo update` locally if needed.
- App can’t reach gateway:
  - Verify MCP URL uses the PC LAN IP, Docker `-p 7999:7999`, and firewall rules.
  - Confirm ATS exceptions were added before building the IPA.

## Summary
- CI builds unsigned IPA on macOS and publishes it as an artifact.
- Download IPA, then sideload it with AltStore on Windows.
- Point the app to your PC’s LAN IP for the MCP Gateway and, if needed, allow HTTP via ATS exceptions.

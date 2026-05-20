# SPIC iOS Target

This folder contains the first iOS VPN target for SPIC:

- `Runner` is the Flutter host app.
- `PacketTunnel` is the Network Extension target.
- Bundle ID: `xyz.stop2virus.spic`
- Packet tunnel Bundle ID: `xyz.stop2virus.spic.PacketTunnel`
- App Group: `group.xyz.stop2virus.spic`

## Required Apple Capabilities

Create both App IDs in Apple Developer and enable:

- Network Extensions: Packet Tunnel Provider
- App Groups: `group.xyz.stop2virus.spic`

Both the app and the extension need matching provisioning profiles.

## macOS Build Smoke Test

Run on a macOS runner or Mac:

```sh
export GPR_KEY="<github package token for TrustTunnelClient>"
flutter pub get
cd ios
pod install
open Runner.xcworkspace
```

Then select the `Runner` scheme and configure signing for:

- `Runner`
- `PacketTunnel`

The app can be archived only after Apple enables the Network Extension entitlement for the SPIC App IDs.

# TaoScreen Release Notes

English · [简体中文](RELEASE_NOTES.md)

- Direct Connect finds nearby Macs on the LAN. You can also enter a LAN or Tailscale address. Temporary access authenticates the host and requires approval for each session.
- Trusted devices can be authorized for unattended access over Tailscale. The default is view-only. The host can allow keyboard, mouse, and system audio access.
- Use the TaoScreen DMG to install the app for the first time. TaoScreen has its own application and update channel.
- Connection details show the selected IPv4 or IPv6 addresses and identify relay addresses. They clear when the session disconnects.
- The **Video and Audio** settings offer five quality presets. Click the connection indicator to keep the details visible, and use the window toolbar to switch input methods.
- The TaoScreen icon shows two connected displays.
- In authorized account sessions, you can save a remote Mac's login password in the local macOS Keychain and use it to unlock the remote Mac. The app does not upload the password or copy it to the clipboard.
- The remote Mac can lock after an authorized session ends. This also applies when an unexpected disconnect cannot be recovered.
- In-app updates use Sparkle. The download icon opens release notes, then Sparkle downloads, verifies, and installs the update.
- Port forwarding includes per-device rules, duplicate rules, offline editing, and resuming active rules on reconnection. Advanced settings cover TCP or UDP, the reverse direction, and listening interfaces.

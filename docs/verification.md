# Direct device verification

Tested on 1 November 2026. The archived [31 October prototype report](verification-20261031.md) describes the superseded computer-bridge design.

## Current implementation

The ESP32 hosts its own authenticated HTTP MCP endpoint on port 80. The iOS app hosts its own endpoint on port 7801; its ReplayKit extension hosts screen MCP on port 7802 while broadcasting. Each advertises `_mcp._tcp` with its role and device ID. Discovery never publishes credentials. No computer forwards runtime MCP requests or frames.

The app can discover keyboards, select one, provision Wi-Fi, report status, request screen sharing, capture its screen, and stop sharing through MCP. Apple still requires its system broadcast confirmation. Background screen access belongs to the broadcast extension; the foreground app listener recovers when the app returns.

The keyboard exposes pairing, saved-host selection, keyboard input and pointer input. Bonds and the selected host are persisted in ESP32 NVS. A target that has not reconnected leaves input unavailable rather than sending it to another host. Initial Bluetooth pairing uses the target's system settings.

## Evidence

| Check | Host / source | Result |
| --- | --- | --- |
| Portable tool tests and enclosure checks | Windows Maxis, `0ccab44` | Passed; physical endpoint tests and POSIX permission checks were skipped in the Windows run. |
| Tool privacy and error checks | macOS | Six focused tests passed, including private-file permissions. |
| ESP32 firmware compilation | Windows Maxis, `bf56edb` | Passed; 59,044 bytes RAM and 1,120,861 bytes flash. |
| ESP32 provisioning | Physical ESP32-D0WDQ6, USB setup | Wi-Fi connected; device-hosted MCP and keyboard-role mDNS discovered. |
| ESP32 direct MCP | Physical board, `bf56edb`, actual Python MCP SDK | Two endpoint acceptance tests passed: authentication / browser-origin rejection, initialization, six tools, status and unknown-tool handling. Pairing command also passed. |
| mDNS discovery | macOS Bonjour and physical iPad app | App, screen and keyboard roles discovered. The iPad resolved the ESP32 endpoint directly. |
| iOS build, install and launch | Mac / physical iPad and iPhone, `0ccab44` | Passed with development signing. |
| iPhone rendered layout | Existing iPhone 16 Pro Max simulator, `0ccab44` | Passed; simulator evidence only. |
| iPad native MCP and capture | Physical iPad Air 13 M3, `0ccab44` | Two direct screen acceptance tests passed, including real JPEG decoding and missing-token / browser-origin rejection. |
| Broadcast initiation | Physical iPad | MCP opened Apple's Start Broadcast dialog; the paired developer UI tool confirmed it. |
| Capture while another app is foregrounded | Physical iPad, `366da1a` | Direct screen MCP remained live with Settings foregrounded; decoded a fresh frame after 20 seconds. App MCP recovered on return. |
| Bluetooth keyboard input and saved-host switching | Physical iPad / iPhone | Still under verification. The first connection exposed a subscription-before-authentication race, corrected in `0039ce8`. The subsequent `bf56edb` attempt reached the board, requested security successfully, then failed authentication with BLE link timeout (520); no bond was saved. Device proximity and an unlocked second target remain to be checked. No physical input or A → B → A success is claimed yet. |

The obsolete installed Mac bridge executable has been removed and its server is stopped.

The temporary XCTest control harness is a development tool for paired USB device setup and system dialogs. Product MCP endpoints run on the devices and do not depend on that harness.

## Changed screens

The app page was rebuilt on 1 November 2026. The previous page is the one
shipped earlier the same day and captured below; nothing else on the device
changed appearance. No credentials, pairing PINs or personal Settings screens
are published.

| Before | After |
| --- | --- |
| ![iPhone, previous page](screenshots/iphone-direct-ready.jpg) | ![iPhone, rebuilt page](screenshots/iphone-home.jpg) |
| Four sections, two always-visible Wi-Fi fields, Apple's unstyled broadcast control, and state as raw strings. Physical iPad / simulator. | Three cards, one action each. iPhone 16 Pro Max simulator, signed build. |
| No prior dark-appearance capture. | ![iPhone dark, rebuilt page](screenshots/iphone-home-dark.jpg) |
| | The accent has its own dark variant in the asset catalogue; cards use elevated system colours rather than an inversion. |
| ![iPad, previous page](screenshots/ipad-direct-ready.jpg) | ![iPad, rebuilt page](screenshots/ipad-home.jpg) |
| Rows stretched the full width of the iPad with the content ending a third of the way down. | Content is held to a readable column aligned with the navigation title. iPad Air 13 M3 simulator. |

The setup sheet and the Advanced screens are new, with no prior equivalent.
The setup sheet was exercised on the simulator, where it correctly reports
missing Bluetooth at step one and leaves the remaining steps pending.

## Verification for this change

| Check | Host / source | Result |
| --- | --- | --- |
| iOS build | Mac, Xcode 27.1, iphonesimulator | Passed, signed with the UnlikeOtherAI team. |
| Rendered app page | iPhone 16 Pro Max and iPad Air 13 M3 simulators | Passed in light and dark appearance. Screenshots above. |
| Screen-sharing request path | iPhone simulator | The button reaches the confirmation state. The broadcast itself cannot run on a simulator, so live capture is unverified here and still rests on the physical iPad evidence above. |
| Keyboard setup sheet | iPhone simulator | Step states render from the provisioning phase. The Bluetooth path itself is unverified on a simulator. |
| ESP32 firmware compilation | Mac, PlatformIO 6.1.18 | Run locally rather than on Maxis, which has no `uv` installed. |
| Tool tests | macOS | Ten tests passed, two skipped as Windows-only. |
| mDNS discovery and the `ewp-discover` CLI | macOS, live network | Four real endpoints found, including a physical ESP32 and iPad. |

## Identity, naming and firmware safety

Added after an architecture review of the 200-device wall. The review is in
[architecture-review.md](architecture-review.md).

| Check | Host / source | Result |
| --- | --- | --- |
| ESP32 firmware compilation | Mac, PlatformIO 6.1.18 | Passed after merge. 1,137,289 bytes flash (86.8%), 59,764 bytes RAM (18.2%). |
| iOS build | Mac, Xcode 27.1 | Passed. |
| Tool tests | macOS | 43 passed, 2 skipped as Windows-only. |
| Device naming end to end | iPhone 16 Pro Max simulator and macOS Bonjour | Passed. A name entered in the app persisted, re-advertised, and appeared in `ewp-discover` in place of the identifier. |
| Device list grouping | iPhone simulator, live network | Passed. A physical iPad advertising app and screen endpoints appeared as one device; this device was excluded. |

**Nothing in this round was run on an ESP32.** The firmware changes — full
48-bit device ids, per-pairing passkeys, host-bound input, `forget_host`,
`set_name`, `identify`, the CCCD store size and the pairing-starvation fix —
are compile-verified only. The bond-overflow fault they address was found by
reading NimBLE's default store callback, not by reproducing it on hardware.
Flashing a board and re-running the Bluetooth acceptance checks is still
outstanding, and the earlier Bluetooth result above has not been re-attempted.

Renaming a board from the app needs that board's access token, which the app
cannot obtain over Bluetooth yet; the review's P3 covers that handoff.

The `help` tool was added to all three endpoints but has not been exercised
against a physical board or a real MCP client. Keyboard delivery, automatic
reconnection, persistence across reboot and pointer delivery remain as
described above and are not affected by this change.

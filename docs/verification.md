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

### On a physical board, 1 November 2026

Firmware 0.3.0 was built and flashed to the ESP32-D0WDQ6 development board
over USB. The board kept its NVS, so its token, Wi-Fi credentials and setup
code carried over; its id changed from the old 8-hex form to the full 48-bit
`ewp-0cb815c55dc4`, and it rejoined Wi-Fi at the same address. The state it
was replaced from is recorded in the run log; it had no bonds, so nothing
pairable was lost, and 0.2.0 can be restored by building `bf56edb`.

A 29-check acceptance suite was run against that board over its own MCP
endpoint. All 29 passed:

| Area | What was checked |
| --- | --- |
| Protocol | `initialize` names the board and reports 0.3.0; all eleven tools advertised; every description carries the board's name |
| Identity | id carries the full 48-bit MAC; `host_capacity` 8; `store_full` false; Wi-Fi up; `help` states what `notified` does not prove |
| Naming | `set_name` persists and changes the Bluetooth name and every tool description; over-long and non-ASCII names refused |
| Idempotency | a repeated `request_id` replays the first result and does not rename the board a second time |
| Host binding | `press_key` and `move_pointer` refused with no `host_id`, and refused for a host that is not the selected one |
| Bonds | no bonds saved; `forget_host` refuses a wrong `confirm` and an unknown host |
| Identify | runs, advertises as `IDENTIFY <name>`, and bounds its duration |
| Authentication | no token, a wrong token and a browser `Origin` are each rejected with 401 |

Also exercised on that board: `ewp-setup --name` over USB named it and saved
its credentials under the new id; `ewp-fleet status` reported it `ok` and
flagged a device on the network that was not in `wall.json`; `start_pairing`
opened a window, issued a fresh code and advertised under the board's name.

### Two faults found by running it, and fixed

- **Renaming a board took it off the network.** `set_name` ended the mDNS
  responder and let the loop restart it; on ESP32 that leaves the service
  advertised but unresolvable, so the board kept answering on its IP while
  disappearing from discovery until a power cycle. Setting the TXT item again
  in place fixes it. Verified by renaming the board and finding it still
  listed, under its new name, without a reboot.
- **`ewp-fleet` refused names the board accepts.** The board takes any
  printable ASCII name, so "Row 4 Seat 2" is legal, but the tool required a
  name that was already a valid MCP server key and rejected it. The key is now
  derived from the name instead.

### Not verified

**No Bluetooth pairing or input was proved.** The chain from `start_pairing`
through a bonded host to a keystroke landing on a screen is still unverified,
exactly as it was before this round. Reaching it needs a target device to pair
with, and none was available: both physical iOS devices were locked, which
this product does not and should not work around, and permission to drive this
Mac's Bluetooth settings was declined. The board's side — opening the window,
issuing a per-window code, advertising under its name — is confirmed; what
happens after a host accepts the code is not.

The earlier Bluetooth failure (`authentication_state: -1`, disconnect reason
520) was reproduced on the old firmware before flashing, and its cause is
understood: the board displays a passkey that only reaches a serial console,
so a person pairing from a phone has no way to read it. `start_pairing`
returns the code over MCP, so an agent-driven pairing has one; a person using
the app's Bluetooth setup flow still does not. The review's P3 covers that
handoff and it is not implemented.

Also unverified: mDNS recovery after a Wi-Fi drop uses the same end-and-begin
pattern that was just fixed for renames, and was not exercised. `identify`
has no LED on this board. Nothing has been tested with more than one board.

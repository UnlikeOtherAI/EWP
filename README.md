# EWP — Expensive Wall of Phones

EWP gives a phone or tablet eyes and a Bluetooth keyboard/mouse that an MCP client can control directly. The ESP32 and the iPhone/iPad app each host MCP on the device and advertise it through mDNS. There is no computer bridge, cloud service or Nessie dependency.

The ESP32 also works with devices that have no EWP app. Pair them once in their Bluetooth settings; the board keeps their bonds and exposes pairing and host selection through its own MCP.

## Direct endpoints

All endpoints use authenticated, stateless MCP Streamable HTTP at `/mcp` and advertise `_mcp._tcp.local.` with `id`, `role` and `path` TXT records. Credentials are never advertised.

| Endpoint | Runs on | Purpose |
| --- | --- | --- |
| Keyboard MCP, port 80 | ESP32 | Pair targets, select a saved host, send keyboard/mouse input |
| App MCP, port 7801 | iPhone/iPad app | Inspect the app, provision Wi-Fi, discover devices, initiate screen sharing |
| Screen MCP, port 7802 | The app's ReplayKit extension on the same iPhone/iPad | Read the whole screen while other apps are foregrounded; stop sharing |

The screen endpoint runs in the broadcast extension because iOS suspends ordinary apps in the background. It is part of the iOS app, on the iOS device. Frames stay in that process's memory; no receiver on another computer is involved. Both iOS advertisements carry the same device ID.

A client discovers these endpoints and connects to them directly, with `Authorization: Bearer <device-token>`. An MCP client must support local HTTP Streamable HTTP endpoints; mDNS discovery does not automatically register tools in every client.

For a one-off discovery check:

```sh
uv run --project tools ewp-discover
```

This command lists endpoints and exits. It does not serve or forward MCP.

## One-time setup

### iPhone or iPad

Build the shared iOS app with Xcode, select your development team for **EWP** and **Broadcast**, then install **EWP**. Both targets share the `$(AppIdentifierPrefix)com.unlikeotherai.ewp` Keychain group. No App Group or Mac service is needed.

```sh
xcodegen generate --spec ios/project.yml
open ios/EWP.xcodeproj
```

Allow Bluetooth and Local Network access. EWP creates its own random MCP credential in Keychain and advertises its app endpoint. **Copy MCP access token** copies that credential for the client you are configuring.

Call `start_screen_sharing` over the app's MCP to initiate Apple's screen-broadcast flow. Confirm **Start Broadcast** in the system dialog. This is a request for visible system capture, not silent authorization. Use the screen endpoint for eyes while controlling other apps.

### ESP32

The development board is an ESP32-DevKitC V4 with an ESP32-D0WDQ6 revision 1, 4 MB flash and a CP2102 serial bridge. USB supplies power/programming; the keyboard and mouse use Bluetooth, not USB HID.

Build and flash the firmware with PlatformIO:

```sh
uvx --from platformio==6.1.18 --with pip platformio run --project-dir firmware
uvx --from platformio==6.1.18 --with pip platformio run --project-dir firmware \
  --target upload --upload-port /dev/cu.usbserial-0001
```

Choose the actual serial port. Use 115200 baud on an unreliable USB link. Preserve existing firmware and settings before replacing a board's software.

For Wi-Fi, choose the nearby keyboard in EWP and enter a 2.4 GHz network name and password. This provisions Wi-Fi only; the ESP32 keeps its own independent MCP token. Alternatively, configure it over USB without installing the app:

```sh
uv run --project tools ewp-setup --port /dev/cu.usbserial-0001 \
  --wifi-file /private/path/to/wifi.json
```

The private JSON file contains `ssid` and `password` strings and must have mode `600` on macOS/Linux. Keep it outside the repository. The setup client boots the application through the CP2102 reset lines, provisions the board, saves its MCP token and pairing PIN privately under `~/.config/ewp/`, and exits. Running it without `--wifi-file` retrieves access information without changing Wi-Fi. It is a one-time setup tool, not a runtime dependency.

BLE Wi-Fi setup is authenticated and encrypted and opens for five minutes after reset. The board generates and retains its own MCP token in NVS. Neither ordinary boot logs nor mDNS contain that token.

## Pairing and switching targets

1. Call the ESP32's `start_pairing`, optionally with a name for the new target. Existing bonds stay saved. Input stops while a new target is being paired.
2. In the target's Bluetooth settings, pair **UnlikeOtherAI Keyboard …** using the returned pairing code. This works without EWP installed on the target.
3. Call `list_hosts` to see saved host IDs. They come from the bonded identity address, not a rotating Bluetooth address or a list position.
4. Call `select_host` with the saved `host_id`; optionally pass `name` to label an existing bond. The ESP32 reserves input for that target and advertises with a connection allowlist. Poll `device_status` until that host subscribes before sending input.

The central device decides whether and when to reconnect. An unavailable target leaves input disabled; the ESP32 must never silently route input to another bonded host. The current board configuration holds eight bonds. If full, pairing fails without deleting an old bond.

For pointer control on iPhone, enable **Settings → Accessibility → Touch → AssistiveTouch**. Keyboard navigation may require Full Keyboard Access. Initial pairing and these OS settings are one-time configuration.

## MCP tools

| ESP32 tool | Purpose |
| --- | --- |
| `device_status` | Firmware, Wi-Fi, pairing and selected-host state |
| `list_hosts` | Persisted bonds, optional names and selected/connected state |
| `start_pairing` | Open a three-minute pairing window; retain existing bonds |
| `select_host` | Select one saved target; reject input until it reconnects |
| `press_key` | Press/release one HID usage with optional modifier bitmask |
| `move_pointer` | Relative motion, wheel scrolling or a left click |

| iOS app tool | Purpose |
| --- | --- |
| `get_status` | App/server, discovery, nearby keyboards and capture state |
| `get_screen` | App screen, or shared device screen when capture is live |
| `start_screen_sharing` | Initiate Apple's broadcast confirmation |
| `stop_screen_sharing` | Stop the on-device broadcast |
| `discover_devices` | Restart mDNS discovery and report nearby devices |
| `select_esp32` | Select a nearby board for setup |
| `configure_esp32` | Configure Wi-Fi through encrypted BLE; optionally submit private form values already entered on the device |

The screen endpoint exposes `get_status`, `get_screen` and `stop_screen_sharing`. It rejects frames older than five seconds. It retains only the latest JPEG, at up to 1280 pixels on the longer side and two frames per second; audio is ignored.

A successful Bluetooth notification does not prove that the target acted on input. Verify the subsequent screen. Unlocking a locked device and bypassing system capture consent are not implemented.

Local HTTP is intended for a trusted LAN. Do not expose these ports to the internet. MCP credentials and screen frames must not be logged or committed.

## Verification and enclosure

See [verification](docs/verification.md) for source revisions and the distinction between builds, direct MCP protocol checks and physical input/capture acceptance. The optional `tools/` package contains client and development-test utilities, not a product server.

The [printable enclosure](docs/enclosure.md) includes Blender and STL sources. It remains a first-print design; physical fit and printing are unverified.

[MIT license](LICENSE).

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

Allow Bluetooth and Local Network access. EWP creates its own random MCP credential in Keychain and advertises its app endpoint. **Copy Agent Prompt** gives you one block of text holding the endpoint, the credential and an instruction to call `help` first; **Send to Another Device** shares the same text through the system share sheet, which is the easiest way to get it from a phone to the computer running your client. The raw credential on its own is under **Advanced → Access**.

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

For Wi-Fi, tap **Set Up Keyboard** in EWP and follow the four steps: the app finds the board over Bluetooth, connects, takes a 2.4 GHz network name and password, and then waits for the board to confirm it joined. This provisions Wi-Fi only; the ESP32 keeps its own independent MCP token. Alternatively, configure it over USB without installing the app:

```sh
uv run --project tools ewp-setup --port /dev/cu.usbserial-0001 \
  --wifi-file /private/path/to/wifi.json
```

The private JSON file contains `ssid` and `password` strings and must have mode `600` on macOS/Linux. Keep it outside the repository. The setup client boots the application through the CP2102 reset lines, provisions the board, saves its MCP token and pairing PIN privately under `~/.config/ewp/`, and exits. Running it without `--wifi-file` retrieves access information without changing Wi-Fi. It is a one-time setup tool, not a runtime dependency.

BLE Wi-Fi setup is authenticated and encrypted and opens for five minutes after reset. The board generates and retains its own MCP token in NVS. Neither ordinary boot logs nor mDNS contain that token.

## Pairing and switching targets

1. Call the ESP32's `start_pairing`, optionally with a name for the new target. Existing bonds stay saved. Input stops while a new target is being paired.
2. In the target's Bluetooth settings, pair the Bluetooth name that call returned — **EWP _name_**, or **EWP _last six MAC digits_** on a board that has not been named — using the `pairing_code` from that same call. Each pairing window issues a fresh code, so an earlier one will not work. This needs no EWP app on the target.
3. Call `list_hosts` to see saved host IDs. They come from the bonded identity address, not a rotating Bluetooth address or a list position.
4. Call `select_host` with the saved `host_id`; optionally pass `name` to label an existing bond. The ESP32 reserves input for that target and advertises with a connection allowlist. Poll `device_status` until that host subscribes before sending input.

The central device decides whether and when to reconnect. An unavailable target leaves input disabled; the ESP32 must never silently route input to another bonded host. The current board configuration holds eight bonds. If full, `start_pairing` fails rather than discarding one; call `forget_host` to free a slot deliberately.

For pointer control on iPhone, enable **Settings → Accessibility → Touch → AssistiveTouch**. Keyboard navigation may require Full Keyboard Access. Initial pairing and these OS settings are one-time configuration.

## MCP tools

Every endpoint exposes `help`. It returns what the device is, the order to use its tools in, and what a result does not prove, so a client that arrives with only a URL can orient itself without being told.

| ESP32 tool | Purpose |
| --- | --- |
| `help` | What this board is, how to pair and select a target, what `notified` does not mean |
| `device_status` | Name, firmware, Wi-Fi, pairing and selected-host state |
| `list_hosts` | Persisted bonds, optional names and selected/connected state |
| `start_pairing` | Open a three-minute pairing window with a fresh code; retain existing bonds |
| `cancel_pairing` | Close that window now and go back to the selected host |
| `select_host` | Select one saved target; reject input until it reconnects |
| `forget_host` | Delete one bond to free a slot; needs `confirm` with the board's id |
| `set_name` | Name the board; the name reaches the Bluetooth name, mDNS and every tool description |
| `identify` | Make the board announce itself so you can find it on a wall |
| `press_key` | Press/release one HID usage on `host_id`, with an optional modifier bitmask |
| `move_pointer` | Relative motion, wheel scrolling or a left click on `host_id` |

Input tools take the `host_id` you selected, so a second agent calling `select_host` cannot silently redirect your keystrokes. Every tool that changes something accepts a `request_id`, and repeating one returns the first result instead of acting twice.

| iOS app tool | Purpose |
| --- | --- |
| `help` | What this device is, how to start sharing, where to find the keyboard that types on it |
| `get_status` | App/server, discovery, nearby keyboards and capture state |
| `get_screen` | App screen, or shared device screen when capture is live |
| `start_screen_sharing` | Initiate Apple's broadcast confirmation |
| `stop_screen_sharing` | Stop the on-device broadcast |
| `discover_devices` | Restart mDNS discovery and report nearby devices |
| `select_esp32` | Select a nearby board for setup |
| `configure_esp32` | Configure Wi-Fi through encrypted BLE; optionally submit private form values already entered on the device |

The screen endpoint exposes `help`, `get_status`, `get_screen` and `stop_screen_sharing`. It rejects frames older than five seconds. It retains only the latest JPEG, at up to 1280 pixels on the longer side and two frames per second; audio is ignored.

A successful Bluetooth notification does not prove that the target acted on input. Verify the subsequent screen. Unlocking a locked device and bypassing system capture consent are not implemented.

Local HTTP is intended for a trusted LAN. Do not expose these ports to the internet. MCP credentials and screen frames must not be logged or committed.

## Choosing devices for a session

A client that loads every endpoint of a large wall holds hundreds of tool schemas, and nothing in an endpoint says where on the wall it is. `ewp-fleet` is setup-time tooling for that. It reads mDNS and a file you keep, prints a report or writes a file, and exits. It carries no MCP traffic and nothing keeps running.

Describe the wall in `~/.config/ewp/wall.json`, or pass `--wall`. The file holds names and positions, never tokens:

```json
{"devices": [
  {"id": "ewp-240ac4a1b2c3", "name": "R4-CTRL-1", "role": "controller", "row": 4},
  {"id": "9f0c1c64-0b7e-4c1d-9a55-3e0d2f6f7a10", "name": "R4-01", "role": "phone",
   "row": 4, "col": 1, "controller": "R4-CTRL-1", "group": ["ios18"]}
]}
```

`id` is the `device_id` that `ewp-discover --json` shows. `name` is 1-32 letters, digits, `-` or `_`; it becomes the MCP server name, so it prefixes every tool. `role` is `phone`, `tablet`, `computer` or `controller`. A `computer` runs no EWP endpoint and is only reached through its `controller`, which is the id or name of the board that types on the device. `token_file` defaults to `~/.config/ewp/<id>.token`, where `ewp-setup` leaves a board's token; save a phone's token there yourself from the app's Advanced → Access, with mode `600`. `address_hint` is a hostname tried only when mDNS does not show the device.

```sh
uv run --project tools ewp-fleet status
uv run --project tools ewp-fleet compose --group row4 --out ~/sessions/row4.mcp.json
```

`status` listens for mDNS, asks each device that answers for its status, and prints one line per device: `ok`, `degraded` (found but not usable: the app is up and screen sharing is not, the token is rejected, two devices share an id), `missing`, or `n/a` for a computer. A phone is `ok` when its screen endpoint reports live frames. Endpoints on the network that are not in `wall.json` are listed after the wall. It exits non-zero unless every device is `ok`; `--json` gives the same result for a script. Uptime, reset reason and signal strength are shown once the firmware reports them.

`compose` writes an MCP client configuration for the part of the wall one session needs. Choose with `--group` (a tag from `group`, or `row4` and `col2` from positions), `--device`, `--controller` (that controller and every device it serves) or `--all`; repeat the flags to combine. Whatever you choose brings the controller that types on it. A phone is represented by its screen endpoint and a controller by its keyboard endpoint, each as a server named after the device, so the client sees `mcp__R4-01__get_screen`. Endpoint URLs use the live mDNS hostname, falling back to `address_hint`. If a chosen device cannot be found nothing is written, unless you pass `--skip-missing`; an existing `--out` file is replaced only with `--force`.

The output is the JSON that Claude Code reads with `claude --mcp-config`. It contains the chosen devices' bearer tokens, so it is written with mode `600`. Keep it out of git and shared folders, and delete it when the session is over. Token files must themselves be private, and tokens never appear in arguments or output.

## Verification and enclosure

See [verification](docs/verification.md) for source revisions and the distinction between builds, direct MCP protocol checks and physical input/capture acceptance. The optional `tools/` package contains client and development-test utilities, not a product server.

The [printable enclosure](docs/enclosure.md) includes Blender and STL sources. It remains a first-print design; physical fit and printing are unverified.

[MIT license](LICENSE).

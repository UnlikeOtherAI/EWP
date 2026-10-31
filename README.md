# EWP — Expensive Wall of Phones

An ESP32 keyboard and mouse, an iPhone/iPad screen-sharing app, and a local MCP server for Claude. No cloud service or Nessie integration is required.

The companion app discovers the ESP32 and the computer bridge through Bonjour. It can configure 2.4 GHz Wi-Fi over BLE. After you confirm Apple's screen broadcast dialog, a ReplayKit extension sends JPEG frames to the bridge. Claude reads those frames and sends keyboard or relative pointer input through the ESP32.

This is an early prototype. Firmware compilation, application builds, transport tests, and physical-device acceptance are separate checks; see [verification](docs/verification.md) for what was actually tested.

## Hardware and software

- ESP32-DevKitC V4 with an ESP32 module supporting BLE. The connected development board is an ESP32-D0WDQ6 revision 1, with 4 MB flash and a CP2102 USB serial bridge.
- iPhone or iPad running iOS/iPadOS 17 or later. An Apple development team is needed to install the companion app from source.
- A computer on the same trusted local network, Python 3.11+, and [uv](https://docs.astral.sh/uv/).
- Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) for the Apple app; [PlatformIO](https://docs.platformio.org/) for the firmware.

The ESP32 acts as a BLE peripheral; USB powers/programs it. A classic ESP32 cannot act as a native USB keyboard through its CP2102 port. The phone/tablet must pair with its Bluetooth keyboard/mouse.

## Start the MCP bridge

```sh
uv sync --project bridge --frozen
uv run --project bridge ewp
```

The command starts both the stdio MCP server and the local HTTP frame receiver, on port 8765. It advertises `_ewpbridge._tcp` through Bonjour. Use `--advertise-ip 192.168.1.10` to select an interface on a computer with several network connections. Use `--http-only` for manual receiver testing without an MCP client; do not run two receivers on the same port.

On first start, EWP creates a random pairing token in `~/.config/ewp/token`. Copy that token into the companion app's **Pairing token** field. Keep this file private. The same token authenticates the ESP32 after Wi-Fi setup. Neither tokens nor frames are written to application logs.

For Claude Desktop, add an `ewp` entry to your existing `mcpServers` configuration, replacing the paths with absolute paths on your computer:

```json
{
  "mcpServers": {
    "ewp": {
      "command": "/absolute/path/to/uv",
      "args": ["run", "--project", "/absolute/path/to/EWP/bridge", "ewp"]
    }
  }
}
```

Keep existing MCP server entries when editing this file. Start the bridge through Claude instead of running a second copy in a terminal.

## Build and flash the ESP32

```sh
uvx --from platformio==6.1.18 --with pip platformio run --project-dir firmware
uvx --from platformio==6.1.18 --with pip platformio run --project-dir firmware --target upload --upload-port /dev/cu.usbserial-0001
uvx --from platformio==6.1.18 --with pip platformio device monitor --port /dev/cu.usbserial-0001 --baud 115200
```

Choose the actual serial port for your machine. If the USB link is unreliable, use 115200 baud for uploading. Preserve existing firmware before replacing it if it may contain something you need; never publish a flash backup containing credentials.

The serial console prints the board's name and its six-digit Bluetooth pairing code. This board has no display. Keep that code available for the initial iOS pairing dialog. Wi-Fi provisioning is open for five minutes after reset; resetting the board reopens setup without deleting the stored Wi-Fi connection or bonds.

For a read-only hardware check before pairing, run `uv run --with bleak firmware/check_ble.py --name ewp-your-board-name`. This checks the advertised services and reads the provisioning status; it does not enter Wi-Fi credentials or send input.

## Install and connect the companion app

```sh
cd ios
xcodegen generate
open EWP.xcodeproj
```

Select your development team for **EWP** and **Broadcast**, then run **EWP** on the physical iPad/iPhone. Both targets share the `$(AppIdentifierPrefix)com.unlikeotherai.ewp` Keychain access group for the bridge connection. There is no separate App Group registration.

1. Allow Bluetooth and Local Network access. Start the bridge on the computer.
2. Choose the discovered bridge, enter its pairing token, and tap **Connect bridge**.
3. Choose the nearby ESP32, enter the 2.4 GHz Wi-Fi name and password, then tap **Connect ESP32 to Wi-Fi**. Enter the serial-console pairing code if iOS asks. Wait for the app's Wi-Fi confirmation.
4. In **Settings → Bluetooth**, pair the ESP32 keyboard. If it is already paired through provisioning, check that it is connected. One ESP32 controls one paired target in this version.
5. For pointer control on iPhone, enable **Settings → Accessibility → Touch → AssistiveTouch**. Keyboard navigation may also need Full Keyboard Access, depending on the action.
6. Return to EWP and tap the broadcast icon beside **Start screen sharing**. Select **EWP Screen Sharing** and confirm **Start Broadcast** in Apple's system interface.

The app says **Screen sharing is live** only after the receiver has a recent frame. Stop sharing using the system recording indicator. Audio is ignored; only the latest screen frame is retained in memory, with no recording history.

## MCP tools

| Tool | Purpose |
| --- | --- |
| `list_devices` | List ESP32 input bridges and companion screen sessions. These have separate IDs. |
| `device_status` | Check firmware identity and whether a HID host is subscribed. |
| `get_screen` | Return the newest frame as an MCP image. Reject frames older than five seconds. |
| `press_key` | Press and release a HID usage, with an optional modifier bitmask. |
| `move_pointer` | Relative movement, wheel scrolling, or a left click. Deltas are −127…127. |
| `wait_for_capture` | Wait for a new frame after manual broadcast confirmation. |

Use the ESP32 `id` from `input_devices` for input tools; use a `session_id` from `screens` for `get_screen`. The companion installation's `device_id` identifies its capture stream. HID notifications do not prove that iOS acted on input; inspect the following screen frame.

## Limits

- Bluetooth pairing and Apple's broadcast confirmation remain visible system interactions. Silent screen-capture authorization is not implemented.
- Automatic capture startup, recovery from a locked phone, and switching one ESP32 between multiple phones are not implemented. The current firmware routes input to one subscribed host and rejects a second host.
- ReplayKit is the compatibility path for this version. The iOS 27 ScreenCaptureKit path needs separate implementation and physical testing.
- Bonjour needs a shared local network with multicast discovery. Guest Wi-Fi isolation and some VPNs block it. The bridge URL field provides a manual IPv4 or `.local` fallback.
- Local HTTP carries frames and bearer credentials without transport encryption. Use a trusted LAN and do not forward the receiver or ESP32 ports to the internet. BLE provisioning uses authenticated, encrypted pairing.
- This prototype has a latest-frame ceiling of 1280 pixels on the longer side and two frames per second. It is a visual-control feed, not a video recorder.

See the [enclosure](docs/enclosure.md) for the printable case and fit assumptions.

## Checks

```sh
uv run --project bridge python -m unittest discover -s bridge/tests -v
uvx --from platformio==6.1.18 --with pip platformio run --project-dir firmware
xcodebuild -project ios/EWP.xcodeproj -scheme EWP -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## License

[MIT](LICENSE).

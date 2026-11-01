# EWP architecture review: the 200-phone wall

Reviewed revision: `3366865` on `pr/app-design-20261101`. Another session is actively committing to this branch; uncommitted edits to `ios/EWP/CompanionView.swift` and `ios/EWP/DesignSystem.swift` were present and are not reviewed. All file:line references are to `3366865`. The firmware, `ios/Shared/*`, `ios/Broadcast/*`, `tools/ewp_tools/setup.py` and `platformio.ini` have not changed since `987da6e`, so those references also hold against that commit. Library behaviour is quoted from the pinned versions in `firmware/platformio.ini` (NimBLE-Arduino 2.3.6, espressif32 6.12.0). Anything I could not verify from source or on hardware is marked **verify**.

Scope: design and architecture only. Nothing here has been implemented. Section 12 is written so that one agent can pick up one piece without reading the rest.

Classification used throughout:

- **A — broken today**: fails with one board and one phone in the owner's hands.
- **B — breaks at 200**: works for the prototype, does not survive the wall.
- **C — nice to have**: improves the result but nothing fails without it.

---

## 0. Findings summary and ranked recommendations

| # | Finding | Class | Evidence | Fix |
|---|---|---|---|---|
| 1 | **Device identity collapses to one byte.** `deviceId` is the low 32 bits of `ESP.getEfuseMac()`, which are the three OUI bytes plus one unique byte; the Bluetooth name takes the six hex digits that are the OUI. Every board from one Espressif OUI batch advertises the *same* name, and only 256 IDs exist per OUI. | A | `firmware/src/main.cpp:379,398` | P1 |
| 2 | **BLE first run cannot complete without a serial console.** The provisioning write needs an authenticated bond, so iOS asks for a passkey that is printed only on serial. Even after Wi-Fi joins, the board's MCP token exists only behind the USB `access` command, so the phone-only path never yields a usable endpoint. The provisioning phone also consumes a bond slot. | A | `main.cpp:383,401-403,411,437`; `ios/EWP/Provisioning.swift:41` | P3 |
| 3 | **Pairing starves when any other bonded phone is in range.** The pairing window drops the whitelist; previously bonded iPhones reconnect within a second, take the single `pairingHandle`, get disconnected by `onAuthenticationComplete`, and loop. On a wall every bonded phone is always in range. | A | `main.cpp:188-195,215-219` | P2 |
| 4 | **"No bond is ever deleted" is false.** `CONFIG_BT_NIMBLE_MAX_CCCDS` is left at NimBLE's default of 8 while bonds are raised to 8. Each bonded host stores 2–4 CCCDs. NimBLE's default store callback answers a CCCD overflow with `ble_gap_unpair_oldest_except`, silently deleting the oldest bond. If that bond was the selected host, `restartAdvertising` returns false forever and the board stops advertising entirely. | A | `firmware/platformio.ini:10-12`; `main.cpp:97,127,146,400,466-468`; README:76 | P2 |
| 5 | **Input is not bound to a host.** `press_key`/`move_pointer` send to whatever is connected now. A concurrent `select_host` from a second agent reroutes the first agent's keystrokes to a different phone after reconnect. | A | `main.cpp:337-360` | P2 |
| 6 | **Provisioning has no failure channel and no re-open path.** Wrong password looks like "joining" until a 25 s client timeout; the board never reports the Wi-Fi disconnect reason; the user is told to reset a board sealed in an enclosure with no button access; the board cannot list the SSIDs it sees. | A | `main.cpp:241,470-472,488`; `Provisioning.swift:38,197`; `docs/enclosure.md:3` | P3 |
| 7 | **Static passkey reused for every pairing, and a pairing window auto-opens for five minutes after every power cycle when no host is selected.** With LE Secure Connections, a static passkey leaks across repeated pairing attempts; a hub brownout reopens 20 boards for pairing. | A (security) | `main.cpp:380-383,400,403` | P2 |
| 8 | **`provisionUntil` is compared unsigned.** After 49.7 days of uptime `millis() > provisionUntil` is false forever and the setup window is permanently open. | A | `main.cpp:218,241,488` | P2 |
| 9 | **No `forget_host`, rename, identify, factory reset, OTA, watchdog, LED, or button handling.** The only recovery from a wedged board is a USB cable and a screwdriver. | A→B | whole of `main.cpp`; `docs/enclosure.md` | P2, P4, P5 |
| 10 | **Topology arithmetic does not close.** "A handful" of controllers × 8 bonds ≠ 200 targets, and each switch costs 2–30 s of iOS reconnection. The switching model cannot be "seamless" at 200:5; it is a cost optimisation that trades reliability. | B | `main.cpp:159-167,400`; README:76 | D1, P6 |
| 11 | **The iOS side has no fleet path.** Token leaves the phone only via clipboard/share sheet; the app endpoint is dead whenever another app is in front; screen sharing needs a human tap per phone per session; development signing is capped at 100 devices per product family and expires yearly. | B | `ios/EWP/CompanionModel.swift:164,200,236`; README:33,40 | D2, P7 |
| 12 | **One MCP server per endpoint does not fit an agent.** 200 phones + controllers ≈ 400 server entries and ~2,000 tool schemas in the client. Addressing "third phone in row 4" is impossible: nothing carries a human name or a position. | B | `ios/Shared/MCPServer.swift:55`; `main.cpp:479` | D3, P1, P8 |
| 13 | **Radio and network reality.** 200 phones plus controllers on 2.4 GHz; ESP32 time-shares one radio between Wi-Fi and BLE; WPA2-PSK lets any wireless peer decrypt screen frames; mDNS may be filtered; iOS randomises MACs per SSID. | B | `main.cpp:389` (no hostname, no static IP) | D4, P9 |
| 14 | **Verification is optional rather than natural.** `host_action_verified:false` is honest, but nothing lets an agent ask "did the screen change since I sent that?" | B | `main.cpp:348,360`; `ios/Broadcast/SampleHandler.swift:72` | P10 |
| 15 | **Input surface is a prototype.** One key per report, no modifier-only press, no hold, no consumer keys (Home), no right button, click and move share one report, relative pointer only, HID usage numbers instead of key names, no text entry. | C (B for computers) | `main.cpp:13-23,312-313,345-358` | P11 |

**Ranked recommendations (what to build, in order):**

1. **P1 Identity and naming** — full 48-bit MAC in `deviceId`, persisted human `name`, `name`/`fw` in mDNS TXT, name in `serverInfo` and tool descriptions, `set_name`, `identify`. Everything else depends on telling devices apart.
2. **P2 Firmware safety** — bind input to `host_id`; fix pairing starvation; set `MAX_CCCDS`; random passkey per pairing; no auto-pairing at boot; recover from a missing selected bond; `forget_host`; signed time arithmetic; `request_id` idempotency.
3. **P3 Provisioning v2** — setup window open whenever Wi-Fi is down plus on-demand (`open_setup`, BOOT long-press); Wi-Fi failure reasons and SSID scan over BLE; provisioning without bonding (X25519 + label code); token handoff over the same session; a user LED and reachable button in the BOM/enclosure.
4. **P4 Self-healing and observability** — task watchdog, `reset_reason`, uptime, RSSI, heap, Wi-Fi reconnect policy, HTTP on its own task so long-polls never stall BLE housekeeping.
5. **P6 + D1 Topology** — decide 1:1 controllers vs. zoned switching; raise bonds; `select_host(wait_seconds)`; leases.
6. **P7 + D2 iOS fleet** — QR token handoff, `identify`, `set_name`, name in TXT, device info, "sharing lost" state; decide TestFlight vs. ABM/MDM for 200 installs.
7. **P8 + D3 Inventory and session composition** — `wall.json` (id → name, row/col, controller, token file), `ewp-fleet status`, `ewp-fleet compose` that writes a per-session MCP client config. Setup-time tooling, not a runtime bridge.
8. **P10 Screen verification semantics** — `frame_id`, `wait_for_change`, `since_frame_id`, region crop; input `sequence` on the controller.
9. **P5 OTA, factory reset, partition headroom.**
10. **P11 Input richness** — `type_text`, key names, chords, hold, consumer page, pointer buttons, absolute pointer report for computers, LED output report as an end-to-end liveness probe.
11. **P9 + D4 Network plan** — WPA3-only lab SSID, phones on 5 GHz, controllers on a dedicated 2.4 GHz SSID or Ethernet, VLAN with mDNS allowed, DHCP reservations, Private Wi-Fi Address off.

**Owner decisions that gate the above** (I cannot make these from the code):

- **D1** One controller per phone (ESP32-C3-class boards, no switching) versus a handful of controllers switching across zones. See §4.
- **D2** How 200 iOS installs are distributed and kept alive: TestFlight (90-day re-install, human taps), Apple Business Manager + MDM (supervision, silent install, Auto-Lock/wallpaper/Wi-Fi profiles), or accept the 100-device development cap. See §7.
- **D3** Whether a *setup-time* tool that writes the MCP client's config for a chosen subset of the wall is acceptable under "no computer bridge". It carries no device traffic. See §11.
- **D4** Whether controllers may move to Ethernet/PoE (e.g. Olimex ESP32-POE) for the production wall. This removes the provisioning problem and the 2.4 GHz contention at the cost of a new enclosure. See §5.

---

## 1. Out-of-box first run

### What happens today, in order

The board has no user LED (the DevKitC V4 carries only a power LED; `docs/enclosure.md:3,7` places the single aperture over it) and no button reachable through the enclosure. "What the user sees on the board" is therefore: a red LED that is on. Every state below is invisible on the board itself.

| Step | Board | Phone (EWP app) | Dead end? |
|---|---|---|---|
| 0 | Blank DevKitC: no firmware. Must be flashed over USB (`README:48-56`). | — | A computer is already required. |
| 1 | Power on. Serial prints `EWP ewp-xxxxxxxx` and the pairing code once (`main.cpp:383`). Opens a 5-minute provisioning window (`:384`) and, with no bonds, a 5-minute pairing window (`:400`). Advertises as `UnlikeOtherAI Keyboard` + six hex digits that are the OUI (`:398`), i.e. the same name as every sibling board. | "Looking for a keyboard…" → "Choose the keyboard to set up." shows N identical names. | Cannot tell boards apart. |
| 2 | On connect, `startSecurity` is called for every central (`:201`), with bonding + MITM + SC (`:401`) and `DISPLAY_ONLY` (`:402`). | iOS shows "Bluetooth Pairing Request: enter the code displayed on UnlikeOtherAI Keyboard". The app's own message says the code comes from the serial console (`Provisioning.swift:41` family of messages; the old string was explicit about it). | **Dead end 1.** No serial console → no code → no provisioning. |
| 3 | If the code was known: bond saved (slot 1 of 8). The write requires `isAuthenticated()` (`:241`), succeeds, `WiFi.begin` runs (`:472`). Status notifies `joining` then `connected` with IP. | "Waiting for the keyboard to join Wi-Fi…" → "The keyboard is on Wi-Fi. Pair it in Settings → Bluetooth." | Misleading: this phone *is* already bonded. To pair a *different* target you need `start_pairing` over MCP. |
| 4 | MCP token exists only in NVS; the only read path is the USB `access` command (`:437`). | Nothing. The app never receives the board's token. | **Dead end 2.** The user has a board on Wi-Fi and no way to call it. |
| 5 | Wrong password: `WiFi.status()` cycles; the board reports `joining` indefinitely (`:486-488`). | After 25 s: "The keyboard did not join Wi-Fi. Check the name and password… Reset the keyboard to try again." (`Provisioning.swift:197`). | **Dead end 3.** Reset means opening the case. |
| 6 | After 5 minutes `setup_open:false`. | "The setup window has closed. Reset the keyboard to reopen it for five minutes." (`:38`). | Same. |

So the honest first-run story is: a board is always commissioned at a bench with USB (`ewp-setup`), and BLE provisioning is only usable by the person who also has the serial console. That is acceptable for a handful of controllers *if it is stated*, and it reframes §2: the requirement that matters on the wall is **re-provisioning a mounted board** (Wi-Fi password rotated, board moved), not first run.

### What the user should see

Target sequence, assuming P1 + P3 + the LED/button hardware note below:

| Step | Board | App |
|---|---|---|
| Bench | `ewp-setup --port … --wifi-file … --name R4-CTRL-1 --label` flashes (or verifies) firmware, provisions Wi-Fi, stores the token and setup code under `~/.config/ewp/`, appends to `wall.json`, prints a label with `name`, `id`, setup code and a QR. | — |
| Power on | LED: slow blink = no Wi-Fi credentials / setup open; fast blink = joining; solid = Wi-Fi up and MCP serving; double-blink = pairing open; triple flash on `identify`. Advertisement carries 1 byte of state flags + id hash in service data so the app can show "needs Wi-Fi" / "online" without connecting. | Nearby list shows `R4-CTRL-1 · needs Wi-Fi` or `R4-CTRL-1 · online 10.0.4.17`. |
| Re-provision | BOOT held 3 s, or `open_setup` over MCP → setup window opens for 10 min, LED slow blink. | Pick the board (or scan its label). Board returns the 2.4 GHz SSIDs *it* can see; user picks one, types password. Status: `joining` → `connected {ip}` or `failed {reason: wrong_password|no_ap_found|…}`. On success, the app receives the board's token over the encrypted session and offers the agent prompt / QR for it. |

Stuck vs. working is answered by the LED and by `device_status.state` (§8). Without a user LED there is no on-board answer; see the hardware note in P3.

---

## 2. The transport bootstrap problem

### Is a 5-minute post-reset window the right model?

No. It optimises for a threat (someone provisioning your board) that is already covered by physical proximity and authentication, and it pessimises the common operational case (a mounted board that lost its network). The window should be driven by **state, not time**:

- Open whenever the board has no Wi-Fi credentials, or has credentials but has not associated for 60 s (it cannot be reached any other way, so BLE *must* be open).
- Open on demand for 10 minutes: authenticated MCP tool `open_setup`, or BOOT button held 3 s (GPIO0 is readable at runtime on the DevKitC; the EN button only resets).
- Closed otherwise. Status is always readable (already the case: the status characteristic is `READ|NOTIFY` without encryption, `main.cpp:413`).

This also fixes finding 8 as a side effect if the window becomes a state machine rather than a `millis()` comparison.

### What BLE should carry

| Option | Verdict |
|---|---|
| **GATT, current scheme** (bonded, passkey-authenticated write) | Wrong tool: it couples Wi-Fi setup to HID pairing, consumes a bond slot, triggers iOS's passkey prompt during setup, and the passkey is unknowable without serial. |
| **GATT, application-layer crypto, no bond** (recommended) | The app reads a 32-byte ephemeral X25519 public key + nonce from the status characteristic, derives a session key with HKDF using the board's printed **setup code** as proof of possession, and writes `ChaCha20-Poly1305(ssid, password)` to the config characteristic. The board replies, encrypted, with `{ip, token}` once joined. No bonding, no iOS prompt, no bond slot, and the token handoff problem disappears. Swift CryptoKit has every primitive; mbedtls on ESP32 has X25519/HKDF/ChaCha20-Poly1305. This is ESP-IDF's `wifi_provisioning` security-2 idea without pulling the whole component in. |
| **GATT, Just Works during a button-gated window** | Acceptable fallback if the crypto piece is deferred: no MITM protection, but the window only opens on physical button press. Still consumes a bond and still prompts iOS unless `WRITE_AUTHEN` is dropped. Not recommended. |
| **L2CAP CoC** | Supported by iOS (`CBL2CAPChannel`) and NimBLE, gives a byte stream at tens of kB/s. Only useful if BLE should carry MCP itself. The only consumer that could use it is the EWP app on a phone, which would then be relaying for the agent's computer — that is the bridge pattern the product rejects. Not needed. |
| **SoftAP captive portal** | App-less, works with any phone, standard IoT UX. Costs a Wi-Fi switch on the phone and gives nothing BLE does not already give here. Keep as a documented fallback, do not build first. |
| **Ethernet (D4)** | Removes the bootstrap entirely: DHCP → mDNS → done. See §5. |

### Should BLE be a permanent control path?

As a **rescue channel**, yes; as an MCP transport, no. A board whose Wi-Fi is down is unreachable by every agent regardless of what BLE carries, so BLE control is for the operator with the app in hand: `identify`, `open_setup`, `reboot`, `factory_reset`, and reading status. All of these fit in one 512-byte GATT write authenticated by the same session key as provisioning. Power cost is nil on USB; range is the real limit (see §5 on the steel wall). iOS background limits are irrelevant because rescue is a foreground, operator-driven act.

### Re-provisioning scenarios

- **Office Wi-Fi password changes.** Today: 20 boards each need a reset (case open) and a phone with a serial console nearby. Target: the boards lose association, fall into "setup open" by state within 60 s, LED slow-blinks, the app lists them as "needs Wi-Fi", operator provisions each from the label or picks "all boards that need Wi-Fi" in the app (sequential, ~20 s each). With Ethernet, nothing happens.
- **Board moves to another site.** Same as above; additionally `forget_host`/`factory_reset` from the app's rescue channel so it does not carry bonds to the new site.
- **Wi-Fi fine, board wedged.** Covered by P4 (watchdog, self-reset) not by BLE.

---

## 3. Identity and differentiation at scale

### What exists

- ESP32: `deviceId = "ewp-" + hex(low 32 bits of efuse MAC)` (`main.cpp:379`). `ESP.getEfuseMac()` copies the six MAC bytes into a `uint64_t` in memory order, so on little-endian Xtensa the low 32 bits are MAC bytes 0..3: the three OUI bytes plus the first NIC byte. Printed most-significant-first, the string is `[b3][b2][b1][b0]`; `substring(len-6)` at `:398` yields `[b2][b1][b0]` — the OUI, constant across every board of a batch. Consequences: at most 256 distinct `deviceId`s per OUI (so two boards from one bag collide with ~16% probability at 10 boards, ~53% at 20), identical Bluetooth names, identical mDNS hostnames (which ESPmDNS will suffix `-2`, but the TXT `id` stays identical so any client keying on `id` merges two boards).
- iOS: `deviceID` is a random UUID created once in Keychain (`Configuration.swift:37`), stable for the install, but tied to nothing physical. The Bonjour name is `EWP app <8 chars>` (`MCPServer.swift:55`). The screen endpoint shares the UUID. No human name anywhere.
- BLE addresses are unusable as identity for the app side: CoreBluetooth gives per-app, per-phone UUIDs (`Provisioning.swift:60`), and iOS phones use rotating RPAs toward the board; the board correctly uses the bonded identity address (`main.cpp:63-65`).

### What identity should look like

Three layers, all of which must appear in the places an agent and a human actually look:

1. **Stable machine ID.** ESP32: full 48-bit MAC as 12 hex digits (`ewp-240ac4a1b2c3`) or a random 64-bit ID generated once into NVS. iOS: keep the UUID. Both go into TXT `id` (as now) and into `serverInfo.name` on `initialize` so the agent sees it on connect.
2. **Human name**, operator-assigned, persisted on the device: `R4-03` for a phone, `R4-CTRL-1` for a controller. ESP32: NVS `name`, exposed as TXT `name=`, Bluetooth name `EWP R4-CTRL-1`, `device_status.name`, and in every tool description prefix (`"[R4-CTRL-1] Press and release…"`) because several MCP clients show only tool descriptions, not server aliases, to the model. iOS: UserDefaults/Keychain `name`, TXT `name=`, Bonjour instance `EWP app R4-03`, `help`/`get_status`. Tools: `set_name(name)` on both.
3. **Physical position**, which no device can know. It lives in the inventory (`wall.json`, P8) keyed by machine ID, and *also* in the name convention so the agent never needs the inventory to address a device in plain language.

### "Identify this one"

- ESP32 with a user LED: `identify(seconds)` → triple-flash pattern. Without an LED, two useful substitutes: flip the Bluetooth name to `IDENTIFY R4-CTRL-1` for 30 s (visible in the app's nearby list) and, if a host is connected, send a HID wake (modifier-only report) so *the phone it drives* lights up — this identifies the controller→phone binding, which is the thing operators actually need to know.
- iOS when EWP is in front: `identify` → full-screen flash with the name in 200-pt text for 3 s. When another app is in front (the normal case on the wall) the app process is suspended and the broadcast extension cannot draw. The durable answer is zero-code: **set each phone's wallpaper to show its name.** It appears in every screenshot, so the agent can confirm which phone it is looking at. The app can generate the image and save it to Photos; MDM can set it on supervised devices.

### Grouping and addressing for the agent

- TXT: `id`, `name`, `role`, `path`, `fw`, and for controllers `hosts=<n>` and `sel=<host name>` so a browser knows which phone a controller currently drives without connecting.
- `wall.json` groups: `row`, `col`, `group` tags (`ios18`, `small-phones`). `ewp-fleet compose --group row4` picks the servers for a session (P8).
- An agent connected to any one ESP32 should be able to call `list_wall` (ESPmDNS `queryService("mcp","tcp")`, ~2 s) and get every EWP endpoint with `id/name/role/host:port`. That is discovery data, not relayed traffic, so it stays within the constraints and gives the agent one entry point.

---

## 4. Pairing and host topology

### What the code does

- Eight bonds (`platformio.ini:11`), one selected host persisted in NVS (`main.cpp:163,387`), advertising whitelisted to the selected host unless pairing is open (`:84-101`), input refused unless the selected host is connected *and subscribed* (`:339`), no fallback to another host (`:97`). This part is right and should be kept.
- `select_host` disconnects every peer and re-advertises (`:159-167`). `start_pairing` does the same and opens a 180 s window (`:145-158`). Both make the currently driven phone go dark immediately.
- `pairingExcluded` is a fixed `[8][32]` (`:37,147-149`): the bond limit is baked into three places (`:37`, `:146`, `:400`) plus the README.

### Where it breaks

1. **Pairing starvation (finding 3).** During the pairing window `setScanFilter(false,false)` lets every bonded phone connect. iOS reconnects to a known HID peripheral in about a second. `onConnect` grants the single `pairingHandle` to the first arrival (`:188-195`); the bonded phone encrypts (no pairing needed), `onAuthenticationComplete` finds it excluded and disconnects it (`:215-219`); it reconnects; repeat. With `MAX_CONNECTIONS=3` the new phone may get a slot but the pairing-handle logic keeps rejecting it as a second concurrent pairing. On a wall this is the steady state. Fix in P2: treat `info.isBonded()` connections as *parked* (accept, do not grant HID, do not take the pairing slot, do not disconnect), raise `MAX_CONNECTIONS` to 9 (the ESP controller maximum per NimBLE's own comment), and give only un-bonded connections the pairing slot.
2. **Silent bond eviction (finding 4).** Verified against NimBLE 2.3.6: `NimBLEDevice::init` installs `onStoreStatus`, whose default is `ble_store_util_status_rr`; on `BLE_STORE_EVENT_OVERFLOW` for `BLE_STORE_OBJ_TYPE_CCCD` it calls `ble_gap_unpair_oldest_except(current peer)`. `CONFIG_BT_NIMBLE_MAX_CCCDS` defaults to 8 and is not set in `platformio.ini`. A bonded iOS host subscribes to the keyboard and mouse input reports and typically the battery level; the provisioning phone also subscribes to the status characteristic. Three to four bonds can exhaust the CCCD store. When the evicted bond is the selected host: `restartAdvertising` finds no match and returns false (`:97`), `advertisingNeeded` is retried every second forever (`:466-468`), the board never advertises again, pairing cannot be opened over BLE, and if Wi-Fi is also down the only recovery is USB. Fix: set `CONFIG_BT_NIMBLE_MAX_CCCDS` ≥ 4 × bonds, and at boot treat "selected host not among bonds" as a first-class state (`selected_host_missing`) that clears the selection and advertises for provisioning/pairing.
3. **Misrouting across agents (finding 5).** Agent A `select_host(phoneA)` while agent B is typing on phoneB: B's next `press_key` fails ("not connected"), then phoneA reconnects, and B's *following* keys land on phoneA. Fix: every input tool takes `host_id`; the firmware refuses when it is not the selected and connected host. Cheap, decisive, and it makes the tool self-describing. Leases (`acquire_host(host_id, seconds) → lease`) can come later if two agents genuinely share a controller.
4. **Switching cost.** iOS, not the board, decides when to reconnect. Awake and unlocked: 1–4 s. Locked, screen off: background scanning is duty-cycled; tens of seconds are normal (**verify** on the actual phones; the verification log shows no A→B→A success yet). There is no way for the agent to wait for this except polling `device_status`. Fix: `select_host(host_id, wait_seconds≤30)` returns `{connected, waited_ms, reason}`; needs P4's task split first, because a blocking wait inside the WebServer handler would stall the very loop that restarts advertising (`:464-468`) — a deadlock.
5. **Target asleep, locked, or gone.** Asleep/locked: iOS still reconnects bonded HID devices and a key press wakes the screen; typing the passcode is possible in principle (**verify** on Face ID devices whether the passcode field is presented to a hardware keyboard without a swipe). Gone: `hid_connected:false`, `state:"waiting_for_selected_host"`, no timestamp. Add `since_ms` and `last_seen_ms`.
6. **Bond limit full.** `start_pairing` refuses (`:146`) — correct — but there is no `forget_host`, so a full controller is permanently full. Note that forgetting on the board leaves the bond on the phone; iOS then fails encryption on reconnect and shows the keyboard as not connected until the user taps "Forget This Device". Document it in the tool result.

### Is one controller / 8 bonds / one selected host the right model for the wall? (D1)

The model is right **per controller**. The question is the ratio. Facts:

- A controller drives exactly one phone at a time. Concurrency on the wall equals the number of controllers, not the number of bonds.
- Each switch costs a disconnect plus 1–30 s of iOS reconnect, and the phone that lost input goes dark mid-task.
- Bonds can be raised (16–32 is realistic in NVS if `MAX_CCCDS` grows with them and `pairingExcluded` becomes dynamic), but that only widens zones; it does not reduce switching.
- An ESP32-C3 "super mini" costs ~€2–3 and already has an RGB LED; 200 of them cost less than one phone, and they can draw power from the same USB infrastructure the phones need anyway.

Recommendation: **1:1 for phones that agents work on concurrently; switching for cold spares and for computers.** With 1:1, findings 3, 5 and most of 4 become irrelevant in practice (one bond, no whitelist churn, no reconnection gap), the controller's `select_host` is still useful for the Mac/PC case, and the firmware does not change — only the build target (NimBLE-Arduino supports C3/S3). Keep the 8-bond switching firmware as the general case. This is the owner's call; the brief described the switching vision, and I am stating that it cannot be made seamless at 200:5 for reasons outside the firmware's control.

Physical note: a steel magnetic wall is a ground plane. Phones' antennas pressed against steel lose range; controllers mounted on the steel will too. Plan for controllers within ~3 m of their phones and standing off the sheet (**verify** with RSSI in `device_status`, P4).

---

## 5. Discovery and networking reality

### What exists

- ESP32: `MDNS.begin(deviceId)`, one `_mcp._tcp` service with `id/path/role` TXT (`main.cpp:478-479`), restarted when Wi-Fi drops (`:482`). No `WiFi.setHostname`, no static IP option, no RSSI/channel reporting. 2.4 GHz only.
- iOS: `NWListener.Service` with the same TXT fields (`MCPServer.swift:51-57`). Discovery browses with `NWBrowser` then resolves each service with a 5 s `NetService` (`Discovery.swift:53-56`); `get_status` returns the whole list every call (`CompanionModel.swift:253`).
- Python `ewp-discover`: zeroconf, sequential `get_service_info` with 1.5 s timeout per service (`tools/ewp_tools/discover.py:21`).

### What breaks at 200

- **Multicast filtering and client isolation.** Guest SSIDs and "AP isolation" block phone↔laptop unicast entirely; enterprise APs often rate-limit or proxy mDNS. The wall needs its own VLAN/SSID with mDNS permitted and isolation off. Nothing in the product can work around isolation; say so in the docs and in the app's "Not reachable" reason (the app already checks it can resolve its own advertisement, `CompanionModel.swift:135-142` — good; extend the failure text).
- **2.4 GHz.** 200 phones on 2.4 GHz with ~20 ESP32s and BLE traffic on the same band is a contended room. The original ESP32 time-shares one radio between Wi-Fi and BLE; HTTP latency and HID jitter degrade together under load. Phones belong on 5 GHz. Controllers belong on a dedicated 2.4 GHz SSID with few clients — or on Ethernet (D4). Only the ESP32-C5 has 5 GHz; the C3/S3 do not.
- **mDNS volume.** ~400 services announcing and ~400 resolves is fine for Bonjour; the iOS app's UI list and `get_status` payload are not. Make `mcp_devices` opt-in (`discover_devices` only) and page it; filter the app's list to keyboards by default (the new UI already does this for the card).
- **DHCP churn.** The ESP32 re-announces after reconnect (handled). Clients should hold `http://<hostname>.local/mcp`, not an IP. Add `WiFi.setHostname(deviceId)` so the router's DNS also learns the name. iOS hostnames are the user-visible device name (`sender.hostName`), which Apple de-duplicates with `-2`.
- **iOS Private Wi-Fi Address.** Per-SSID random MAC defeats DHCP reservations. Turn it off per phone for the lab SSID (or via MDM profile).
- **Roaming.** Stationary devices on a wall do not roam. Not a concern.

### When mDNS is blocked outright

There is no product-side fallback that does not involve an operator-maintained record, and that is fine: it is configuration, not a bridge.

1. `wall.json` (P8) holds `id → {name, row, col, address_hint}`; `ewp-fleet` resolves by mDNS when available and by `address_hint`/DHCP reservation otherwise.
2. ESP32: optional static IP in the provisioning payload (`ip, gateway, mask, dns`), plus the DHCP hostname above.
3. iOS: no static IP from an app. DHCP reservation per phone (requires Private Wi-Fi Address off) or MDM. State this plainly in the ops doc.
4. Wide-area DNS-SD (`_mcp._tcp.wall.example.internal` PTR/SRV/TXT records in the office DNS) is a clean alternative if the network admin will host records generated from `wall.json`. Devices cannot register themselves (no DNS Update), so it is static.

### How an MCP client holds a stable reference

By `id`, resolved at session start to a hostname URL; never by IP. The `help` tool on every endpoint should return `{"id", "name", "stable_url": "http://ewp-….local/mcp"}` so a client that landed on an IP can switch to the stable form.

---

## 6. The remote-computer keyboard case

### What changes when the host is a Mac or PC

- **No screen endpoint.** Verification must come from the computer side (the agent's own tooling) or from a webcam. The controller's `help` should say so and the inventory should mark the host `kind: computer`.
- **Descriptor.** The current map is a boot-protocol-style keyboard (report 1) and a relative 3-button mouse (report 2) (`main.cpp:13-23`). Computers accept more: add report 3 = **absolute pointer** (Generic Desktop, X/Y logical 0..32767, buttons), which macOS and Windows accept as an absolute mouse (the KVM-over-IP projects rely on this); iOS ignores it (**verify**, iOS has no external digitizer support). Add report 4 = **consumer control** (Usage Page 0x0C: volume, play/pause, `AC Home` 0x0223, brightness) — needed for iOS Home and useful on computers. Add a 1-byte **LED output report** to report 1 (see below). `hid->setHidInfo(0,1)` (`:408`) sets country 0 and remote-wake, fine.
- **Layout.** HID sends usages, the host applies its layout. The office is in Czechia; a Czech QWERTZ host turns `y` into `z`. `type_text` must map characters to usages through a layout table *chosen per host* (`select_host(…, layout:"us"|"cs-qwertz"|…)`, persisted next to the host name). Non-ASCII on macOS can use the Unicode Hex Input layout (Option+hex); on Windows Alt+numpad; on iOS there is no reliable path — document it.
- **Modifiers and chords.** Today one usage per report and `usage ≥ 4` (`:312,345`), so a modifier-only press (tap ⌘ for Spotlight, tap Fn) and multi-key chords other than modifier+key are impossible. The descriptor already has six key slots. Add `press_keys(keys[≤6], modifiers, hold_ms)` and allow `keys: []` for modifier-only.
- **Timing.** 20 ms press (`:346,358`) is fine for key-down/up but repeat, hold (`hold_ms` up to 5 s for long-press gestures on iOS), and inter-key spacing must be parameters. A `key_sequence([...], inter_key_ms)` executed on the board collapses 40 HTTP round trips (~3–4 s for a 40-character string today) into one.
- **Pointer semantics.** `move_pointer(click:true, dx, dy)` sends button-down *with* the motion and releases 20 ms later (`:357-359`): that is a micro-drag, not a click-then-move. Split into `move_pointer(dx,dy)`, `scroll(dy,dx)` (add AC Pan for horizontal), `click(button:left|right|middle, count:1|2)`, `pointer_button(button, action:down|up)` for drags, and for computers `move_pointer_to(x,y)` via report 3. On iOS, AssistiveTouch's cursor appears in the screen capture, so closed-loop targeting is possible: `pointer_home()` (saturate 30 × (−127,−127) to park at the top-left) then stepped moves with a per-host gain measured once by the agent from screenshots; iOS tracking speed must be at its minimum to keep the curve near-linear (**verify**).
- **Sleep and login.** A Mac wakes on BLE HID input if "Allow Bluetooth devices to wake this computer" is on; login windows accept BLE keyboards once paired. USB HID (ESP32-S3 native USB) is strictly more reliable for computers — no pairing, works in firmware/BIOS, no reconnection gap — and the same firmware can expose both. Worth considering if a controller is dedicated to a test Mac.

### Is `press_key`/`move_pointer` adequate for test automation?

No. Missing, in priority order: text entry with layout; key names instead of usage numbers (`"Enter"`, `"Cmd+Shift+4"`); chords; hold; sequences with timing; consumer keys; pointer buttons and drag; absolute pointing on computers; and a liveness probe. The probe is the interesting one: HID hosts send an **output report** with LED state when Caps Lock toggles. If the descriptor includes the LED output report, `probe_host()` can press Caps Lock, wait ≤500 ms for the host's LED report, press it again, and return `host_processed_input: true`. That is the only end-to-end acknowledgement BLE HID offers (input reports are unacknowledged notifications by specification; indications are not permitted for HID input). macOS and Windows send it; iOS behaviour **verify**.

---

## 7. Fleet operations

### Provisioning 200 phones and ~20 controllers

Controllers: the bench flow already exists (`ewp-setup`) and is the right fleet path; extend it to flash, name, label and register in `wall.json` in one run (~1 minute per board, serially). Twenty boards is an afternoon.

Phones are the real cost, and most of it is Apple's, not EWP's:

| Per-phone step | Automatable? | Notes |
|---|---|---|
| Install EWP | Only with MDM (supervised) or TestFlight (human tap) | **Development signing (README:33) is capped at 100 registered devices per product family per membership year and the certificate expires yearly** (confirm the current figure in the Apple Developer account help; it has been 100 for years). 200 phones breaks it unless the split is exactly 100 iPhones + 100 iPads. TestFlight: 10,000 testers, but builds expire after 90 days, so every phone needs a re-install every quarter. Apple Business Manager + MDM: silent install, no expiry, requires supervision (USB per phone once, or DEP). **D2.** |
| Grant Bluetooth and Local Network | No | iOS permission prompts cannot be pre-approved by MDM. |
| Start screen broadcast | No | Apple's dialog, every session, every phone. This is the single biggest recurring human cost on the wall; see below. |
| Pair the keyboard | No | Settings → Bluetooth, passkey entry. |
| AssistiveTouch, Full Keyboard Access | No (MDM cannot enable AssistiveTouch) | One-time per phone. |
| Auto-Lock Never, disable auto-update, Private Wi-Fi Address off, join lab Wi-Fi, wallpaper with name | MDM profiles, else manual | Reboots from iOS updates kill the broadcast and require unlock + relaunch. |

Realistic manual budget without MDM: 4–6 minutes per phone → 13–20 hours for 200, then ~1 minute per phone whenever a broadcast has to be re-armed.

### Screen sharing on a wall

The broadcast extension is the phone's only runtime presence (the app endpoint on 7801 is suspended whenever another app is in front, README:17). So "phone alive" == "broadcast running" for the inventory. Broadcasts end on reboot, on the user stopping them, on extension crash or memory kill (50 MB limit; the current pipeline is far below it), and probably pause rather than end on lock (**verify**; `broadcastPaused` is implemented, `SampleHandler.swift:75`). Nothing can restart one without a tap: the app's hidden-picker trick (`CompanionModel.swift:236`) only *opens* Apple's dialog, and it only works with EWP in front.

What EWP can do: make re-arming a one-tap act and make the need visible. The app should remember that sharing was live, show a prominent "Sharing stopped — tap to resume" state on launch, and the inventory tool should list phones whose screen endpoint vanished. The owner's self-recovery rule cannot be met here by code; it is met by process (a morning walk of the wall) and by minimising the triggers (Auto-Lock Never, updates off, stable power).

The controller side can help: a bonded keyboard can wake a sleeping phone and, if policy allows, type its passcode, so a *locked* phone with a paused broadcast is recoverable by the agent without a human.

### Credentials: distribution, rotation, revocation

- Controllers: tokens land in `~/.config/ewp/<id>.token` at the bench (`tools/ewp_tools/setup.py:60`). Fine. Add `rotate_token` (authenticated; returns the new token once; old token valid for 60 s to let the caller re-authenticate) and `ewp-setup --rotate` over USB.
- Phones: today the token leaves the phone by clipboard or the share sheet (`CompanionModel.swift:200`, `ShareLink` in `CompanionView.swift`). AirDrop to the operator's Mac works but is ~15 s of taps per phone. Add a **QR** on the Access screen encoding `ewp://<id>?name=…&token=…&url=…`; the operator scans 200 of them with a phone running `ewp-fleet import` (or the operator's Mac camera via Continuity). Add `rotate_token` in the app.
- Revocation = rotation. A per-device token already bounds blast radius to one device (§9).

### Firmware update across the wall

None today. Build P5: `update_firmware(url, sha256)` pulls over HTTP from the operator's machine (which serves the file only for the duration — setup tooling, not runtime), writes the inactive OTA slot, verifies the hash, reboots, and **marks the image valid only after Wi-Fi is up and HTTP has answered a request**; otherwise ESP-IDF rolls back on the next boot. That is the self-recovery rule applied to firmware. Headroom: the image is 1,120,861 B against a 1,310,720 B app partition in the default `esp32dev` table (85%); OTA fits today but every feature in this document costs flash. Switch to `min_spiffs.csv` (1.9 MB per slot) or to a 16 MB board.

### Factory reset and recovery when wedged

- BOOT held 10 s → erase NVS (`Preferences` namespace and NimBLE bond store), regenerate token, regenerate setup code if the label is not fixed (if it is, keep the setup code — decide at manufacture), reboot. Enclosure needs a plunger or hole over BOOT (and ideally EN).
- MCP `factory_reset(confirm: "<deviceId>")`.
- Watchdog (P4): subscribe the loop task to the task WDT; a Wi-Fi association that fails for 5 minutes with valid credentials triggers a radio restart, after 15 minutes a reboot; `restartAdvertising` failing for 30 s triggers a NimBLE re-init. Report `reset_reason` (`esp_reset_reason()`) and `uptime_s` so brownouts on a shared hub become visible in the inventory rather than mysterious re-pairing windows.

### Health and inventory

`ewp-fleet status` (P8): reads `wall.json`, browses mDNS for 3 s, calls `device_status`/`get_status` on each in parallel, prints a table: name, id, role, reachable, uptime, reset_reason, rssi, hid_connected/selected host, sharing live, frame_age. Exit code non-zero if any expected device is missing. It runs when invoked (cron on the operator's machine is their choice); it carries no agent traffic.

---

## 8. The agent-facing surface

### Review of the current tools

**ESP32 (`main.cpp:308-313`)**

| Tool | Verdict |
|---|---|
| `help` | Good addition. Must gain `name`, `id`, `stable_url`, and must stop asserting "fails rather than deleting an existing bond" (`:127`) until P2 lands. |
| `device_status` | Mixes product state with debug counters (`ble_connections`, `last_disconnect_reason`, `connections_seen`, `security_request_result`, `authentication_state`, `:136-140`). Move those under `diagnostics`. Add `name`, `uptime_s`, `reset_reason`, `wifi.rssi/channel/ip/hostname`, `selected_host{host_id,name,connected,since_ms}`, `pairing{open,expires_in_s}`, `setup{open,expires_in_s}`, `input{sequence,last_sent_ms}`, and a single `state` enum: `no_wifi_credentials | wifi_joining | wifi_failed(reason) | online_no_host_selected | waiting_for_selected_host | ready | pairing_open | selected_host_missing`. |
| `list_hosts` | Add `last_connected_ms`, `kind` (phone/tablet/computer, operator-set), `layout`. |
| `start_pairing` | Returns the pairing code — correct. Make the code random per call. Add `cancel_pairing`. |
| `select_host` | Add `wait_seconds` and a structured result. Make `name` a separate `set_host(host_id, name, kind, layout)` so naming is not coupled to switching. |
| `press_key`, `move_pointer` | Add `host_id` (required). See §6 for the rest. |

**iOS app (`CompanionModel.swift:65-77`)**

| Tool | Verdict |
|---|---|
| `help` | Good. Add `name`, `device_info`. |
| `get_status` | Make `mcp_devices` and `nearby_keyboards` opt-in (`include_network:true`); add `name`, `model`, `system_version`, `screen{points_w,points_h,scale,orientation}`, `battery`, `locked` (not available to apps; omit), `sharing{live,frame_age_ms,frame_id}`. |
| `get_screen` | Dual meaning (app window vs. device) is fine because `source` is returned. Add the P10 parameters. |
| `start_screen_sharing` | Correct honesty (`requested`, not `live`). Note it depends on a private-ish view hierarchy walk (`:234`) that any iOS release can break; keep the manual button prominent as the fallback (the new UI does). |
| `discover_devices`, `select_esp32`, `configure_esp32` | Setup helpers; fine. Key `select_esp32` by advertised device id once service data exists (P3), not by CoreBluetooth's per-app UUID. |
| Missing | `identify`, `set_name`, `show_access_qr` (display only; the token must never be *returned* by a tool), `rotate_token`. |

**Screen (`SampleHandler.swift:26-30`)**

| Tool | Verdict |
|---|---|
| `help`, `get_status`, `stop_screen_sharing` | Fine. `get_status` needs `frame_id`, `frame_age_ms`, `name`, `screen{points,scale}`. |
| `get_screen` | Needs `since_frame_id`, `wait_ms` (≤ 25 s; the connection cap is now 30 s, `MCPServer.swift:111`), `max_dimension`, `quality`, `region{x,y,w,h}` in points. Returns `frame_id`, `captured_ms_ago`, `changed`. |

### What is missing for an agent driving a wall

- **Addressing.** Name and id in `serverInfo.name`, in `help`, and prefixed into tool descriptions (§3). Without this, five controllers in one client are five identical `press_key` tools.
- **Batch and timing.** `key_sequence`, `type_text` on the controller; nothing cross-device (that is the client's job).
- **Waiting and settling.** `select_host(wait_seconds)`, `wait_for_host`, `get_screen(wait_for_change)`. The natural loop becomes: `seq = press_key(host_id, …)` → `get_screen(since_frame_id, wait_ms:1500)` → `changed:true|false`. Make `press_key` return `{sequence, sent_ms}` so the agent can log cause and effect.
- **Idempotency.** HTTP timeouts on a retrying client produce double keystrokes. Accept an optional `request_id`; keep an 8-entry LRU of `(request_id → result)` per controller and replay the stored result.
- **Confirming input landed.** Three layers, strongest first: (1) screen change since frame N (P10); (2) the LED output-report probe (§6) proving the host's HID stack processed a key; (3) `notified:true` meaning "queued to the radio", which is what exists now. `host_action_verified` should disappear in favour of the agent reading `changed`.
- **Safety.** Destructive tools take `confirm:"<deviceId>"` (`factory_reset`, `forget_host`, `rotate_token`). Input tools stay unconfirmed but host-bound.
- **Consistency.** iOS returns JSON-RPC `-32602` for an unknown tool (`MCPServer.swift:182`); the ESP32 returns `isError:true` text (`main.cpp:363`). The spec prefers the error. Align on the error.

---

## 9. Security at this scale

Proportionate stance: trusted-LAN lab tool, but one that holds live screens of 200 real devices and types their passcodes.

| Concern | Today | At 200 | Change |
|---|---|---|---|
| **Transport confidentiality** | Plain HTTP with bearer tokens on Wi-Fi. | On WPA2-PSK any wireless peer with the PSK can decrypt other clients' traffic: screen frames and `press_key` passcodes included. 200 phones share that PSK. | **WPA3-SAE-only lab SSID** (per-station PMK; peers cannot decrypt each other). The original ESP32 supports WPA3-SAE station mode in this IDF. Wired segment for the agent's machine. TLS on the ESP32 alongside NimBLE is marginal on heap; defer to S3-class hardware if ever needed. iOS could do TLS cheaply, but a per-device self-signed cert pinned via unauthenticated mDNS TXT adds little over WPA3. |
| **Token distribution/storage** | Per-device random 64-hex tokens; ESP32 NVS plaintext, iOS Keychain `AfterFirstUnlockThisDeviceOnly`. Operator copies in `~/.config/ewp/` mode 600. | 400 tokens in one directory on the operator's machine is the real honeypot. | Keep per-device tokens (blast radius = one device). Add `rotate_token`. Store the operator's set in an encrypted file or the OS keychain via `ewp-fleet`; never in `wall.json`. |
| **mDNS leakage** | `id`, `role`, `path`. | Plus `name`, `fw`, `hosts`, `sel` (proposed). | All harmless on a lab VLAN; keep tokens and setup codes out. Do not publish `wall.json` positions over mDNS. |
| **BLE pairing** | SC passkey entry with a *static* passkey stored in NVS (`main.cpp:380-383,403`); auto-open pairing 5 min after boot without a selection (`:400`). | Static passkey leaks across repeated pairing attempts under SC passkey entry (the specification requires a fresh passkey per pairing). Power blips open 20 boards. | Random passkey per `start_pairing`, returned in the tool result as now. No auto pairing window except on a board with zero bonds and even then only until first provisioning. Provisioning stops using pairing at all (P3). |
| **Browser/rebinding** | `Origin` header rejected (`main.cpp:261`, `MCPServer.swift:148`). `Host` not checked. | Same. | Fine for a LAN tool. Drop `NSAllowsArbitraryLoads` (`ios/EWP/Info.plist:27`); `NSAllowsLocalNetworking` suffices. |
| **USB** | `access` returns the token to anyone with the cable (`main.cpp:437`). | Same. | Physical access is ownership of the board; acceptable. Boot log prints the pairing code (`:383`); after P3 it becomes the setup code and should print only when BOOT is held during boot. |
| **Compromised token blast radius** | One device's input (and, for phones, its screen and the ability to request a broadcast — which still needs a human tap). | Same per device. | Already proportionate. Rotation closes the loop. |
| **Screen frames** | In extension memory only, 5 s freshness. | Same. | Fine. |

---

## 10. Where the current code breaks

File:line, grouped by what fails. Class in brackets.

**`firmware/src/main.cpp`**

- `:379` — `static_cast<uint32_t>(ESP.getEfuseMac())`: identity is OUI + 1 byte. `:398` — name suffix is the OUI. [A]
- `:380-383,403` — static passkey, printed on serial only, used for all pairings. [A, security]
- `:384,218,241,488` — `provisionUntil` compared with `>`/`<=`; wraps at 2³² ms ≈ 49.7 days and re-opens setup permanently. `pairingOpen()` at `:74` does it correctly; copy that. [A]
- `:400` — pairing window auto-opens for 5 min at every boot when no host is selected. [A, security]
- `:401,201` — every connection is bonded with MITM; the provisioning phone consumes a bond slot and gets iOS's passkey prompt. [A]
- `:411,241` — `WRITE_AUTHEN` on the config characteristic couples provisioning to HID pairing. [A]
- `:437` — the MCP token is reachable only over USB; no BLE handoff. [A]
- `:188-195,215-219` — single `pairingHandle`; bonded excluded hosts take it and get disconnect-looped. [A]
- `:37,147-149,146,400` + `platformio.ini:11` — bond limit hard-coded in four places. [B]
- `platformio.ini:10-12` — `MAX_CCCDS` not raised; NimBLE evicts the oldest bond on CCCD overflow. [A]
- `:97,466-468,387,400` — selected bond missing → `restartAdvertising` false forever → no advertising, no BLE recovery. [A]
- `:127` — `help` claims no bond is ever deleted. [A, doc]
- `:159-167` — `select_host` has no wait; `:153,164` disconnect all peers (correct) but nothing reports how long reconnection took. [B]
- `:337-360` — input tools take no `host_id`. [A]
- `:345` — one key slot used of six; `:312` `usage` 4..101 excludes keypad, F13+, international; no modifier-only press. [C/B]
- `:357-359` — click + motion in one report then release: micro-drag; no right/middle button; no down/up. [C]
- `:346,358` — fixed 20 ms hold; `delay()` inside the HTTP handler blocks `loop()`. [C]
- `:13-23` — no consumer page, no absolute pointer, no LED output report. [C, B for computers]
- `:289` — 4 KB request cap; fine now, sizes `type_text`. [—]
- `:389` — no `WiFi.setHostname`, no static IP, no disconnect-reason capture (`WiFi.onEvent`), no scan. [A/B]
- `:452-492` — no watchdog, no `reset_reason`, no uptime, no RSSI, no self-heal for a Wi-Fi that never associates; `MDNS.begin` retry at `:477-478` is fine. [B]
- `:429-450` — serial setup has no `rotate`, `name`, `factory_reset`. [B]
- Whole file — no OTA, no button, no LED, no `forget_host`, no `set_name`, no `identify`. [A→B]
- `:132` — `firmware` version string literal `"0.2.0"` duplicated in `:301`; move to one constant and into TXT `fw`. [C]

**`ios/Shared/MCPServer.swift`**

- `:55` — Bonjour name carries 8 UUID chars, no human name. [B]
- `:103` — 8 concurrent connections; fine. `:111` — 30 s cap bounds any long-poll (P10 uses ≤ 25 s). [—]
- `:182` vs `main.cpp:363` — unknown-tool handling differs. [C]

**`ios/EWP/CompanionModel.swift`**

- `:164` — token in the agent prompt in plain text (by design); the only extraction paths are clipboard (`:200`) and the share sheet. [B]
- `:236` — broadcast start depends on finding a `UIButton` inside Apple's picker. [B, fragility]
- `:252-253` — `get_status` returns every nearby keyboard and every mDNS service on every call. [B]
- `:312` — 8 s fixed wait for BLE readiness in `configure_esp32`. [C]

**`ios/EWP/Discovery.swift`**

- `:53-56` — one `NetService` resolve per service with a 5 s timeout; ~400 concurrent resolves at scale. `:79` — service identity is name:port. [B]

**`ios/EWP/Provisioning.swift`**

- `:38,197` — instructs the user to reset the board. `:41` — tells an already-bonded phone to pair in Settings. `:94,101` — scans continuously while the app is in front. [A, UX]

**`ios/Shared/Configuration.swift`**

- `:37` — random UUID identity, no name, no rotation. [B]

**`ios/Broadcast/SampleHandler.swift`**

- `:72` — liveness is a 5 s window; no `frame_id`, no change detection. [B]
- `:59` — stop is fire-and-forget; fine. [—]

**`tools/ewp_tools/discover.py:21`** — sequential 1.5 s resolves. [B]

**`README.md:33`** — installation path is development signing. [B, process]
**`README.md:76`, `main.cpp:127`** — bond-deletion claim. [A, doc]
**`docs/enclosure.md:3,7`** — no button access, LED aperture over the power LED only. [A, hardware]

---

## 11. The constraints, re-examined

**No cloud, no computer bridge at runtime, MCP on the devices.** None of these break outright for the runtime path: every scenario above is solvable with device-side changes plus operator configuration. Two places strain, and I want to name them separately rather than smuggle them in:

1. **Client-side scale (D3).** Agents' MCP clients take a static list of servers and load each server's tool schemas into context. A 400-server client is not usable today regardless of what EWP does. The product-side mitigations — names in descriptions, `help`, `list_wall`, scoped sessions — reduce the damage; the clean solution is a *setup-time* tool (`ewp-fleet compose`) that writes the client's configuration for the devices this session needs. It carries no device traffic, runs before the session, and could be replaced by hand-editing a config file. I consider it outside the bridge prohibition, but the owner should rule on it.
2. **Apple's management plane (D2).** Installing and keeping an app alive on 200 iOS devices cannot be done without Apple infrastructure: TestFlight or ABM/MDM. Both are cloud services. They are *device management*, not part of the product's runtime, and they touch no MCP traffic or screen frames; but if "no cloud" is meant absolutely, the honest consequence is a 100-device ceiling per product family and a yearly reinstall.

Everything else — provisioning, discovery, pairing, verification, security — stays on the devices and the LAN.

---

## 12. Build this first

Each piece is independently implementable. "Depends on" lists hard prerequisites only. Sizes are rough: S < 1 day, M 1–3 days, L a week with hardware testing.

### P1 — Identity and naming (S, no dependencies)

**Problem.** Findings 1 and 12: colliding IDs, identical names, no human name anywhere.

**Firmware (`main.cpp`).**
- `deviceId = "ewp-" + 12 lowercase hex digits of the full 48-bit efuse MAC` (`WiFi.macAddress()` without colons, or format all 6 bytes of `ESP.getEfuseMac()` in network order). Migration: a board with an old 8-digit id gets a new id; bonds are unaffected (identity is the BLE address); `ewp-setup` users must re-import the token file name. Accept this once.
- NVS `name` (≤ 32 bytes, default empty). Bluetooth name: `EWP <name>` if set, else `EWP <last 6 hex of the full MAC>`. Note `keyboardName` is used in `appendHelp`/`appendStatus`; both should return `name` and `id` separately.
- TXT records: add `name`, `fw`. `serverInfo.name = "EWP keyboard <name or id>"`.
- Tool descriptions: build them at `tools/list` time with a `[<name>]` prefix (they are already constructed per request).
- New tools: `set_name(name)` → persists, re-advertises, re-registers mDNS; `identify(seconds≤30)` → LED pattern if present, Bluetooth name `IDENTIFY <name>` for the duration, and a modifier-only HID report to the connected host if any.
- `ewp-setup`: `--name`, accept 12-hex ids; `--expected-id` unchanged.

**iOS.**
- `Configuration` gains `name` (UserDefaults is fine; it is not secret). `MCPServer.Service(name: "EWP <role> <name or 8 chars>")`, TXT `name`, `fw` (`Bundle.version`).
- Tools on app and screen: `set_name`, `identify` (app only: full-screen flash with the name, 3 s). `help`/`get_status` return `name`, `id`.
- Advanced → About: editable name field.

**Acceptance.** Two boards from the same batch show distinct ids and names in `ewp-discover` and in the app; `tools/list` on a controller named `R4-CTRL-1` shows that prefix; `identify` is visible.

### P2 — Firmware safety (M, no dependencies; P4 recommended first for the wait feature)

**Problem.** Findings 3, 4, 5, 7, 8, 9 (`forget_host`).

**Spec (`main.cpp`, `platformio.ini`).**
1. `platformio.ini`: `-D CONFIG_BT_NIMBLE_MAX_BONDS=<N>`, `-D CONFIG_BT_NIMBLE_MAX_CCCDS=<4*N>`, `-D CONFIG_BT_NIMBLE_MAX_CONNECTIONS=9`. Replace every literal 8 with `CONFIG_BT_NIMBLE_MAX_BONDS`; size `pairingExcluded` from it. Start with N=8; raising later is a rebuild.
2. Install a custom `NimBLEDeviceCallbacks::onStoreStatus` that returns `BLE_HS_ESTORE_CAP` (refuse) instead of evicting, and surface `store_full:true` in `device_status`. The product rule "never delete a bond implicitly" then holds.
3. Boot: if `selected` is not among bonds → clear it, set `state:"selected_host_missing"`, advertise unrestricted for provisioning (not for pairing), log in `device_status.last_error`.
4. Pairing: random 6-digit passkey per `start_pairing` (`NimBLEDevice::setSecurityPasskey` before advertising); no automatic pairing window at boot unless `getNumBonds()==0`. In `onConnect`, consult `info.isBonded()` (**verify** the NimBLE 2.3.6 accessor name on `NimBLEConnInfo`; `NimBLEDevice::isBonded(address)` exists): bonded peers never take `pairingHandle`; during a pairing window they are *parked* (kept connected, no HID handle, no disconnect) so they do not loop; only unbonded peers are candidates. `cancel_pairing` tool.
5. `forget_host(host_id, confirm)` → `NimBLEDevice::deleteBond(address)`; clears selection if it was selected; result explains the phone-side "Forget This Device" step.
6. Input binding: `press_key`/`move_pointer` (and all P11 tools) take `host_id` (required); refuse with `error:"host_id is not the selected and connected host"` otherwise. Return `{sequence, sent_ms}` (monotonic counter and `millis()`).
7. Idempotency: optional `request_id` (string ≤ 64); 8-entry LRU replays the stored result.
8. Time: replace `millis() > provisionUntil` with the signed difference idiom used by `pairingOpen()`; better, make setup/pairing windows a small state machine with `expires_in_s` in status.
9. `select_host(host_id, wait_seconds≤30)` — only once P4 has moved HTTP off the housekeeping loop.

**Acceptance.** With two bonded iPhones in range, `start_pairing` and pairing a third phone succeeds in one attempt; `select_host` on A while B is connected, then `press_key(host_id:B)` is refused rather than delivered to A; filling CCCDs (subscribe from 3+ hosts) does not remove a bond and `device_status.store_full` becomes true; `forget_host` frees a slot; a board left running 50+ days (simulate by offsetting `millis()`) keeps the setup window closed.

### P3 — Provisioning v2 (L, depends on P1 for ids; hardware note)

**Problem.** Findings 2 and 6.

**Firmware.**
- Setup window by state: open when no credentials, or when `WiFi.status()!=WL_CONNECTED` for 60 s with credentials; `open_setup(minutes≤30)` tool; BOOT (GPIO0) held 3 s → open 10 min; 10 s → factory reset (P5).
- Status characteristic JSON gains: `state` (`no_credentials|joining|connected|failed`), `reason` from `WiFi.onEvent(ARDUINO_EVENT_WIFI_STA_DISCONNECTED)` (`info.wifi_sta_disconnected.reason` mapped to `wrong_password|no_ap_found|assoc_failed|…`), `ip`, `rssi`, `name`, `id`, `setup_open`, `expires_in_s`, and when setup is open an ephemeral X25519 public key + 12-byte nonce.
- Advertisement: 4 bytes of service data under the EWP service UUID: flags (`provisioned`, `wifi_up`, `setup_open`, `pairing_open`) + 2-byte id hash, so the app can label boards without connecting.
- Config characteristic: drop `WRITE_AUTHEN`; accept `{op:"scan"}` (unencrypted; reply with up to 15 SSIDs/RSSI/channel in status), and encrypted `{op:"wifi", ssid, password, static?:{ip,gw,mask,dns}}`, `{op:"identify"}`, `{op:"open_pairing"}`, `{op:"reboot"}`. Encryption: HKDF-SHA256(X25519 shared secret ‖ setup code) → ChaCha20-Poly1305 with the advertised nonce; the setup code is the existing `passkey` renamed, printed on the label, still printed on boot only if BOOT is held.
- After `connected`, write an encrypted `{token, id, name, url}` into the status value for 60 s (the app reads it once; the board clears it). No bond is created; `startSecurity` is only called for connections that subscribe to HID reports (move the call from `onConnect` to the first HID subscription, or start it for all but with bonding disabled when the connection's first action is on the EWP service — the former is simpler).
- `ewp-setup`: `--label` prints `name`, `id`, setup code, and a QR with `ewp://setup?id=…&code=…`.

**iOS.**
- `Provisioning` uses CryptoKit (`Curve25519.KeyAgreement`, `HKDF`, `ChaChaPoly`). Setup sheet: step 2 asks for the label code (or scans the QR); step 3 shows the board's SSID list; step 4 shows `joining → connected (ip)` or `failed (reason)` with "Try again" that re-sends without a reset. On success, show the agent prompt for the *keyboard* as well (it now has the token).
- Nearby list shows the advertised flags: "needs Wi-Fi", "online".

**Hardware note (owner decision, no code).** The DevKitC V4 has no user LED and the enclosure exposes no button. Minimum viable: one LED + resistor on a spare GPIO and a plunger over BOOT; the enclosure's existing aperture moves to the user LED. Better: ESP32-S3-DevKitC-1 (onboard WS2812, 8–16 MB flash, USB-OTG) for controllers and ESP32-C3 minis (onboard RGB on most) for 1:1 phone controllers. Best for the wall: Ethernet/PoE (D4).

**Acceptance.** A phone with no serial access provisions a factory-fresh board end-to-end using only the label; a wrong password yields `failed: wrong_password` within 15 s and a retry without reset; the app ends with a working keyboard MCP prompt; `list_hosts` shows zero bonds afterwards.

### P4 — Self-healing and observability (M, no dependencies)

**Problem.** Findings 9 and 13; the owner's recovery rule.

**Spec (`main.cpp`).**
- Move `WebServer` handling to its own FreeRTOS task (core 1, 8 KB stack), leaving `loop()` for BLE housekeeping, Wi-Fi/mDNS, serial, status notify. Guard shared state (`advertisingNeeded`, `pairingUntil`, selection) with the existing mutex or a FreeRTOS queue of commands from HTTP to the housekeeping task. This is what makes long-polls (`select_host(wait)`, P10 is iOS-side) safe.
- `esp_task_wdt_add(NULL)` in both tasks with a 30 s timeout; reset in each iteration.
- Wi-Fi policy: with credentials and no association for 5 min → `WiFi.disconnect(); WiFi.begin()`; 15 min → `esp_restart()`. `MDNS.begin` failing 10× → log and keep retrying (already does).
- BLE policy: `restartAdvertising()` false for 30 s → `NimBLEDevice::deinit(); init()` once; if still failing, `esp_restart()` with reason logged to NVS (`last_error`).
- `device_status` additions: `uptime_s`, `reset_reason` (`esp_reset_reason()`), `heap_free`, `wifi{rssi,channel,ip,hostname,disconnects}`, `ble{connections,advertising}`, `last_error`, `store_full`. Move the debug counters under `diagnostics`.
- `WiFi.setHostname(deviceId)` before `WiFi.begin`.

**Acceptance.** Pull the AP: within 5 min the board retries, within 15 min reboots, and comes back announcing `reset_reason:"software"`; a deliberate `while(1)` in a test build trips the WDT; `ewp-fleet status` (P8) shows uptime and RSSI.

### P5 — OTA, factory reset, partition headroom (M, depends on P4 for the HTTP task)

- `platformio.ini`: `board_build.partitions = min_spiffs.csv` (or a custom table with two 1.9 MB app slots and a small NVS; NimBLE's bond store lives in NVS, so keep ≥ 24 KB).
- Tool `update_firmware(url, sha256, confirm)`: HTTP GET (LAN only, refuse non-RFC1918), stream into `Update`, verify SHA-256, `esp_ota_set_boot_partition`, reboot. On boot, if `esp_ota_get_state_partition()==PENDING_VERIFY`, mark valid only after Wi-Fi associated and the first authenticated HTTP request succeeded; otherwise the bootloader rolls back.
- Tool `factory_reset(confirm:"<deviceId>")` and BOOT held 10 s: `preferences.clear()`, `NimBLEDevice::deleteAllBonds()`, regenerate token, keep or regenerate setup code per the manufacturing decision, reboot.
- `ewp-fleet update --group controllers --image build/firmware.bin` serves the file from the operator's machine for the duration and calls each board.

**Acceptance.** A board updated with a deliberately broken image (Wi-Fi disabled) rolls back by itself and reports it in `last_error`; a good image reports the new `fw`.

### P6 — Topology (S code; owner decision D1)

- Raise `CONFIG_BT_NIMBLE_MAX_BONDS` per D1 (P2 made it a single constant).
- `select_host(wait_seconds)` and `wait_for_host(timeout_s)`; status `selected_host.since_ms`, `last_seen_ms`.
- Optional leases: `acquire_host(host_id, seconds, owner)` → `lease`; input tools accept `lease` as an alternative to `host_id`; `device_status.lease{owner, expires_in_s}`; `select_host` from a different owner is refused while a lease is live.
- Documentation: the zone plan (which controller is bonded to which phones) is `wall.json` data (P8).

### P7 — iOS fleet affordances (M, depends on P1)

- Access screen: QR of `ewp://device?id=…&name=…&url=…&token=…`; `ewp-fleet import` scans or accepts the AirDropped text. Tool `rotate_token(confirm)`.
- `identify` (foreground flash), `set_name`, "Save name wallpaper" (renders the name on a dark background to Photos; iOS cannot set wallpaper programmatically).
- `get_status`: `include_network` flag; `device_info` fields (model, system version, screen points/scale/orientation, battery level/state, low power mode).
- Sharing watchdog: remember `wasSharing`; on launch or foreground with `wasSharing && !live` show "Sharing stopped — tap to resume" as the primary card state; keep the visible button (the hidden-picker call stays as the MCP path).
- Discovery: resolve lazily (only keyboards and own advertisement by default), cap concurrent resolves, and expose a paged `discover_devices(role, limit)`.
- `Info.plist`: remove `NSAllowsArbitraryLoads`.

### P8 — Inventory and session composition (M, no dependencies; D3)

A `tools/ewp_tools/fleet.py` CLI, in the same package as `ewp-setup`:

- `wall.json` schema: `{"devices": [{"id","name","role":"phone|tablet|computer|controller","row","col","group":[...],"controller":"<controller id>","token_file":"~/.config/ewp/<id>.token","address_hint":"ewp-….local"}]}`. Tokens never in the file.
- `ewp-fleet import` (from `ewp-setup` output, QR text, AirDropped prompt), `ewp-fleet status` (mDNS + parallel `help`/`device_status`/`get_status`; table; exit code), `ewp-fleet compose --group row4 --controller R4-CTRL-1 --out <client config path>` writing the MCP client configuration for exactly those servers (Claude Desktop/Code JSON shape; others as needed), `ewp-fleet label <id>` (prints the label), `ewp-fleet update` (P5).
- `help` on every device returns `stable_url` so `compose` can prefer hostnames.

**Acceptance.** `ewp-fleet status` lists 3 devices with uptime and sharing state; `ewp-fleet compose` yields a config that an agent loads with 4 servers, each tool prefixed by name.

### P9 — Network plan (ops doc, no code; D4)

A `docs/network.md`: lab VLAN with mDNS allowed and client isolation off; WPA3-SAE-only SSID for devices; phones on 5 GHz, controllers on a 2.4 GHz SSID of their own (or Ethernet); DHCP reservations keyed on real MACs (Private Wi-Fi Address off per phone or via MDM); agent machines wired on the same VLAN; no port forwarding. Include the Ethernet/PoE controller option with the BOM delta.

### P10 — Screen verification semantics (S–M, no dependencies)

**Screen extension (`SampleHandler.swift`, `MCPServer` long-poll).**
- Each encoded frame gets `frame_id` (monotonic) and a cheap content hash (e.g. 64-bit of a 16×16 luma downsample). `latest()` returns both.
- `get_status`: `frame_id`, `frame_age_ms`, `screen{points_w,points_h,scale,orientation}`, `name`, `id`.
- `get_screen(since_frame_id?, wait_ms≤25000, changed_only?:bool, max_dimension?, quality?, region?)`: if `since_frame_id` is given, wait until a frame with a different hash (or any newer frame if `changed_only:false`) arrives or `wait_ms` elapses; return `{frame_id, changed, captured_ms_ago}` plus the image unless `changed:false && changed_only`. `region` crops in points before encoding.
- App `get_screen` forwards the same parameters to 7802.

**Controller (`main.cpp`).** Already in P2: `press_key` returns `{sequence, sent_ms}`.

**Acceptance.** Agent loop `press_key` → `get_screen(since_frame_id, wait_ms:1500)` returns `changed:true` on a key that opens a menu and `changed:false` on a no-op key; `region` returns a correctly cropped JPEG.

### P11 — Input richness (M, depends on P2 for `host_id`)

- Descriptor: keep report 1 keyboard but add a 1-byte LED output report; report 2 relative mouse plus AC Pan; report 3 absolute pointer (X/Y 0..32767, 3 buttons); report 4 consumer control (16-bit usage). Re-pairing may be required on iOS after a descriptor change (iOS caches the report map); document it.
- Tools: `press_keys(host_id, keys[≤6 names or usages], modifiers[names or mask], hold_ms≤5000)`, `type_text(host_id, text≤2000, inter_key_ms, layout?)` with layout tables `us`, `cs-qwertz` to start, `key_sequence(host_id, steps[...], inter_key_ms)`, `consumer_key(host_id, name|usage)` (`home`, `volume_up`, `play_pause`, …), `click(host_id, button, count)`, `pointer_button(host_id, button, action)`, `move_pointer(host_id, dx, dy)`, `scroll(host_id, dy, dx)`, `pointer_home(host_id)`, `move_pointer_to(host_id, x, y)` (report 3; iOS unsupported, say so in the result), `probe_host(host_id)` (Caps Lock LED round trip; returns `host_processed_input`, `latency_ms`).
- Key-name table lives in firmware (a ~110-entry array); `help` lists supported names.

**Acceptance.** `type_text("Hello, wall!")` appears correctly on a US-layout Mac and on an iPhone; `probe_host` returns true on a Mac within 500 ms; `move_pointer_to(16383,16383)` centres the cursor on a Mac; `consumer_key("home")` returns to the iOS home screen (**verify**).

---

### Reading order for implementers

P1 → P2 → P4 → P3 → P10 → P8 → P7 → P5 → P11 → P6 → P9. P1 and P10 are safe to start in parallel; P2 and P4 touch the same file and should be sequenced; P3 touches both firmware and app and should start once P1's id change has landed so labels carry the final id.

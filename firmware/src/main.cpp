#include <Arduino.h>
#include <ArduinoJson.h>
#include <ESPmDNS.h>
#include <NimBLEDevice.h>
#include <NimBLEHIDDevice.h>
#include <Preferences.h>
#include <WebServer.h>
#include <WiFi.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>

// Standard keyboard (report 1) and relative three-button mouse (report 2).
static uint8_t reportMap[] = {
  0x05,0x01,0x09,0x06,0xA1,0x01,0x85,0x01,
  0x05,0x07,0x19,0xE0,0x29,0xE7,0x15,0x00,0x25,0x01,
  0x75,0x01,0x95,0x08,0x81,0x02,0x95,0x01,0x75,0x08,0x81,0x01,
  0x95,0x06,0x75,0x08,0x15,0x00,0x25,0x65,0x19,0x00,0x29,0x65,0x81,0x00,0xC0,
  0x05,0x01,0x09,0x02,0xA1,0x01,0x85,0x02,0x09,0x01,0xA1,0x00,
  0x05,0x09,0x19,0x01,0x29,0x03,0x15,0x00,0x25,0x01,
  0x95,0x03,0x75,0x01,0x81,0x02,0x95,0x01,0x75,0x05,0x81,0x01,
  0x05,0x01,0x09,0x30,0x09,0x31,0x09,0x38,0x15,0x81,0x25,0x7F,
  0x75,0x08,0x95,0x03,0x81,0x06,0xC0,0xC0
};
constexpr char SERVICE[] = "e7a00001-7c3d-4d21-a19a-455750000001";
constexpr char CONFIG[] = "e7a00002-7c3d-4d21-a19a-455750000001";
constexpr char STATUS_UUID[] = "e7a00003-7c3d-4d21-a19a-455750000001";
constexpr char FIRMWARE[] = "0.3.0";
struct Configuration { char ssid[33]; char password[65]; };
QueueHandle_t configurationQueue;
Preferences preferences;
WebServer http(80);
NimBLECharacteristic *keyboard, *mouse, *statusCharacteristic;
String deviceId, token, setupStatus = "ready";
String keyboardName, deviceName;
char selectedHost[32] = {};
volatile uint32_t pairingUntil = 0;
volatile uint32_t identifyUntil = 0;
volatile bool advertisingNeeded = false;
char pairingExcluded[CONFIG_BT_NIMBLE_MAX_BONDS][32] = {};
String pendingHostName, lastError;
struct HostEvent { char id[32]; };
QueueHandle_t hostEvents;
uint32_t passkey, setupCode;
uint32_t provisionUntil;
volatile bool storeFull = false;
uint32_t inputSequence = 0;
bool mdnsStarted = false;
portMUX_TYPE hidMux = portMUX_INITIALIZER_UNLOCKED;
uint16_t hidHandle = BLE_HS_CONN_HANDLE_NONE;
uint16_t pairingHandle = BLE_HS_CONN_HANDLE_NONE;
// Subscription can arrive before encryption completes. Keep it until the
// authentication callback rather than waiting for iOS to subscribe twice.
struct Subscription { uint16_t handle = BLE_HS_CONN_HANDLE_NONE; uint8_t reports = 0; };
Subscription subscriptions[3];
volatile int lastDisconnectReason = 0;
volatile uint32_t connectionsSeen = 0;
volatile int securityRequestResult = 0;
volatile int authenticationState = 0;

void setHid(uint16_t handle) {
  portENTER_CRITICAL(&hidMux); hidHandle = handle; portEXIT_CRITICAL(&hidMux);
}
uint16_t getHid() {
  portENTER_CRITICAL(&hidMux); auto handle = hidHandle; portEXIT_CRITICAL(&hidMux); return handle;
}

String hostId(const NimBLEAddress &address) {
  return String(address.toString().c_str()) + "/" + String(address.getType());
}
String selectedId() {
  char copy[32]; portENTER_CRITICAL(&hidMux); memcpy(copy, selectedHost, sizeof(copy)); portEXIT_CRITICAL(&hidMux);
  return String(copy);
}
void reserveHost(const String &id) {
  portENTER_CRITICAL(&hidMux); strlcpy(selectedHost, id.c_str(), sizeof(selectedHost));
  hidHandle = BLE_HS_CONN_HANDLE_NONE; portEXIT_CRITICAL(&hidMux);
}
// millis() wraps after 49.7 days, so every window is a signed difference; an
// unsigned comparison leaves the window stuck open after the wrap.
bool pairingOpen() { return static_cast<int32_t>(pairingUntil - millis()) > 0; }
bool setupOpen() { return static_cast<int32_t>(provisionUntil - millis()) > 0; }
bool identifyOpen() { return static_cast<int32_t>(identifyUntil - millis()) > 0; }
String displayName() { return deviceName.isEmpty() ? deviceId : deviceName; }
// Both the operator and the agent need to tell sibling boards apart, and the
// scan response carries 29 bytes of name, so the product prefix stays short
// enough to leave room for whatever the operator calls this board.
String advertisedName() {
  String tail = deviceName.isEmpty() ? deviceId.substring(deviceId.length() - 6) : deviceName;
  return (identifyOpen() ? "IDENTIFY " : "EWP ") + tail;
}
void applyAdvertisedName() {
  keyboardName = advertisedName();
  NimBLEDevice::setDeviceName(keyboardName.c_str());
  NimBLEAdvertisementData scanResponse; scanResponse.setName(keyboardName.c_str());
  NimBLEDevice::getAdvertising()->setScanResponseData(scanResponse);
  advertisingNeeded = true;
}
bool permittedHost(NimBLEConnInfo &info) {
  String id = hostId(info.getIdAddress());
  if (!pairingOpen()) return selectedId() == id;
  bool excluded = false;
  portENTER_CRITICAL(&hidMux);
  for (auto &prior : pairingExcluded) if (id == prior) excluded = true;
  portEXIT_CRITICAL(&hidMux);
  return !excluded;
}
void clearSelection(const char *reason) {
  reserveHost(""); preferences.remove("selected"); lastError = reason;
}
bool restartAdvertising() {
  auto advertising = NimBLEDevice::getAdvertising();
  advertising->stop();
  for (int i=static_cast<int>(NimBLEDevice::getWhiteListCount())-1; i>=0; --i) {
    if (!NimBLEDevice::whiteListRemove(NimBLEDevice::getWhiteListAddress(i))) return false;
  }
  bool restricted = !pairingOpen() && !selectedId().isEmpty();
  if (restricted) {
    NimBLEAddress selected; bool found = false;
    for (int i=0; i<NimBLEDevice::getNumBonds(); ++i) {
      auto address = NimBLEDevice::getBondedAddress(i);
      if (hostId(address) == selectedId()) { selected = address; found = true; break; }
    }
    // No fallback to a different previously paired phone: when the selected
    // bond is gone the board advertises openly so it can be provisioned and
    // re-paired, rather than refusing to advertise at all and going dark.
    if (!found) { clearSelection("selected_host_missing"); restricted = false; }
    else if (!NimBLEDevice::whiteListAdd(selected)) return false;
  }
  advertising->setScanFilter(false, restricted);
  return advertising->start();
}
void appendHosts(JsonDocument &doc) {
  auto hosts = doc["hosts"].to<JsonArray>();
  JsonDocument names; deserializeJson(names, preferences.getString("hostnames", "{}"));
  for (int i=0; i<NimBLEDevice::getNumBonds(); ++i) {
    auto id = hostId(NimBLEDevice::getBondedAddress(i));
    auto item = hosts.add<JsonObject>(); item["host_id"] = id; item["selected"] = id == selectedId(); item["name"] = names[id] | "";
    item["hid_connected"] = id == selectedId() && getHid() != BLE_HS_CONN_HANDLE_NONE;
  }
}
// An agent arrives here knowing only the endpoint. `help` is how it learns
// what this board is for and which mistakes to avoid, without a human
// explaining the system first.
void appendHelp(JsonDocument &doc) {
  doc["device"] = keyboardName;
  doc["id"] = deviceId;
  doc["name"] = deviceName;
  doc["firmware"] = FIRMWARE;
  doc["role"] = "keyboard";
  doc["summary"] = "A Bluetooth keyboard and mouse. It types and clicks on one paired phone, tablet or computer at a time.";
  auto steps = doc["getting_started"].to<JsonArray>();
  steps.add("Call device_status to see Wi-Fi state, saved bonds and which host is selected.");
  steps.add("Call list_hosts for the bonds this board has saved. Each host_id is stable across reconnections and reboots.");
  steps.add("To add a target: call start_pairing, then a person pairs the Bluetooth name it returns in that target's own Bluetooth settings using the returned pairing_code. The board cannot pair on its own.");
  steps.add("Call select_host to reserve input for one saved host, then poll device_status until hid_connected is true before sending input.");
  steps.add("Use press_key and move_pointer, passing that same host_id, to type and click.");
  steps.add("Call set_name to label this board, and identify when a person needs to find it among boards that look alike.");
  auto care = doc["important"].to<JsonArray>();
  care.add("notified:true means this board sent the HID report. It does not prove the target acted on it. Verify on the target's screen.");
  care.add("press_key and move_pointer need the host_id you selected. They are refused unless that host is the selected one and is connected and subscribed, so a select_host from another agent cannot deliver your keystrokes to a different target.");
  care.add("Pass request_id on anything that changes state, and reuse the same value when you retry after a timeout. The last eight results are replayed instead of acted on twice.");
  care.add(String("This board holds ") + CONFIG_BT_NIMBLE_MAX_BONDS + " bonds and never deletes one by itself. When it is full, or store_full is true because the hosts' subscriptions filled its store, start_pairing fails; call forget_host to free a slot.");
  care.add("forget_host removes only this board's side of a bond. The target keeps its own until a person removes it there, and until then it fails to reconnect.");
  care.add("start_pairing issues a new pairing_code each time, so a code from an earlier call no longer works. The code printed on the board itself is for Wi-Fi setup and a first pairing only.");
  doc["seeing_the_screen"] = "This board has no camera or screen access. If the target is an iPhone or iPad running EWP, browse _mcp._tcp.local. for a service whose role TXT record is 'app' on the same device, and use its get_screen tool.";
  doc["discovery"] = "This endpoint advertises _mcp._tcp.local. with TXT records id, name, role, path and fw. The name record falls back to the id until set_name is called. Credentials are never advertised.";
}
void appendStatus(JsonDocument &doc) {
  doc["id"] = deviceId; doc["name"] = deviceName; doc["bluetooth_name"] = keyboardName; doc["firmware"] = FIRMWARE;
  doc["selected_host"] = selectedId(); doc["hid_connected"] = getHid() != BLE_HS_CONN_HANDLE_NONE;
  doc["pairing_open"] = pairingOpen(); doc["saved_hosts"] = NimBLEDevice::getNumBonds();
  doc["host_capacity"] = CONFIG_BT_NIMBLE_MAX_BONDS; doc["store_full"] = storeFull;
  doc["host_switching"] = true;
  if (!lastError.isEmpty()) doc["last_error"] = lastError;
  doc["ble_connections"] = NimBLEDevice::getServer()->getConnectedCount();
  doc["last_disconnect_reason"] = lastDisconnectReason;
  doc["connections_seen"] = connectionsSeen;
  doc["security_request_result"] = securityRequestResult;
  doc["authentication_state"] = authenticationState;
  doc["wifi_connected"] = WiFi.status() == WL_CONNECTED;
  doc["address"] = WiFi.status() == WL_CONNECTED ? WiFi.localIP().toString() : "";
  if (!selectedId().isEmpty() && getHid() == BLE_HS_CONN_HANDLE_NONE) doc["state"] = "waiting_for_selected_host";
  else if (selectedId().isEmpty() && lastError == "selected_host_missing") doc["state"] = "selected_host_missing";
}
bool beginPairing(JsonDocument &out) {
  if (NimBLEDevice::getNumBonds() >= CONFIG_BT_NIMBLE_MAX_BONDS) {
    out["error"] = String("All ") + CONFIG_BT_NIMBLE_MAX_BONDS + " bonds are saved; pairing was not opened and no bond was deleted. Call forget_host to free a slot.";
    return false;
  }
  char excluded[CONFIG_BT_NIMBLE_MAX_BONDS][32] = {};
  for (int i=0; i<NimBLEDevice::getNumBonds() && i<CONFIG_BT_NIMBLE_MAX_BONDS; ++i) strlcpy(excluded[i], hostId(NimBLEDevice::getBondedAddress(i)).c_str(), 32);
  portENTER_CRITICAL(&hidMux); memcpy(pairingExcluded, excluded, sizeof(excluded)); portEXIT_CRITICAL(&hidMux);
  setHid(BLE_HS_CONN_HANDLE_NONE);
  portENTER_CRITICAL(&hidMux); pairingHandle = BLE_HS_CONN_HANDLE_NONE; portEXIT_CRITICAL(&hidMux);
  // Secure Connections passkey entry leaks a reused passkey across attempts,
  // so each window gets its own code. loop() restores the setup code when the
  // window closes, because that is the one printed on the board's label.
  passkey = 100000 + esp_random() % 900000;
  NimBLEDevice::setSecurityPasskey(passkey);
  pairingUntil = millis()+180000;
  for (auto peer : NimBLEDevice::getServer()->getPeerDevices()) NimBLEDevice::getServer()->disconnect(peer);
  advertisingNeeded = true;
  out["pairing_open"] = true; out["name"] = keyboardName; out["expires_seconds"] = 180;
  out["pairing_code"] = passkey;
  return true;
}
bool chooseHost(const String &id, JsonDocument &out) {
  bool found = false;
  for (int i=0; i<NimBLEDevice::getNumBonds(); ++i) if (hostId(NimBLEDevice::getBondedAddress(i)) == id) found = true;
  if (!found) { out["error"] = "Unknown saved host; pair it first"; return false; }
  pairingUntil = 0; reserveHost(id); preferences.putString("selected", id);
  for (auto peer : NimBLEDevice::getServer()->getPeerDevices()) NimBLEDevice::getServer()->disconnect(peer);
  advertisingNeeded = true;
  out["selected_host"] = id; out["connected"] = false; out["state"] = "waiting_for_selected_host";
  return true;
}
bool persistName(const String &value, JsonDocument &out) {
  if (value.length() > 32) { out["error"] = "Name is limited to 32 bytes"; return false; }
  for (size_t i=0; i<value.length(); ++i) {
    if (value[i] < 0x20 || value[i] > 0x7e) { out["error"] = "Name must be printable ASCII"; return false; }
  }
  deviceName = value; preferences.putString("name", value);
  applyAdvertisedName();
  // Setting the TXT item again replaces it. Ending and restarting the
  // responder instead leaves the service advertised but unresolvable until
  // the board reboots, which takes a renamed board off the network.
  if (mdnsStarted) MDNS.addServiceTxt("mcp", "tcp", "name", displayName());
  out["id"] = deviceId; out["name"] = deviceName; out["bluetooth_name"] = keyboardName;
  return true;
}
bool beginIdentify(int seconds, JsonDocument &out) {
  if (seconds < 1 || seconds > 30) { out["error"] = "seconds must be between 1 and 30"; return false; }
  identifyUntil = millis() + static_cast<uint32_t>(seconds) * 1000;
  applyAdvertisedName();
  uint16_t target = getHid();
  bool woke = false;
  if (target != BLE_HS_CONN_HANDLE_NONE) {
    // A modifier-only report wakes the screen of the host this board drives
    // without typing anything into it, which is what shows the operator the
    // controller-to-phone binding.
    uint8_t report[8] = {0x01, 0,0,0,0,0,0,0};
    woke = keyboard->notify(report, sizeof(report), target); delay(20);
    memset(report, 0, sizeof(report));
    woke = keyboard->notify(report, sizeof(report), target) && woke;
  }
  out["identifying_seconds"] = seconds; out["bluetooth_name"] = keyboardName; out["host_notified"] = woke;
  out["note"] = "This board has no user LED. It advertises under the Bluetooth name above for the duration, and woke the screen of the host it drives with a modifier-only key.";
  return true;
}
void cancelPairing(JsonDocument &out) {
  pairingUntil = 0;
  portENTER_CRITICAL(&hidMux); pairingHandle = BLE_HS_CONN_HANDLE_NONE; portEXIT_CRITICAL(&hidMux);
  advertisingNeeded = true;
  out["pairing_open"] = false; out["selected_host"] = selectedId(); out["saved_hosts"] = NimBLEDevice::getNumBonds();
}
bool forgetHost(const String &id, JsonDocument &out) {
  for (int i=0; i<NimBLEDevice::getNumBonds(); ++i) {
    auto address = NimBLEDevice::getBondedAddress(i);
    if (hostId(address) != id) continue;
    if (!NimBLEDevice::deleteBond(address)) { out["error"] = "The bond could not be deleted"; return false; }
    storeFull = false;
    if (selectedId() == id) { reserveHost(""); preferences.remove("selected"); }
    JsonDocument names; deserializeJson(names, preferences.getString("hostnames", "{}"));
    names.remove(id); String value; serializeJson(names, value); preferences.putString("hostnames", value);
    advertisingNeeded = true;
    out["forgot"] = id; out["saved_hosts"] = NimBLEDevice::getNumBonds();
    out["host_capacity"] = CONFIG_BT_NIMBLE_MAX_BONDS; out["selected_host"] = selectedId();
    out["next_step"] = "Only this board's side of the bond is gone. The target keeps its own, so it will fail to reconnect until a person taps Forget This Device for this keyboard in the target's Bluetooth settings.";
    return true;
  }
  out["error"] = "Unknown saved host"; return false;
}
// A bonded phone reconnects to a known keyboard within about a second, so
// disconnecting one that is not the host in use puts it in a reconnect loop
// that starves the phone being paired. Keep it connected with no HID handle.
bool parkedPeer(NimBLEConnInfo &info) { return !permittedHost(info) && info.isBonded(); }
void acceptSubscribedHost(NimBLEConnInfo &info) {
  bool subscribed = false;
  for (auto &entry : subscriptions) if (entry.handle == info.getConnHandle() && entry.reports) subscribed = true;
  if (!subscribed || !info.isEncrypted() || !info.isAuthenticated()) return;
  if (parkedPeer(info)) return;
  uint16_t current = getHid();
  if (!permittedHost(info) || (current != BLE_HS_CONN_HANDLE_NONE && current != info.getConnHandle())) {
    NimBLEDevice::getServer()->disconnect(info.getConnHandle()); return;
  }
  String id = hostId(info.getIdAddress());
  if (pairingOpen()) {
    reserveHost(id); pairingUntil = 0;
    HostEvent event{}; strlcpy(event.id, id.c_str(), sizeof(event.id)); xQueueOverwrite(hostEvents, &event);
    advertisingNeeded = true;
  }
  setHid(info.getConnHandle());
}
class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer *server, NimBLEConnInfo &info) override {
    ++connectionsSeen; authenticationState = 0;
    if (pairingOpen()) {
      if (NimBLEDevice::isBonded(info.getIdAddress())) {
        // Parked, so it never takes the pairing slot. The controller allows
        // three links at once; the last one stays free for the new phone.
        bool reserved;
        portENTER_CRITICAL(&hidMux); reserved = pairingHandle == BLE_HS_CONN_HANDLE_NONE; portEXIT_CRITICAL(&hidMux);
        if (reserved && server->getConnectedCount() >= CONFIG_BT_NIMBLE_MAX_CONNECTIONS) {
          server->disconnect(info.getConnHandle()); return;
        }
      } else {
        bool accepted;
        portENTER_CRITICAL(&hidMux);
        accepted = pairingHandle == BLE_HS_CONN_HANDLE_NONE || pairingHandle == info.getConnHandle();
        if (accepted) pairingHandle = info.getConnHandle();
        portEXIT_CRITICAL(&hidMux);
        if (!accepted) { server->disconnect(info.getConnHandle()); return; }
      }
    }
    for (auto &entry : subscriptions) if (entry.handle == BLE_HS_CONN_HANDLE_NONE) {
      entry.handle = info.getConnHandle(); entry.reports = 0; break;
    }
    // Let the central negotiate connection parameters during initial pairing.
    int result = 0;
    NimBLEDevice::startSecurity(info.getConnHandle(), &result);
    securityRequestResult = result;
    advertisingNeeded = true;
  }
  void onDisconnect(NimBLEServer *, NimBLEConnInfo &info, int reason) override {
    lastDisconnectReason = reason;
    for (auto &entry : subscriptions) if (entry.handle == info.getConnHandle()) entry = Subscription{};
    if (getHid() == info.getConnHandle()) setHid(BLE_HS_CONN_HANDLE_NONE);
    portENTER_CRITICAL(&hidMux);
    if (pairingHandle == info.getConnHandle()) pairingHandle = BLE_HS_CONN_HANDLE_NONE;
    portEXIT_CRITICAL(&hidMux);
    advertisingNeeded = true;
  }
  uint32_t onPassKeyDisplay() override { return passkey; }
  void onAuthenticationComplete(NimBLEConnInfo &info) override {
    authenticationState = info.isEncrypted() && info.isAuthenticated() ? 1 : -1;
    if (!info.isEncrypted() || !info.isAuthenticated()) {
      NimBLEDevice::getServer()->disconnect(info.getConnHandle()); return;
    }
    if (parkedPeer(info)) {
      // Its identity address may only have resolved now, so release the
      // pairing slot it was given on connect.
      portENTER_CRITICAL(&hidMux);
      if (pairingHandle == info.getConnHandle()) pairingHandle = BLE_HS_CONN_HANDLE_NONE;
      portEXIT_CRITICAL(&hidMux);
      return;
    }
    if (!permittedHost(info) && !setupOpen()) NimBLEDevice::getServer()->disconnect(info.getConnHandle());
    else acceptSubscribedHost(info);
  }
} serverCallbacks;

class DeviceCallbacks : public NimBLEDeviceCallbacks {
  // NimBLE's default store handler answers an overflow with
  // ble_gap_unpair_oldest_except, which deletes a bond nobody asked it to
  // delete. Refusing the store fails the write instead, which is the promise
  // the product makes: a saved host disappears only when told to.
  int onStoreStatus(struct ble_store_status_event *, void *) override {
    storeFull = true; return BLE_HS_ESTORE_CAP;
  }
} deviceCallbacks;

class ReportCallbacks : public NimBLECharacteristicCallbacks {
  void onSubscribe(NimBLECharacteristic *report, NimBLEConnInfo &info, uint16_t value) override {
    for (auto &entry : subscriptions) if (entry.handle == info.getConnHandle()) {
      uint8_t bit = report == keyboard ? 1 : 2;
      if (value) entry.reports |= bit; else entry.reports &= ~bit;
      if (!entry.reports && getHid() == info.getConnHandle()) setHid(BLE_HS_CONN_HANDLE_NONE);
    }
    acceptSubscribedHost(info);
  }
} reportCallbacks;

class ProvisionCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *characteristic, NimBLEConnInfo &info) override {
    JsonDocument doc;
    auto value = characteristic->getValue();
    // Drop sensitive data from the readable characteristic immediately.
    characteristic->setValue("");
    if (!info.isAuthenticated() || !info.isEncrypted() || !setupOpen()) return;
    if (value.size() > 512 || deserializeJson(doc, value.c_str(), value.size())) return;
    String ssid = doc["ssid"] | "", password = doc["password"] | "";
    if (ssid.length() < 1 || ssid.length() > 32 || password.length() > 64) return;
    Configuration config{};
    strlcpy(config.ssid, ssid.c_str(), sizeof(config.ssid));
    strlcpy(config.password, password.c_str(), sizeof(config.password));
    xQueueOverwrite(configurationQueue, &config);
  }
} provisionCallbacks;

void jsonReply(int code, JsonDocument &doc) {
  String output; serializeJson(doc, output);
  http.sendHeader("Connection", "close"); http.send(code, "application/json", output);
}
bool authorized() {
  String expected = "Bearer " + token, actual = http.header("Authorization");
  uint8_t difference = actual.length() == expected.length() ? 0 : 1;
  for (size_t i = 0; i < expected.length(); ++i)
    difference |= static_cast<uint8_t>(expected[i] ^ (i < actual.length() ? actual[i] : 0));
  if (token.isEmpty() || difference || http.hasHeader("Origin")) {
    http.send(401, "application/json", "{\"error\":\"Unauthorized\"}"); return false;
  }
  return true;
}
// Each board is its own stateless MCP endpoint; no computer forwards input.
void rpcError(JsonDocument &reply, int code, const char *message) {
  auto error = reply["error"].to<JsonObject>(); error["code"] = code; error["message"] = message;
}
void toolText(JsonDocument &reply, const String &text, bool failed) {
  auto result = reply["result"].to<JsonObject>(); result["isError"] = failed;
  auto item = result["content"].to<JsonArray>().add<JsonObject>();
  item["type"] = "text"; item["text"] = text;
}
void toolText(JsonDocument &reply, JsonDocument &data, bool failed = false) {
  String text; serializeJson(data, text); toolText(reply, text, failed);
}
// A client that retried after an HTTP timeout must not type the key twice.
struct Replay { String id, text; bool failed; };
Replay replays[8];
uint8_t nextReplay = 0;
void addTool(JsonArray tools, const char *name, const String &description, const char *schema) {
  auto tool = tools.add<JsonObject>(); tool["name"] = name; tool["description"] = description;
  JsonDocument parsed; deserializeJson(parsed, schema); tool["inputSchema"] = parsed.as<JsonObject>();
}
void appendHelp(JsonDocument &doc);
void appendStatus(JsonDocument &doc);
void appendHosts(JsonDocument &doc);
bool beginPairing(JsonDocument &out);
bool chooseHost(const String &id, JsonDocument &out);

void handleMCP() {
  if (!authorized()) return;
  JsonDocument request, reply;
  reply["jsonrpc"] = "2.0";
  if (http.arg("plain").length() > 4096 || deserializeJson(request, http.arg("plain"))) {
    reply["id"] = nullptr; rpcError(reply, -32700, "Invalid JSON request"); jsonReply(200, reply); return;
  }
  if (request["jsonrpc"] != "2.0" || !request["method"].is<String>() ||
      (!request["id"].isNull() && !request["id"].is<String>() && !request["id"].is<int>())) {
    reply["id"] = nullptr; rpcError(reply, -32600, "Invalid JSON-RPC request"); jsonReply(200, reply); return;
  }
  String method = request["method"];
  if (request["id"].isNull() && method.startsWith("notifications/")) { http.send(202); return; }
  reply["id"] = request["id"];
  if (method == "initialize") {
    auto result = reply["result"].to<JsonObject>(); result["protocolVersion"] = "2025-03-26";
    result["capabilities"]["tools"].to<JsonObject>();
    result["serverInfo"]["name"] = "EWP keyboard " + displayName(); result["serverInfo"]["version"] = FIRMWARE;
  } else if (method == "ping") {
    reply["result"].to<JsonObject>();
  } else if (method == "tools/list") {
    auto tools = reply["result"]["tools"].to<JsonArray>();
    // Several MCP clients show the model only tool descriptions, so each one
    // names the board it drives; five controllers in one client are otherwise
    // five identical press_key tools.
    String prefix = "[" + displayName() + "] ";
    addTool(tools, "help", prefix + "Explain what this device is, how to pair and select a target, and what its results do and do not prove. Call this first.", R"({"type":"object","properties":{},"additionalProperties":false})");
    addTool(tools, "device_status", prefix + "Read this keyboard's name, Wi-Fi, pairing and selected-host status.", R"({"type":"object","properties":{},"additionalProperties":false})");
    addTool(tools, "list_hosts", prefix + "List Bluetooth bonds persisted on this ESP32, with stable host IDs.", R"({"type":"object","properties":{},"additionalProperties":false})");
    addTool(tools, "start_pairing", prefix + "Disconnect input and advertise for a new host. Existing bonds stay saved. Pair the returned Bluetooth name in the target's own Bluetooth settings, with the pairing_code from this call and no earlier one.", R"({"type":"object","properties":{"name":{"type":"string","maxLength":64},"request_id":{"type":"string","maxLength":64}},"additionalProperties":false})");
    addTool(tools, "cancel_pairing", prefix + "Close the pairing window now and go back to advertising for the selected host.", R"({"type":"object","properties":{"request_id":{"type":"string","maxLength":64}},"additionalProperties":false})");
    addTool(tools, "select_host", prefix + "Reserve input for one saved host and advertise to it. A different host can never receive input while reconnection is pending.", R"({"type":"object","properties":{"host_id":{"type":"string"},"name":{"type":"string","maxLength":64},"request_id":{"type":"string","maxLength":64}},"required":["host_id"],"additionalProperties":false})");
    addTool(tools, "forget_host", prefix + "Delete one saved bond to free a slot. Pass confirm with this board's id. The target keeps its own bond until a person removes it there.", R"({"type":"object","properties":{"host_id":{"type":"string"},"confirm":{"type":"string"},"request_id":{"type":"string","maxLength":64}},"required":["host_id","confirm"],"additionalProperties":false})");
    addTool(tools, "set_name", prefix + "Name this board for people and agents. The name persists, appears in the Bluetooth name, the mDNS TXT records and every tool description.", R"({"type":"object","properties":{"name":{"type":"string","maxLength":32},"request_id":{"type":"string","maxLength":64}},"required":["name"],"additionalProperties":false})");
    addTool(tools, "identify", prefix + "Make this board announce itself: it advertises as IDENTIFY <name> and wakes the screen of the host it drives.", R"({"type":"object","properties":{"seconds":{"type":"integer","minimum":1,"maximum":30,"default":10},"request_id":{"type":"string","maxLength":64}},"additionalProperties":false})");
    addTool(tools, "press_key", prefix + "Press and release one HID keyboard usage on the host_id you selected, which must be the selected and connected host. Enter=40, Tab=43, Escape=41, Space=44; left GUI modifier=8. Check the target screen to verify its action.", R"({"type":"object","properties":{"host_id":{"type":"string"},"usage":{"type":"integer","minimum":4,"maximum":101},"modifiers":{"type":"integer","minimum":0,"maximum":255,"default":0},"request_id":{"type":"string","maxLength":64}},"required":["host_id","usage"],"additionalProperties":false})");
    addTool(tools, "move_pointer", prefix + "Relative mouse movement, wheel scrolling or a left click on the host_id you selected, which must be the selected and connected host. iPhone pointer control requires AssistiveTouch.", R"({"type":"object","properties":{"host_id":{"type":"string"},"dx":{"type":"integer","minimum":-127,"maximum":127,"default":0},"dy":{"type":"integer","minimum":-127,"maximum":127,"default":0},"wheel":{"type":"integer","minimum":-127,"maximum":127,"default":0},"click":{"type":"boolean","default":false},"request_id":{"type":"string","maxLength":64}},"required":["host_id"],"additionalProperties":false})");
  } else if (method == "tools/call") {
    String name = request["params"]["name"] | "";
    auto args = request["params"]["arguments"].as<JsonObject>();
    JsonDocument out; bool failed = false;
    String requestId = args["request_id"] | "";
    if (requestId.length() > 64) {
      out["error"] = "request_id is limited to 64 bytes"; toolText(reply, out, true); jsonReply(200, reply); return;
    }
    for (auto &entry : replays) if (!requestId.isEmpty() && entry.id == requestId) {
      toolText(reply, entry.text, entry.failed); jsonReply(200, reply); return;
    }
    if (name == "help") appendHelp(out);
    else if (name == "device_status") appendStatus(out);
    else if (name == "list_hosts") appendHosts(out);
    else if (name == "start_pairing") {
      pendingHostName = args["name"] | "";
      if (pendingHostName.length() > 64) { out["error"] = "Host name is limited to 64 bytes"; failed = true; }
      else failed = !beginPairing(out);
    }
    else if (name == "cancel_pairing") cancelPairing(out);
    else if (name == "select_host") {
      if (!args["host_id"].is<String>()) { out["error"] = "host_id is required"; failed = true; }
      else if ((!args["name"].isNull() && !args["name"].is<String>()) || args["name"].as<String>().length() > 64) {
        out["error"] = "Host name is limited to 64 bytes"; failed = true;
      } else {
        String id = args["host_id"].as<String>(); failed = !chooseHost(id, out);
        if (!failed && args["name"].is<String>()) {
          JsonDocument names; deserializeJson(names, preferences.getString("hostnames", "{}")); names[id] = args["name"].as<String>();
          String value; serializeJson(names, value); preferences.putString("hostnames", value);
        }
      }
    }
    else if (name == "forget_host") {
      if (!args["host_id"].is<String>()) { out["error"] = "host_id is required"; failed = true; }
      else if (args["confirm"].as<String>() != deviceId) {
        out["error"] = "confirm must be this board's id"; out["id"] = deviceId; failed = true;
      }
      else failed = !forgetHost(args["host_id"].as<String>(), out);
    }
    else if (name == "set_name") {
      if (!args["name"].is<String>()) { out["error"] = "name is required"; failed = true; }
      else failed = !persistName(args["name"].as<String>(), out);
    }
    else if (name == "identify") {
      if (!args["seconds"].isNull() && !args["seconds"].is<int>()) { out["error"] = "seconds must be an integer"; failed = true; }
      else failed = !beginIdentify(args["seconds"] | 10, out);
    }
    else if (name == "press_key" || name == "move_pointer") {
      uint16_t target = getHid();
      if (!args["host_id"].is<String>()) { out["error"] = "host_id is required"; failed = true; }
      else if (args["host_id"].as<String>() != selectedId()) {
        out["error"] = "host_id is not the selected and connected host"; out["selected_host"] = selectedId(); failed = true;
      }
      else if (target == BLE_HS_CONN_HANDLE_NONE) { out["error"] = "Selected host is not connected and subscribed"; failed = true; }
      else if (name == "press_key") {
        if (!args["usage"].is<int>() || args["usage"].as<int>() < 4 || args["usage"].as<int>() > 101 ||
            (!args["modifiers"].isNull() && (!args["modifiers"].is<int>() || args["modifiers"].as<int>() < 0 || args["modifiers"].as<int>() > 255))) {
          out["error"] = "Invalid HID usage or modifiers"; failed = true;
        } else {
          uint8_t report[8] = {static_cast<uint8_t>(args["modifiers"] | 0), 0, static_cast<uint8_t>(args["usage"].as<int>()), 0,0,0,0,0};
          bool sent = keyboard->notify(report, sizeof(report), target); delay(20);
          memset(report, 0, sizeof(report)); bool released = keyboard->notify(report, sizeof(report), target);
          out["notified"] = sent && released; out["host_action_verified"] = false;
          out["sequence"] = ++inputSequence; out["sent_ms"] = millis(); failed = !(sent && released);
        }
      } else {
        for (const char *key : {"dx", "dy", "wheel"}) {
          if (!args[key].isNull() && (!args[key].is<int>() || args[key].as<int>() < -127 || args[key].as<int>() > 127)) failed = true;
        }
        if (!args["click"].isNull() && !args["click"].is<bool>()) failed = true;
        if (failed) out["error"] = "Invalid pointer input";
        else {
          uint8_t report[] = {static_cast<uint8_t>(args["click"].as<bool>() ? 1 : 0), static_cast<uint8_t>(args["dx"] | 0), static_cast<uint8_t>(args["dy"] | 0), static_cast<uint8_t>(args["wheel"] | 0)};
          bool sent = mouse->notify(report, sizeof(report), target); delay(20);
          memset(report, 0, sizeof(report)); bool released = mouse->notify(report, sizeof(report), target);
          out["notified"] = sent && released; out["host_action_verified"] = false;
          out["sequence"] = ++inputSequence; out["sent_ms"] = millis(); failed = !(sent && released);
        }
      }
    } else { out["error"] = "Unknown tool"; failed = true; }
    String text; serializeJson(out, text);
    if (!requestId.isEmpty()) {
      replays[nextReplay] = Replay{requestId, text, failed};
      nextReplay = (nextReplay + 1) % (sizeof(replays)/sizeof(replays[0]));
    }
    toolText(reply, text, failed);
  } else rpcError(reply, -32601, "Method not found");
  jsonReply(200, reply);
}
void setupHttp() {
  const char *headers[] = {"Authorization", "Origin"}; http.collectHeaders(headers, 2);
  http.on("/mcp", HTTP_POST, handleMCP);
  http.on("/mcp", HTTP_GET, [] { if (authorized()) { http.sendHeader("Allow", "POST"); http.send(405); } });
  http.onNotFound([] { http.send(404, "application/json", "{\"error\":\"Not found\"}"); });
  http.begin();
}

void setup() {
  Serial.begin(115200);
  preferences.begin("ewp", false);
  // getEfuseMac() copies the six address bytes into a uint64_t in memory order,
  // so the OUI sits in the low bytes here, not the high ones.
  uint64_t mac = ESP.getEfuseMac(); char digits[13] = {};
  for (int i=0; i<6; ++i) snprintf(digits + i*2, 3, "%02x", static_cast<uint8_t>(mac >> (8*i)));
  deviceId = String("ewp-") + digits;
  deviceName = preferences.getString("name", "");
  setupCode = preferences.getUInt("passkey", 0);
  if (!setupCode) { setupCode = 100000 + esp_random() % 900000; preferences.putUInt("passkey", setupCode); }
  passkey = setupCode;
  // The setup code is physical setup data, and it only covers Wi-Fi setup and a
  // first pairing; start_pairing issues its own code. Never print Wi-Fi
  // credentials or bridge tokens.
  Serial.printf("\nEWP %s\nBluetooth setup code: %06u\n", deviceId.c_str(), setupCode);
  provisionUntil = millis() + 300000;
  configurationQueue = xQueueCreate(1, sizeof(Configuration));
  hostEvents = xQueueCreate(1, sizeof(HostEvent));
  reserveHost(preferences.isKey("selected") ? preferences.getString("selected") : "");

  WiFi.mode(WIFI_STA); WiFi.setAutoReconnect(true);
  token = preferences.isKey("token") ? preferences.getString("token") : "";
  if (token.length() != 64) {
    token = "";
    for (int i=0; i<8; ++i) { char part[9]; snprintf(part, sizeof(part), "%08lx", static_cast<unsigned long>(esp_random())); token += part; }
    preferences.putString("token", token);
  }
  String ssid = preferences.isKey("ssid") ? preferences.getString("ssid") : "";
  if (!ssid.isEmpty()) WiFi.begin(ssid.c_str(), preferences.getString("password", "").c_str());
  keyboardName = advertisedName();
  NimBLEDevice::setDeviceCallbacks(&deviceCallbacks);
  NimBLEDevice::init(keyboardName.c_str());
  // Only a board that has never been paired opens a pairing window by itself.
  // A power blip must not offer a wall of boards to anyone in the room.
  if (NimBLEDevice::getNumBonds() == 0) pairingUntil = millis() + 300000;
  bool selectedBonded = selectedId().isEmpty();
  for (int i=0; i<NimBLEDevice::getNumBonds(); ++i)
    if (hostId(NimBLEDevice::getBondedAddress(i)) == selectedId()) selectedBonded = true;
  if (!selectedBonded) clearSelection("selected_host_missing");
  NimBLEDevice::setSecurityAuth(true, true, true);
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_DISPLAY_ONLY);
  NimBLEDevice::setSecurityPasskey(passkey);
  auto server = NimBLEDevice::createServer(); server->setCallbacks(&serverCallbacks);
  auto hid = new NimBLEHIDDevice(server);
  keyboard = hid->getInputReport(1); mouse = hid->getInputReport(2);
  keyboard->setCallbacks(&reportCallbacks); mouse->setCallbacks(&reportCallbacks);
  hid->setManufacturer("UnlikeOtherAI"); hid->setHidInfo(0, 1);
  hid->setReportMap(reportMap, sizeof(reportMap)); hid->setBatteryLevel(100);
  auto service = server->createService(SERVICE);
  auto config = service->createCharacteristic(CONFIG, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_AUTHEN, 512);
  config->setCallbacks(&provisionCallbacks);
  statusCharacteristic = service->createCharacteristic(STATUS_UUID, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
  statusCharacteristic->setValue("{\"state\":\"ready\"}");
  // NimBLE 2.3.x registers each service explicitly before starting GATT.
  hid->startServices();
  service->start();
  server->start();
  auto advertising = NimBLEDevice::getAdvertising();
  advertising->setAppearance(0x03C1);
  advertising->addServiceUUID(SERVICE); advertising->addServiceUUID(NimBLEUUID((uint16_t)0x1812)); advertising->enableScanResponse(true);
  applyAdvertisedName();
  advertisingNeeded = !restartAdvertising();
  setupHttp();
}

// One-off physical USB setup; these responses are never emitted unsolicited.
// The setup client stores access material privately instead of printing it.
void serialSetup() {
  static String line;
  while (Serial.available()) {
    char c = Serial.read();
    if (c != '\n') { if (line.length() < 1024) line += c; else line = ""; continue; }
    JsonDocument request, reply;
    if (!deserializeJson(request, line)) {
      String method = request["method"] | "";
      if (method == "access") { reply["id"] = deviceId; reply["token"] = token; reply["pairing_code"] = passkey; reply["name"] = deviceName; }
      else if (method == "set_name") {
        if (!request["name"].is<String>()) reply["error"] = "A name string is required";
        else persistName(request["name"].as<String>(), reply);
      }
      else if (method == "setup_wifi") {
        String ssid = request["ssid"] | "", password = request["password"] | "";
        if (ssid.length() > 0 && ssid.length() <= 32 && password.length() <= 64) {
          Configuration config{}; strlcpy(config.ssid, ssid.c_str(), sizeof(config.ssid));
          strlcpy(config.password, password.c_str(), sizeof(config.password));
          xQueueOverwrite(configurationQueue, &config); reply["submitted"] = true;
        } else reply["error"] = "Invalid Wi-Fi configuration";
      } else if (method == "status") appendStatus(reply);
      else reply["error"] = "Unknown USB setup command";
      serializeJson(reply, Serial); Serial.println();
    }
    line = "";
  }
}
void loop() {
  serialSetup();
  HostEvent hostEvent;
  if (xQueueReceive(hostEvents, &hostEvent, 0) == pdTRUE) {
    preferences.putString("selected", hostEvent.id);
    if (!pendingHostName.isEmpty()) {
      JsonDocument names; deserializeJson(names, preferences.getString("hostnames", "{}")); names[hostEvent.id] = pendingHostName;
      String json; serializeJson(names, json); preferences.putString("hostnames", json); pendingHostName = "";
    }
  }
  static bool wasPairing = false;
  bool open = pairingOpen();
  if (wasPairing != open) {
    if (!open) { passkey = setupCode; NimBLEDevice::setSecurityPasskey(setupCode); }
    advertisingNeeded = true; wasPairing = open;
  }
  static bool wasIdentifying = false;
  bool identifying = identifyOpen();
  if (wasIdentifying != identifying) { wasIdentifying = identifying; applyAdvertisedName(); }
  static uint32_t nextAdvertisingAttempt = 0;
  if (advertisingNeeded && static_cast<int32_t>(millis()-nextAdvertisingAttempt) >= 0) {
    advertisingNeeded = !restartAdvertising(); nextAdvertisingAttempt = millis()+1000;
  }
  Configuration config;
  if (xQueueReceive(configurationQueue, &config, 0) == pdTRUE) {
    preferences.putString("ssid", config.ssid); preferences.putString("password", config.password);
    WiFi.disconnect(); WiFi.begin(config.ssid, config.password);
    memset(&config, 0, sizeof(config)); setupStatus = "joining";
  }
  static uint32_t nextMdnsAttempt = 0;
  if (WiFi.status() == WL_CONNECTED && !mdnsStarted && static_cast<int32_t>(millis()-nextMdnsAttempt) >= 0) {
    nextMdnsAttempt = millis()+2000;
    mdnsStarted = MDNS.begin(deviceId.c_str());
    if (mdnsStarted) {
      MDNS.addService("mcp", "tcp", 80); MDNS.addServiceTxt("mcp", "tcp", "id", deviceId);
      MDNS.addServiceTxt("mcp", "tcp", "path", "/mcp"); MDNS.addServiceTxt("mcp", "tcp", "role", "keyboard");
      MDNS.addServiceTxt("mcp", "tcp", "name", displayName()); MDNS.addServiceTxt("mcp", "tcp", "fw", FIRMWARE);
    }
    if (mdnsStarted) Serial.printf("Wi-Fi connected, address: %s\n", WiFi.localIP().toString().c_str());
  }
  if (WiFi.status() != WL_CONNECTED && mdnsStarted) { MDNS.end(); mdnsStarted = false; }
  static uint32_t lastStatus = 0;
  if (millis() - lastStatus > 1000) {
    JsonDocument doc; doc["id"] = deviceId;
    doc["state"] = WiFi.status() == WL_CONNECTED ? "connected" : setupStatus;
    doc["ip"] = WiFi.status() == WL_CONNECTED ? WiFi.localIP().toString() : "";
    doc["setup_open"] = setupOpen();
    String output; serializeJson(doc, output); statusCharacteristic->setValue(output.c_str());
    statusCharacteristic->notify(); lastStatus = millis();
  }
  http.handleClient(); delay(2);
}

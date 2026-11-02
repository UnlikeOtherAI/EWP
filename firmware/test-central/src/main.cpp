#include <Arduino.h>
#include <ArduinoJson.h>
#include <NimBLEDevice.h>

// Stands in for a phone. It finds the keyboard, bonds, subscribes to the HID
// input reports and records what arrives, so the whole chain can be checked
// without a person tapping a dialog. It also reads the attributes iOS is said
// to care about, and reports whether they were readable without encryption,
// which is a claim about iOS that can at least be measured here.
static const NimBLEUUID EWP_SERVICE("e7a00001-7c3d-4d21-a19a-455750000001");
static const NimBLEUUID HID_SERVICE((uint16_t)0x1812);
static const NimBLEUUID REPORT_CHR((uint16_t)0x2a4d);
static const NimBLEUUID REPORT_MAP((uint16_t)0x2a4b);
static const NimBLEUUID HID_INFO((uint16_t)0x2a4a);

String lastEvent = "idle", lastReport = "", mapBeforeEncryption = "untried";
String profileName = "android";
int connections = 0, failures = 0, reportsSeen = 0, subscribed = 0;
volatile bool encrypted = false;
NimBLEAdvertisedDevice *target = nullptr;
NimBLEClient *held = nullptr;

static String hex(const uint8_t *data, size_t length) {
  String out;
  for (size_t i = 0; i < length; ++i) {
    char pair[4]; snprintf(pair, sizeof(pair), "%02x", data[i]);
    out += pair; if (i + 1 < length) out += ' ';
  }
  return out;
}

// Keep the recent ones, not just the last. A key press sends two reports, the
// press and the release, and the release is all zeros: sampling only the last
// one proves a report arrived and nothing about which key it was.
static const int RECENT = 6;
String recent[RECENT];
int recentNext = 0;

static void onReport(NimBLERemoteCharacteristic *chr, uint8_t *data, size_t length, bool isNotify) {
  ++reportsSeen;
  lastReport = hex(data, length);
  recent[recentNext] = lastReport;
  recentNext = (recentNext + 1) % RECENT;
  lastEvent = "report";
  // Printed as it happens. Asking over the same serial line that resets this
  // board is a race; a stream is not.
  Serial.printf("{\"report\":\"%s\",\"n\":%d}\n", lastReport.c_str(), reportsSeen);
}

class ClientCallbacks : public NimBLEClientCallbacks {
  void onConnect(NimBLEClient *client) override { ++connections; lastEvent = "connected"; }
  void onDisconnect(NimBLEClient *client, int reason) override {
    encrypted = false; subscribed = 0;
    lastEvent = String("disconnected reason=") + reason;
  }
  void onAuthenticationComplete(NimBLEConnInfo &info) override {
    encrypted = info.isEncrypted();
    lastEvent = info.isEncrypted() ? "encrypted" : "encryption failed";
    if (!info.isEncrypted()) ++failures;
  }
} clientCallbacks;

class ScanCallbacks : public NimBLEScanCallbacks {
  void onResult(const NimBLEAdvertisedDevice *device) override {
    if (!device->isAdvertisingService(EWP_SERVICE) || target) return;
    target = new NimBLEAdvertisedDevice(*device);
    NimBLEDevice::getScan()->stop();
    lastEvent = String("found ") + device->getName().c_str();
  }
} scanCallbacks;

void report() {
  JsonDocument doc;
  doc["role"] = "test-central";
  doc["profile"] = profileName;
  doc["event"] = lastEvent;
  doc["connections"] = connections;
  doc["failures"] = failures;
  doc["encrypted"] = encrypted;
  doc["connected"] = held && held->isConnected();
  doc["subscribed_reports"] = subscribed;
  doc["reports_seen"] = reportsSeen;
  doc["last_report"] = lastReport;
  { auto list = doc["recent_reports"].to<JsonArray>();
    for (int i = 0; i < RECENT; ++i) {
      const String &entry = recent[(recentNext + i) % RECENT];
      if (entry.length()) list.add(entry);
    } }
  doc["report_map_without_encryption"] = mapBeforeEncryption;
  doc["bonded_peers"] = NimBLEDevice::getNumBonds();
  doc["target"] = target ? target->getAddress().toString().c_str() : "";
  serializeJson(doc, Serial); Serial.println();
}

// Before asking for security, try the attribute iOS is said to require
// encryption on. A device that hands it over in the clear is the thing the
// vendor documentation warns about, so measure it rather than assume it.
static void probeBeforeEncryption() {
  auto hid = held->getService(HID_SERVICE);
  if (!hid) { mapBeforeEncryption = "no hid service"; return; }
  auto map = hid->getCharacteristic(REPORT_MAP);
  if (!map) { mapBeforeEncryption = "no report map"; return; }
  NimBLEAttValue value = map->readValue();
  mapBeforeEncryption = value.length() ? String("readable, ") + value.length() + " bytes"
                                       : "refused or empty";
}

static void subscribeToReports() {
  auto hid = held->getService(HID_SERVICE);
  if (!hid) { lastEvent = "no hid service after encryption"; return; }
  for (auto chr : hid->getCharacteristics(true)) {
    if (chr->getUUID() != REPORT_CHR || !chr->canNotify()) continue;
    if (chr->subscribe(true, onReport)) ++subscribed;
  }
  lastEvent = subscribed ? String("subscribed to ") + subscribed + " reports"
                         : "no report characteristic took a subscription";
}

void attempt(bool probeFirst) {
  if (!target) { lastEvent = "no target yet"; return; }
  if (held) { NimBLEDevice::deleteClient(held); held = nullptr; }
  held = NimBLEDevice::createClient();
  held->setClientCallbacks(&clientCallbacks, false);
  // Delete cached attributes on connect. Keeping them reuses a GATT table
  // from a session whose bond has since been cleared, and the link then
  // connects but never encrypts.
  if (!held->connect(target, true)) { ++failures; lastEvent = "connect refused"; return; }
  if (probeFirst) probeBeforeEncryption();
  held->secureConnection();
  for (int i = 0; i < 50 && !encrypted; ++i) delay(100);
  if (!encrypted) { lastEvent = "connected but never encrypted"; return; }
  subscribeToReports();
}

// Host profiles. A phone's stack cannot be installed here, but the part that
// decides how pairing is negotiated — IO capability, whether MITM protection
// is demanded, whether Secure Connections is used, whether keys are kept — is
// exactly what these set, so the board can be put through each without a phone.
void applyProfile(const String &name) {
  profileName = name;
  if (name == "apple") {
    // iOS presents as DisplayYesNo and asks for MITM protection. Against a
    // board with no input and no output the result is still Just Works, which
    // is the case worth proving: a host may ask for more than the board can
    // give and must not be left hanging.
    NimBLEDevice::setSecurityAuth(true, true, true);
    NimBLEDevice::setSecurityIOCap(BLE_HS_IO_DISPLAY_YESNO);
  } else if (name == "legacy") {
    NimBLEDevice::setSecurityAuth(true, false, false);   // no Secure Connections
    NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);
  } else if (name == "nobond") {
    NimBLEDevice::setSecurityAuth(false, false, true);   // encrypt, keep nothing
    NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);
  } else if (name == "keyboard") {
    NimBLEDevice::setSecurityAuth(true, true, true);     // expects to type a passkey
    NimBLEDevice::setSecurityIOCap(BLE_HS_IO_KEYBOARD_ONLY);
  } else {
    profileName = "android";
    NimBLEDevice::setSecurityAuth(true, false, true);
    NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);
  }
}

void setup() {
  Serial.begin(115200);
  NimBLEDevice::init("EWP test central");
  applyProfile("android");
  auto scan = NimBLEDevice::getScan();
  scan->setScanCallbacks(&scanCallbacks, false);
  scan->setActiveScan(true);
  scan->start(0, false);
  Serial.println("{\"role\":\"test-central\",\"event\":\"ready\"}");
}

void loop() {
  static String line;
  while (Serial.available()) {
    char c = Serial.read();
    if (c != '\n') { if (line.length() < 256) line += c; continue; }
    JsonDocument request;
    if (!deserializeJson(request, line)) {
      String method = request["method"] | "";
      if (method == "status") report();
      else if (method == "profile") {
        applyProfile(request["name"] | "android");
        lastEvent = String("profile ") + profileName; report();
      }
      else if (method == "connect") { attempt(false); report(); }
      else if (method == "probe") { attempt(true); report(); }
      else if (method == "reports") {
        reportsSeen = 0; lastReport = "";
        for (int i = 0; i < RECENT; ++i) recent[i] = "";
        recentNext = 0; report();
      }
      else if (method == "forget") {
        if (held) { NimBLEDevice::deleteClient(held); held = nullptr; }
        NimBLEDevice::deleteAllBonds(); lastEvent = "bonds cleared"; report();
      } else if (method == "rescan") {
        if (target) { delete target; target = nullptr; }
        NimBLEDevice::getScan()->start(0, false); lastEvent = "scanning"; report();
      } else Serial.println("{\"error\":\"unknown\"}");
    }
    line = "";
  }
}

#include <Arduino.h>
#include <ArduinoJson.h>
#include <NimBLEDevice.h>

// Stands in for a phone. It scans for the EWP service, connects, lets the
// keyboard drive security, and reports what happened over USB as JSON so a
// test can read it without a person watching a screen.
static const NimBLEUUID SERVICE("e7a00001-7c3d-4d21-a19a-455750000001");

String lastEvent = "idle";
int connections = 0, bonds = 0, failures = 0;
volatile bool encrypted = false;
NimBLEAdvertisedDevice *target = nullptr;

class ClientCallbacks : public NimBLEClientCallbacks {
  void onConnect(NimBLEClient *client) override {
    ++connections; lastEvent = "connected";
    // The keyboard asks for security itself; this mirrors a phone that
    // accepts rather than one that demands.
    client->secureConnection();
  }
  void onDisconnect(NimBLEClient *client, int reason) override {
    encrypted = false;
    lastEvent = String("disconnected reason=") + reason;
  }
  void onAuthenticationComplete(NimBLEConnInfo &info) override {
    encrypted = info.isEncrypted();
    if (info.isEncrypted()) { ++bonds; lastEvent = "encrypted"; }
    else { ++failures; lastEvent = "encryption failed"; }
  }
} clientCallbacks;

class ScanCallbacks : public NimBLEScanCallbacks {
  void onResult(const NimBLEAdvertisedDevice *device) override {
    if (!device->isAdvertisingService(SERVICE) || target) return;
    target = new NimBLEAdvertisedDevice(*device);
    NimBLEDevice::getScan()->stop();
    lastEvent = String("found ") + device->getName().c_str();
  }
} scanCallbacks;

void report() {
  JsonDocument doc;
  doc["role"] = "test-central";
  doc["event"] = lastEvent;
  doc["connections"] = connections;
  doc["bonds"] = bonds;
  doc["failures"] = failures;
  doc["encrypted"] = encrypted;
  doc["bonded_peers"] = NimBLEDevice::getNumBonds();
  doc["target"] = target ? target->getAddress().toString().c_str() : "";
  serializeJson(doc, Serial); Serial.println();
}

void attempt() {
  if (!target) { lastEvent = "no target yet"; return; }
  auto client = NimBLEDevice::createClient();
  client->setClientCallbacks(&clientCallbacks, false);
  if (!client->connect(target)) { ++failures; lastEvent = "connect refused"; }
  else {
    // Give security time to complete before judging it.
    for (int i = 0; i < 40 && !encrypted; ++i) delay(100);
    lastEvent = encrypted ? "bonded" : "connected but never encrypted";
  }
  NimBLEDevice::deleteClient(client);
}

void setup() {
  Serial.begin(115200);
  NimBLEDevice::init("EWP test central");
  NimBLEDevice::setSecurityAuth(true, false, true);
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);
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
      else if (method == "connect") { attempt(); report(); }
      else if (method == "forget") {
        NimBLEDevice::deleteAllBonds(); bonds = 0; lastEvent = "bonds cleared"; report();
      } else if (method == "rescan") {
        if (target) { delete target; target = nullptr; }
        NimBLEDevice::getScan()->start(0, false); lastEvent = "scanning"; report();
      } else { Serial.println("{\"error\":\"unknown\"}"); }
    }
    line = "";
  }
}

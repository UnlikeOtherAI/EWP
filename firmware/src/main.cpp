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
constexpr char STATUS[] = "e7a00003-7c3d-4d21-a19a-455750000001";
struct Configuration { char ssid[33]; char password[65]; char token[65]; };
QueueHandle_t configurationQueue;
Preferences preferences;
WebServer http(80);
NimBLECharacteristic *keyboard, *mouse, *statusCharacteristic;
String deviceId, token, setupStatus = "ready";
uint32_t passkey;
uint32_t provisionUntil;
bool mdnsStarted = false;
portMUX_TYPE hidMux = portMUX_INITIALIZER_UNLOCKED;
uint16_t hidHandle = BLE_HS_CONN_HANDLE_NONE;

void setHid(uint16_t handle) {
  portENTER_CRITICAL(&hidMux); hidHandle = handle; portEXIT_CRITICAL(&hidMux);
}
uint16_t getHid() {
  portENTER_CRITICAL(&hidMux); auto handle = hidHandle; portEXIT_CRITICAL(&hidMux); return handle;
}

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer *server, NimBLEConnInfo &info) override {
    server->updateConnParams(info.getConnHandle(), 12, 24, 0, 200);
    NimBLEDevice::startAdvertising();
  }
  void onDisconnect(NimBLEServer *, NimBLEConnInfo &info, int) override {
    if (getHid() == info.getConnHandle()) setHid(BLE_HS_CONN_HANDLE_NONE);
    NimBLEDevice::startAdvertising();
  }
  uint32_t onPassKeyDisplay() override { return passkey; }
  void onAuthenticationComplete(NimBLEConnInfo &info) override {
    if (!info.isEncrypted() || !info.isAuthenticated())
      NimBLEDevice::getServer()->disconnect(info.getConnHandle());
  }
} serverCallbacks;

class ReportCallbacks : public NimBLECharacteristicCallbacks {
  void onSubscribe(NimBLECharacteristic *, NimBLEConnInfo &info, uint16_t value) override {
    if (value && info.isEncrypted() && info.isAuthenticated()) {
      uint16_t current = getHid();
      // Never broadcast input to every subscribed peer. One explicit host only.
      if (current == BLE_HS_CONN_HANDLE_NONE || current == info.getConnHandle()) setHid(info.getConnHandle());
      else NimBLEDevice::getServer()->disconnect(info.getConnHandle());
    }
  }
} reportCallbacks;

class ProvisionCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *characteristic, NimBLEConnInfo &info) override {
    if (!info.isAuthenticated() || !info.isEncrypted() || millis() > provisionUntil) return;
    JsonDocument doc;
    auto value = characteristic->getValue();
    // Drop sensitive data from the readable characteristic immediately.
    characteristic->setValue("");
    if (value.size() > 512 || deserializeJson(doc, value.c_str(), value.size())) return;
    String ssid = doc["ssid"] | "", password = doc["password"] | "", secret = doc["token"] | "";
    if (ssid.length() < 1 || ssid.length() > 32 || password.length() > 64 || secret.length() != 64) return;
    for (auto c : secret) if (!isxdigit(c) || isupper(c)) return;
    Configuration config{};
    strlcpy(config.ssid, ssid.c_str(), sizeof(config.ssid));
    strlcpy(config.password, password.c_str(), sizeof(config.password));
    strlcpy(config.token, secret.c_str(), sizeof(config.token));
    xQueueOverwrite(configurationQueue, &config);
  }
} provisionCallbacks;

void jsonReply(int code, JsonDocument &doc) {
  String output; serializeJson(doc, output); http.send(code, "application/json", output);
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
bool parseInput(JsonDocument &doc) {
  if (!authorized()) return false;
  if (http.arg("plain").length() > 256 || deserializeJson(doc, http.arg("plain"))) {
    http.send(400, "application/json", "{\"error\":\"Invalid input\"}"); return false;
  }
  if (getHid() == BLE_HS_CONN_HANDLE_NONE) {
    http.send(409, "application/json", "{\"error\":\"No paired HID host subscribed\"}"); return false;
  }
  return true;
}
void notificationResult(bool sent, bool released) {
  http.send(sent && released ? 200 : 503, "application/json",
    sent && released ? "{\"notified\":true,\"host_action_verified\":false}" : "{\"error\":\"HID notification failed\"}");
}
void setupHttp() {
  const char *headers[] = {"Authorization", "Origin"}; http.collectHeaders(headers, 2);
  http.on("/status", HTTP_GET, [] {
    if (!authorized()) return;
    JsonDocument doc; doc["id"] = deviceId; doc["firmware"] = "0.1.0";
    doc["hid_connected"] = getHid() != BLE_HS_CONN_HANDLE_NONE;
    doc["host_switching"] = false; jsonReply(200, doc);
  });
  http.on("/key", HTTP_POST, [] {
    JsonDocument doc; if (!parseInput(doc)) return;
    if (!doc["usage"].is<int>() || !doc["modifiers"].is<int>()) {
      http.send(400, "application/json", "{\"error\":\"Expected integer usage and modifiers\"}"); return;
    }
    int usage = doc["usage"], modifiers = doc["modifiers"];
    if (usage < 4 || usage > 101 || modifiers < 0 || modifiers > 255) {
      http.send(400, "application/json", "{\"error\":\"Out of range\"}"); return;
    }
    uint16_t target = getHid();
    uint8_t report[8] = {static_cast<uint8_t>(modifiers), 0, static_cast<uint8_t>(usage), 0,0,0,0,0};
    bool sent = keyboard->notify(report, sizeof(report), target); delay(20);
    memset(report, 0, sizeof(report)); bool released = keyboard->notify(report, sizeof(report), target);
    notificationResult(sent, released);
  });
  http.on("/pointer", HTTP_POST, [] {
    JsonDocument doc; if (!parseInput(doc)) return;
    for (const char *key : {"dx", "dy", "wheel"}) {
      if (!doc[key].is<int>() || doc[key].as<int>() < -127 || doc[key].as<int>() > 127) {
        http.send(400, "application/json", "{\"error\":\"Invalid delta\"}"); return;
      }
    }
    if (!doc["click"].is<bool>()) { http.send(400, "application/json", "{\"error\":\"Invalid click\"}"); return; }
    uint16_t target = getHid();
    uint8_t report[] = {static_cast<uint8_t>(doc["click"].as<bool>() ? 1 : 0),
      static_cast<uint8_t>(doc["dx"].as<int>()), static_cast<uint8_t>(doc["dy"].as<int>()),
      static_cast<uint8_t>(doc["wheel"].as<int>())};
    bool sent = mouse->notify(report, sizeof(report), target); delay(20);
    memset(report, 0, sizeof(report)); bool released = mouse->notify(report, sizeof(report), target);
    notificationResult(sent, released);
  });
  http.onNotFound([] { http.send(404, "application/json", "{\"error\":\"Not found\"}"); });
  http.begin();
}

void setup() {
  Serial.begin(115200);
  preferences.begin("ewp", false);
  deviceId = "ewp-" + String(static_cast<uint32_t>(ESP.getEfuseMac()), HEX);
  passkey = preferences.getUInt("passkey", 0);
  if (!passkey) { passkey = 100000 + esp_random() % 900000; preferences.putUInt("passkey", passkey); }
  // Pairing code is physical setup data; never print Wi-Fi credentials or bridge tokens.
  Serial.printf("\nEWP %s\nBluetooth pairing code: %06u\n", deviceId.c_str(), passkey);
  provisionUntil = millis() + 300000;
  configurationQueue = xQueueCreate(1, sizeof(Configuration));
  WiFi.mode(WIFI_STA); WiFi.setAutoReconnect(true);
  token = preferences.getString("token", "");
  String ssid = preferences.getString("ssid", "");
  if (!ssid.isEmpty()) WiFi.begin(ssid.c_str(), preferences.getString("password", "").c_str());
  NimBLEDevice::init(deviceId.c_str());
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
  statusCharacteristic = service->createCharacteristic(STATUS, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
  statusCharacteristic->setValue("{\"state\":\"ready\"}");
  server->start();
  auto advertising = NimBLEDevice::getAdvertising();
  advertising->setAppearance(0x03C1); advertising->setName(deviceId.c_str());
  advertising->addServiceUUID(SERVICE); advertising->addServiceUUID(NimBLEUUID((uint16_t)0x1812)); advertising->enableScanResponse(true); advertising->start();
  setupHttp();
}

void loop() {
  Configuration config;
  if (xQueueReceive(configurationQueue, &config, 0) == pdTRUE) {
    preferences.putString("ssid", config.ssid); preferences.putString("password", config.password);
    preferences.putString("token", config.token); token = config.token;
    WiFi.disconnect(); WiFi.begin(config.ssid, config.password);
    memset(&config, 0, sizeof(config)); setupStatus = "joining";
  }
  if (WiFi.status() == WL_CONNECTED && !mdnsStarted) {
    mdnsStarted = MDNS.begin(deviceId.c_str());
    if (mdnsStarted) { MDNS.addService("ewp", "tcp", 80); MDNS.addServiceTxt("ewp", "tcp", "id", deviceId); }
    Serial.printf("Wi-Fi connected, address: %s\n", WiFi.localIP().toString().c_str());
  }
  if (WiFi.status() != WL_CONNECTED && mdnsStarted) { MDNS.end(); mdnsStarted = false; }
  static uint32_t lastStatus = 0;
  if (millis() - lastStatus > 1000) {
    JsonDocument doc; doc["id"] = deviceId;
    doc["state"] = WiFi.status() == WL_CONNECTED ? "connected" : setupStatus;
    doc["ip"] = WiFi.status() == WL_CONNECTED ? WiFi.localIP().toString() : "";
    doc["setup_open"] = millis() <= provisionUntil;
    String output; serializeJson(doc, output); statusCharacteristic->setValue(output.c_str());
    statusCharacteristic->notify(); lastStatus = millis();
  }
  http.handleClient(); delay(2);
}

#include <Arduino.h>
#include <NimBLEDevice.h>
#include <Preferences.h>
#include <PubSubClient.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <mbedtls/base64.h>
#include <memory>

// SE H2D Timelapse Bridge v1.6.1
//
// H2D --Wi-Fi/MQTT TLS--> ESP32 --Bluetooth LE--> iPhone SE app
//
// The ESP32 never controls motion or temperature. It only reads print status,
// converts a completed-layer transition to one SNAP event, and reports FINISH.
// Credentials are entered once in the SE app and stored in ESP32 Preferences.

namespace Config {
constexpr char DEVICE_NAME[] = "SE-H2D-Timelapse";
constexpr char SERVICE_UUID[] = "7E57A000-8E3A-4D6A-9B2B-13B10A000001";
constexpr char EVENT_UUID[] = "7E57A001-8E3A-4D6A-9B2B-13B10A000001";
constexpr char COMMAND_UUID[] = "7E57A002-8E3A-4D6A-9B2B-13B10A000001";

constexpr uint16_t MQTT_PORT = 8883;
// H2D full-state packets can exceed 32 KB, especially when AMS data and HMS
// warnings are present. PubSubClient silently drops packets larger than this
// buffer, which used to hide printer alerts from the iPhone.
constexpr uint16_t MQTT_BUFFER_BYTES = 40960;
constexpr uint32_t WIFI_RETRY_MS = 12000;
constexpr uint32_t MQTT_RETRY_MS = 10000;
constexpr uint32_t STATUS_PERIOD_MS = 2000;
constexpr uint32_t DATA_TIMEOUT_MS = 45000;
constexpr uint32_t BLE_NOTIFY_GAP_MS = 22;
constexpr uint8_t EVENT_QUEUE_SIZE = 24;
constexpr size_t EVENT_LENGTH = 150;
constexpr uint8_t STATUS_LED_PIN = 25;
}  // namespace Config

struct BridgeSettings {
  String wifiSsid;
  String wifiPassword;
  String printerIp;
  String printerSerial;
  String accessCode;

  bool complete() const {
    IPAddress address;
    return !wifiSsid.isEmpty() && !wifiPassword.isEmpty() &&
           address.fromString(printerIp) && !printerSerial.isEmpty() &&
           !accessCode.isEmpty();
  }
};

Preferences preferences;
BridgeSettings settings;
BridgeSettings pendingSettings;
WiFiClientSecure tlsClient;
PubSubClient mqtt(tlsClient);
NimBLECharacteristic *eventCharacteristic = nullptr;

portMUX_TYPE eventMux = portMUX_INITIALIZER_UNLOCKED;
char eventQueue[Config::EVENT_QUEUE_SIZE][Config::EVENT_LENGTH];
uint8_t eventHead = 0;
uint8_t eventTail = 0;

volatile bool phoneConnected = false;
bool timelapseArmed = false;
bool mqttWasConnected = false;
bool statusDataSeen = false;
bool finishSent = false;
bool printWasRunning = false;
bool hmsAlertActive = false;
bool printErrorActive = false;
bool lastReportedPrinterAlert = false;
uint32_t printErrorCode = 0;
uint32_t lastReportedPrintErrorCode = 0;
String printState = "IDLE";
String activeJob = "0";
int currentLayer = 0;
int totalLayers = 0;
int printPercent = 0;
// Bambu print.stg_cur: 0 means real layer printing, >0 is a preparation or
// maintenance stage, and -1/255 means idle or unavailable.
int currentStage = -1;
int lastObservedLayer = 0;
int lastSnapLayer = 0;
uint32_t lastWifiAttemptAt = 0;
uint32_t lastMqttAttemptAt = 0;
uint32_t lastStatusNotifyAt = 0;
uint32_t lastMqttMessageAt = 0;
uint32_t lastBleNotifyAt = 0;
uint32_t sequenceId = 0;

void queuePhoneEvent(const String &event) {
  portENTER_CRITICAL(&eventMux);
  const uint8_t next = (eventHead + 1) % Config::EVENT_QUEUE_SIZE;
  if (next == eventTail) eventTail = (eventTail + 1) % Config::EVENT_QUEUE_SIZE;
  strlcpy(eventQueue[eventHead], event.c_str(), Config::EVENT_LENGTH);
  eventHead = next;
  portEXIT_CRITICAL(&eventMux);
}

void flushPhoneEvents() {
  if (!phoneConnected || eventCharacteristic == nullptr) return;
  const uint32_t now = millis();
  if (now - lastBleNotifyAt < Config::BLE_NOTIFY_GAP_MS) return;

  char event[Config::EVENT_LENGTH];
  bool hasEvent = false;
  portENTER_CRITICAL(&eventMux);
  if (eventTail != eventHead) {
    strlcpy(event, eventQueue[eventTail], sizeof(event));
    eventTail = (eventTail + 1) % Config::EVENT_QUEUE_SIZE;
    hasEvent = true;
  }
  portEXIT_CRITICAL(&eventMux);
  if (!hasEvent) return;
  eventCharacteristic->setValue(event);
  eventCharacteristic->notify();
  lastBleNotifyAt = now;
}

void reportStatus(const char *status) {
  queuePhoneEvent(String("H2D,STATUS,") + status);
}

void reportPrintStatus(bool force = false) {
  const uint32_t now = millis();
  if (!force && now - lastStatusNotifyAt < Config::STATUS_PERIOD_MS) return;
  lastStatusNotifyAt = now;
  queuePhoneEvent(String("H2D,PRINT,") + printState + "," + currentLayer +
                  "," + totalLayers + "," + printPercent + "," + currentStage);
}

String decodeBase64(const String &encoded) {
  if (encoded.isEmpty()) return "";
  const size_t capacity = encoded.length() * 3 / 4 + 4;
  std::unique_ptr<unsigned char[]> output(new unsigned char[capacity + 1]);
  size_t outputLength = 0;
  const int result = mbedtls_base64_decode(
      output.get(), capacity, &outputLength,
      reinterpret_cast<const unsigned char *>(encoded.c_str()),
      encoded.length());
  if (result != 0) return "";
  output[outputLength] = '\0';
  return String(reinterpret_cast<char *>(output.get()));
}

void loadSettings() {
  preferences.begin("se-h2d-tl", false);
  settings.wifiSsid = preferences.getString("ssid", "");
  settings.wifiPassword = preferences.getString("wifiPass", "");
  settings.printerIp = preferences.getString("printerIp", "");
  settings.printerSerial = preferences.getString("serial", "");
  settings.accessCode = preferences.getString("access", "");
  pendingSettings = settings;
}

bool savePendingSettings() {
  if (!pendingSettings.complete()) return false;
  settings = pendingSettings;
  preferences.putString("ssid", settings.wifiSsid);
  preferences.putString("wifiPass", settings.wifiPassword);
  preferences.putString("printerIp", settings.printerIp);
  preferences.putString("serial", settings.printerSerial);
  preferences.putString("access", settings.accessCode);
  return true;
}

bool findKey(const uint8_t *payload, size_t length, const char *key,
             size_t start, size_t &valuePosition) {
  String pattern = String('"') + key + '"';
  const size_t patternLength = pattern.length();
  if (length < patternLength || start >= length) return false;
  for (size_t i = start; i + patternLength < length; ++i) {
    if (memcmp(payload + i, pattern.c_str(), patternLength) != 0) continue;
    size_t cursor = i + patternLength;
    while (cursor < length && payload[cursor] != ':') ++cursor;
    if (cursor >= length) return false;
    valuePosition = cursor + 1;
    return true;
  }
  return false;
}

bool extractLastJsonInt(const uint8_t *payload, size_t length, const char *key,
                        int &output) {
  bool found = false;
  size_t searchFrom = 0;
  size_t valuePosition = 0;
  while (findKey(payload, length, key, searchFrom, valuePosition)) {
    size_t cursor = valuePosition;
    while (cursor < length &&
           (payload[cursor] == ' ' || payload[cursor] == '\t' ||
            payload[cursor] == '"')) {
      ++cursor;
    }
    bool negative = false;
    if (cursor < length && payload[cursor] == '-') {
      negative = true;
      ++cursor;
    }
    long value = 0;
    bool hasDigit = false;
    while (cursor < length && payload[cursor] >= '0' && payload[cursor] <= '9') {
      value = value * 10 + (payload[cursor] - '0');
      hasDigit = true;
      ++cursor;
    }
    if (hasDigit) {
      output = negative ? -value : value;
      found = true;
    }
    searchFrom = valuePosition;
  }
  return found;
}

bool extractLastJsonUInt32(const uint8_t *payload, size_t length,
                           const char *key, uint32_t &output) {
  bool found = false;
  size_t searchFrom = 0;
  size_t valuePosition = 0;
  while (findKey(payload, length, key, searchFrom, valuePosition)) {
    size_t cursor = valuePosition;
    while (cursor < length &&
           (payload[cursor] == ' ' || payload[cursor] == '\t' ||
            payload[cursor] == '"')) {
      ++cursor;
    }
    uint64_t value = 0;
    bool hasDigit = false;
    while (cursor < length && payload[cursor] >= '0' && payload[cursor] <= '9') {
      value = value * 10 + (payload[cursor] - '0');
      hasDigit = true;
      ++cursor;
    }
    if (hasDigit) {
      output = value > 0xFFFFFFFFULL ? 0xFFFFFFFFUL
                                     : static_cast<uint32_t>(value);
      found = true;
    }
    searchFrom = valuePosition;
  }
  return found;
}

bool extractJsonString(const uint8_t *payload, size_t length, const char *key,
                       String &output) {
  size_t valuePosition = 0;
  if (!findKey(payload, length, key, 0, valuePosition)) return false;
  size_t cursor = valuePosition;
  while (cursor < length && payload[cursor] != '"') ++cursor;
  if (cursor >= length) return false;
  ++cursor;
  output = "";
  while (cursor < length && payload[cursor] != '"') {
    if (payload[cursor] == '\\' && cursor + 1 < length) ++cursor;
    if (output.length() < 64) output += static_cast<char>(payload[cursor]);
    ++cursor;
  }
  return cursor < length;
}

bool extractJsonArrayHasItems(const uint8_t *payload, size_t length,
                              const char *key, bool &hasItems) {
  size_t valuePosition = 0;
  if (!findKey(payload, length, key, 0, valuePosition)) return false;
  size_t cursor = valuePosition;
  while (cursor < length &&
         (payload[cursor] == ' ' || payload[cursor] == '\t' ||
          payload[cursor] == '\r' || payload[cursor] == '\n')) {
    ++cursor;
  }
  if (cursor >= length || payload[cursor] != '[') return false;
  ++cursor;
  while (cursor < length &&
         (payload[cursor] == ' ' || payload[cursor] == '\t' ||
          payload[cursor] == '\r' || payload[cursor] == '\n')) {
    ++cursor;
  }
  hasItems = cursor < length && payload[cursor] != ']';
  return true;
}

void reportPrinterAlert(bool force = false) {
  // H2D keeps acknowledged/old HMS entries in some full-state packets even
  // while the printer is idle. Only surface them during a real print session;
  // a stopped/failed job must return the phone to its waiting state.
  const bool printContext =
      printState == "RUNNING" || printState == "PREPARE" ||
      printState == "PREPARING" || printState == "PAUSE" ||
      printState == "PAUSED" || printState == "SLICING" ||
      printState == "INIT" || printState == "HEATING";
  const bool active = printContext && (hmsAlertActive || printErrorActive);
  if (!force && active == lastReportedPrinterAlert &&
      printErrorCode == lastReportedPrintErrorCode) {
    return;
  }
  if (active) {
    if (printErrorActive) {
      char errorCode[11];
      snprintf(errorCode, sizeof(errorCode), "0x%08lX",
               static_cast<unsigned long>(printErrorCode));
      queuePhoneEvent(String("H2D,ALERT,1,H2D báo lỗi máy in • mã ") +
                      errorCode + " • xem màn hình H2D");
    } else {
      queuePhoneEvent("H2D,ALERT,1,H2D có cảnh báo HMS • xem màn hình máy in");
    }
  } else {
    queuePhoneEvent("H2D,ALERT,0,CLEAR");
  }
  lastReportedPrinterAlert = active;
  lastReportedPrintErrorCode = printErrorCode;
}

uint32_t hashJobToken(const String &value) {
  uint32_t hash = 2166136261u;
  for (size_t i = 0; i < value.length(); ++i) {
    hash ^= static_cast<uint8_t>(value[i]);
    hash *= 16777619u;
  }
  return hash;
}

String safeJobID(const String &source) {
  if (source.isEmpty() || source == "0") return "0";
  char token[12];
  snprintf(token, sizeof(token), "%08lX",
           static_cast<unsigned long>(hashJobToken(source)));
  return String(token);
}

void sendSnapshot(int layer) {
  if (!timelapseArmed || layer <= 0 || layer <= lastSnapLayer) return;
  lastSnapLayer = layer;
  queuePhoneEvent(String("H2D,SNAP,") + layer + "," +
                  max(layer, totalLayers) + "," + activeJob);
  Serial.printf("[SNAP] completed layer %d/%d\n", layer, totalLayers);
}

void resetForNewPrint(const String &job, int layer) {
  activeJob = job;
  currentLayer = max(0, layer);
  lastObservedLayer = currentLayer;
  lastSnapLayer = 0;
  finishSent = false;
  printWasRunning = true;
  Serial.printf("[PRINT] new job %s, starting observation at layer %d\n",
                activeJob.c_str(), currentLayer);
}

void processPrintUpdate(const String &newState, int newLayer, int newTotal,
                        int newPercent, int newStage,
                        const String &jobToken) {
  const String previousState = printState;
  const bool wasRunning = printWasRunning;
  if (!newState.isEmpty()) {
    printState = newState;
    printState.toUpperCase();
  }
  if (newLayer >= 0) currentLayer = newLayer;
  if (newTotal >= 0) totalLayers = newTotal;
  if (newPercent >= 0) printPercent = constrain(newPercent, 0, 100);
  if (newStage != -999) currentStage = newStage;

  // PREPARE may already report layer 0/1 while the bed is heating. Baseline
  // only on the first real RUNNING packet, otherwise layer 1 is photographed
  // before it has actually finished.
  const bool stateRunning = printState == "RUNNING";
  const bool actualLayerPrinting =
      stateRunning && (currentStage == 0 || currentStage == -1);
  if (actualLayerPrinting) {
    if (!wasRunning || (jobToken != "0" && jobToken != activeJob)) {
      resetForNewPrint(jobToken, currentLayer);
    } else if (currentLayer > lastObservedLayer) {
      // When H2D announces layer N, layer N-1 has completed. This avoids taking
      // a picture while the reported layer is still being printed.
      sendSnapshot(max(1, currentLayer - 1));
      lastObservedLayer = currentLayer;
    }
    printWasRunning = true;
  }

  if (printState == "FINISH" && (wasRunning || previousState == "RUNNING") &&
      !finishSent) {
    const int finalLayer = max(max(currentLayer, totalLayers), lastObservedLayer);
    sendSnapshot(finalLayer);
    queuePhoneEvent(String("H2D,DONE,") + finalLayer + "," +
                    max(finalLayer, totalLayers) + "," + activeJob);
    finishSent = true;
    printWasRunning = false;
    Serial.printf("[PRINT] finished at layer %d\n", finalLayer);
  } else if (printState == "FAILED" || printState == "ERROR" ||
             printState == "IDLE" || printState == "STOP" ||
             printState == "STOPPED" || printState == "CANCELED" ||
             printState == "CANCELLED" || printState == "FINISH" ||
             printState == "COMPLETE" || printState == "COMPLETED") {
    printWasRunning = false;
  }
  reportPrintStatus(true);
}

void onMqttMessage(char *topic, uint8_t *payload, unsigned int length) {
  lastMqttMessageAt = millis();
  int layer = -1;
  int total = -1;
  int percent = -1;
  int stage = -999;
  uint32_t incomingPrintError = 0;
  bool incomingHmsAlert = false;
  String state;
  String job;
  const bool hasLayer = extractLastJsonInt(payload, length, "layer_num", layer);
  const bool hasTotal =
      extractLastJsonInt(payload, length, "total_layer_num", total);
  const bool hasPercent = extractLastJsonInt(payload, length, "mc_percent", percent);
  const bool hasStage = extractLastJsonInt(payload, length, "stg_cur", stage);
  const bool hasPrintError =
      extractLastJsonUInt32(payload, length, "print_error", incomingPrintError);
  const bool hasHms =
      extractJsonArrayHasItems(payload, length, "hms", incomingHmsAlert);
  const bool hasState = extractJsonString(payload, length, "gcode_state", state);
  bool hasJob = extractJsonString(payload, length, "job_id", job);
  if (!hasJob) hasJob = extractJsonString(payload, length, "subtask_id", job);

  if (hasLayer || hasTotal || hasPercent || hasStage || hasState ||
      hasPrintError || hasHms) {
    statusDataSeen = true;
  }
  if (hasLayer || hasTotal || hasPercent || hasStage || hasState) {
    processPrintUpdate(hasState ? state : "", hasLayer ? layer : -1,
                       hasTotal ? total : -1, hasPercent ? percent : -1,
                       hasStage ? stage : -999,
                       hasJob ? safeJobID(job) : activeJob);
  }
  if (hasPrintError) {
    printErrorCode = incomingPrintError;
    printErrorActive = incomingPrintError != 0;
  }
  if (hasHms) hmsAlertActive = incomingHmsAlert;
  // A state transition to IDLE must clear a previously active warning even
  // when that incremental packet does not contain hms/print_error fields.
  if (hasPrintError || hasHms || hasState) reportPrinterAlert();
}

void publishStatusRequest() {
  if (!mqtt.connected()) return;
  const String topic = "device/" + settings.printerSerial + "/request";
  const String pushAll = String("{\"pushing\":{\"sequence_id\":\"") +
                         ++sequenceId +
                         "\",\"command\":\"pushall\",\"version\":1,"
                         "\"push_target\":1}}";
  mqtt.publish(topic.c_str(), pushAll.c_str());
}

void disconnectNetwork() {
  if (mqtt.connected()) mqtt.disconnect();
  WiFi.disconnect(false, false);
  mqttWasConnected = false;
  statusDataSeen = false;
  lastWifiAttemptAt = 0;
  lastMqttAttemptAt = 0;
}

void maintainWiFi() {
  if (!settings.complete()) return;
  if (WiFi.status() == WL_CONNECTED) return;
  const uint32_t now = millis();
  if (now - lastWifiAttemptAt < Config::WIFI_RETRY_MS) return;
  lastWifiAttemptAt = now;
  reportStatus("WIFI_CONNECTING");
  Serial.printf("[WIFI] connecting to configured SSID (%u chars)\n",
                static_cast<unsigned>(settings.wifiSsid.length()));
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  WiFi.begin(settings.wifiSsid.c_str(), settings.wifiPassword.c_str());
}

void maintainMqtt() {
  if (!settings.complete() || WiFi.status() != WL_CONNECTED) return;
  if (mqtt.connected()) {
    if (!mqttWasConnected) {
      mqttWasConnected = true;
      reportStatus("READY");
      publishStatusRequest();
    }
    if (!statusDataSeen && lastMqttMessageAt > 0 &&
        millis() - lastMqttMessageAt > Config::DATA_TIMEOUT_MS) {
      queuePhoneEvent("H2D,ERROR,H2D không trả dữ liệu • bật LAN Only và Developer Mode");
      lastMqttMessageAt = millis();
    }
    return;
  }

  if (mqttWasConnected) {
    Serial.printf("[MQTT] disconnected, state=%d; reconnecting\n", mqtt.state());
  }
  mqttWasConnected = false;
  const uint32_t now = millis();
  if (now - lastMqttAttemptAt < Config::MQTT_RETRY_MS) return;
  lastMqttAttemptAt = now;
  reportStatus("MQTT_CONNECTING");
  const uint64_t chip = ESP.getEfuseMac();
  char clientId[32];
  snprintf(clientId, sizeof(clientId), "SE-H2D-%08lX",
           static_cast<unsigned long>(chip & 0xFFFFFFFF));
  Serial.printf("[MQTT] connecting %s -> %s:%u, RSSI=%d, heap=%u, max=%u\n",
                WiFi.localIP().toString().c_str(), settings.printerIp.c_str(),
                Config::MQTT_PORT, WiFi.RSSI(), ESP.getFreeHeap(),
                ESP.getMaxAllocHeap());
  if (!mqtt.connect(clientId, "bblp", settings.accessCode.c_str())) {
    char tlsError[96] = {};
    const int tlsCode = tlsClient.lastError(tlsError, sizeof(tlsError));
    Serial.printf("[MQTT] connection failed, state=%d, TLS=%d (%s), heap=%u\n",
                  mqtt.state(), tlsCode, tlsError, ESP.getFreeHeap());
    return;
  }
  const String reportTopic = "device/" + settings.printerSerial + "/report";
  mqtt.subscribe(reportTopic.c_str(), 0);
  lastMqttMessageAt = millis();
  statusDataSeen = false;
  Serial.println("[MQTT] connected and subscribed to H2D report topic");
}

void sendCurrentStatus() {
  queuePhoneEvent("H2D,ESP32,SE_H2D_BRIDGE,1.6.1");
  if (!settings.complete()) {
    reportStatus("CONFIG_REQUIRED");
  } else if (WiFi.status() != WL_CONNECTED) {
    reportStatus("WIFI_CONNECTING");
  } else if (!mqtt.connected()) {
    reportStatus("MQTT_CONNECTING");
  } else {
    reportStatus(timelapseArmed ? "ARMED" : "READY");
    reportPrintStatus(true);
    reportPrinterAlert(true);
  }
}

void handlePhoneCommand(String command) {
  command.trim();
  const int comma = command.indexOf(',');
  const String head = comma < 0 ? command : command.substring(0, comma);
  const String argument = comma < 0 ? "" : command.substring(comma + 1);

  if (head == "H2D_WIFI_SSID") {
    pendingSettings.wifiSsid = decodeBase64(argument);
    queuePhoneEvent("H2D,CFG_ACK,SSID");
  } else if (head == "H2D_WIFI_PASS") {
    pendingSettings.wifiPassword = decodeBase64(argument);
    queuePhoneEvent("H2D,CFG_ACK,PASS");
  } else if (head == "H2D_IP") {
    pendingSettings.printerIp = argument;
    queuePhoneEvent("H2D,CFG_ACK,IP");
  } else if (head == "H2D_SERIAL") {
    pendingSettings.printerSerial = argument;
    queuePhoneEvent("H2D,CFG_ACK,SERIAL");
  } else if (head == "H2D_CODE") {
    pendingSettings.accessCode = decodeBase64(argument);
    queuePhoneEvent("H2D,CFG_ACK,CODE");
  } else if (head == "H2D_SAVE") {
    if (savePendingSettings()) {
      queuePhoneEvent("H2D,CFG_ACK,SAVE");
      reportStatus("CONFIG_SAVED");
      disconnectNetwork();
    } else {
      queuePhoneEvent("H2D,ERROR,Cấu hình thiếu hoặc IP H2D chưa đúng");
    }
  } else if (head == "H2D_ARM") {
    timelapseArmed = argument == "1";
    if (timelapseArmed) {
      // Arm at the current layer so reconnecting in the middle of a print does
      // not invent frames for layers that the iPhone never observed.
      lastObservedLayer = currentLayer;
      lastSnapLayer = 0;
      finishSent = false;
      reportStatus("ARMED");
    } else {
      reportStatus("DISARMED");
    }
  } else if (head == "H2D_STATUS" || head == "APP_READY" || head == "PING") {
    sendCurrentStatus();
    if (mqtt.connected()) publishStatusRequest();
  } else if (head == "H2D_ACK") {
    // BLE indications are already ordered. ACK is retained for diagnostics and
    // future retry logic; credentials and camera data never travel in this path.
  }
}

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer *server, NimBLEConnInfo &connection) override {
    phoneConnected = true;
    server->updateConnParams(connection.getConnHandle(), 12, 24, 0, 180);
    Serial.println("[BLE] iPhone connected");
  }

  void onDisconnect(NimBLEServer *, NimBLEConnInfo &, int) override {
    phoneConnected = false;
    portENTER_CRITICAL(&eventMux);
    eventHead = eventTail = 0;
    portEXIT_CRITICAL(&eventMux);
    Serial.println("[BLE] iPhone disconnected");
    NimBLEDevice::startAdvertising();
  }
};

class CommandCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *characteristic,
               NimBLEConnInfo &) override {
    const String value = characteristic->getValue().c_str();
    if (!value.isEmpty()) handlePhoneCommand(value);
  }
};

void setupBle() {
  NimBLEDevice::init(Config::DEVICE_NAME);
  NimBLEDevice::setMTU(185);
  NimBLEServer *server = NimBLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  NimBLEService *service = server->createService(Config::SERVICE_UUID);
  eventCharacteristic = service->createCharacteristic(
      Config::EVENT_UUID,
      NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
  eventCharacteristic->setValue("H2D,STATUS,BOOTING");
  NimBLECharacteristic *commandCharacteristic = service->createCharacteristic(
      Config::COMMAND_UUID,
      NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  commandCharacteristic->setCallbacks(new CommandCallbacks());
  service->start();
  NimBLEAdvertising *advertising = NimBLEDevice::getAdvertising();
  advertising->addServiceUUID(Config::SERVICE_UUID);
  advertising->setName(Config::DEVICE_NAME);
  advertising->enableScanResponse(true);
  advertising->start();
}

void updateLed() {
  const uint32_t now = millis();
  bool on = false;
  if (!settings.complete()) {
    on = (now % 1400) < 100;
  } else if (WiFi.status() != WL_CONNECTED || !mqtt.connected()) {
    on = (now % 700) < 110;
  } else if (timelapseArmed) {
    on = (now % 2200) < 1750;
  } else {
    on = true;
  }
  digitalWrite(Config::STATUS_LED_PIN, on ? HIGH : LOW);
}

void setup() {
  Serial.begin(115200);
  delay(250);
  Serial.println("\nSE H2D Timelapse Bridge v1.6.1");
  pinMode(Config::STATUS_LED_PIN, OUTPUT);
  loadSettings();
  setupBle();

  tlsClient.setInsecure();  // H2D uses a per-device/self-signed LAN certificate.
  mqtt.setServer(settings.printerIp.c_str(), Config::MQTT_PORT);
  mqtt.setCallback(onMqttMessage);
  mqtt.setKeepAlive(60);
  mqtt.setSocketTimeout(5);
  if (!mqtt.setBufferSize(Config::MQTT_BUFFER_BYTES)) {
    Serial.printf("[MQTT] failed to allocate %u-byte receive buffer\n",
                  Config::MQTT_BUFFER_BYTES);
    reportStatus("BUFFER_ERROR");
  }
  if (settings.complete()) {
    reportStatus("WIFI_CONNECTING");
  } else {
    reportStatus("CONFIG_REQUIRED");
  }
}

void loop() {
  // setServer is repeated because the IP can be changed from the app at runtime.
  mqtt.setServer(settings.printerIp.c_str(), Config::MQTT_PORT);
  maintainWiFi();
  maintainMqtt();
  if (mqtt.connected()) mqtt.loop();
  reportPrintStatus(false);
  flushPhoneEvents();
  updateLed();
  delay(2);
}

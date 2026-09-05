#include <Arduino.h>
#include <Adafruit_NeoPixel.h>
#include <NimBLEDevice.h>
#include <Preferences.h>
#include <PubSubClient.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <mbedtls/base64.h>
#include <memory>

// SE Bambu Timelapse Bridge for classic ESP32 v1.8.5
//
// Bambu printer --Wi-Fi/MQTT TLS--> ESP32 --Bluetooth LE--> iPhone SE app
//
// The ESP32 never controls motion or temperature. It only reads print status,
// converts a completed-layer transition to one SNAP event, and reports FINISH.
// Credentials are entered once in the SE app and stored in ESP32 Preferences.

namespace Config {
constexpr char DEVICE_NAME[] = "SE-Bambu-Timelapse";
constexpr char SERVICE_UUID[] = "7E57A000-8E3A-4D6A-9B2B-13B10A000001";
constexpr char EVENT_UUID[] = "7E57A001-8E3A-4D6A-9B2B-13B10A000001";
constexpr char COMMAND_UUID[] = "7E57A002-8E3A-4D6A-9B2B-13B10A000001";

constexpr uint16_t MQTT_PORT = 8883;
// Bambu full-state packets can exceed 32 KB, especially when AMS data and HMS
// warnings are present. PubSubClient silently drops packets larger than this
// buffer, which used to hide printer alerts from the iPhone.
constexpr uint16_t MQTT_BUFFER_BYTES = 49152;
constexpr uint32_t WIFI_RETRY_MS = 12000;
constexpr uint32_t MQTT_RETRY_MS = 10000;
constexpr uint32_t STATUS_PERIOD_MS = 2000;
constexpr uint32_t TELEMETRY_PERIOD_MS = 1000;
constexpr uint32_t STATUS_REQUEST_RETRY_MS = 3500;
constexpr uint32_t PRINT_DATA_STALE_MS = 10000;
constexpr uint32_t DATA_TIMEOUT_MS = 45000;
constexpr uint8_t MATERIAL_SYNC_RETRY_LIMIT = 5;
constexpr uint32_t BLE_NOTIFY_GAP_MS = 22;
constexpr uint8_t EVENT_QUEUE_SIZE = 24;
constexpr size_t EVENT_LENGTH = 150;
// External WS2812/NeoPixel strip. DATA -> GPIO4 through a 330-ohm resistor;
// strip 5V/GND uses a separate 5V supply and MUST share GND with ESP32.
// Change only these two values if a different free pin/count is wired.
constexpr uint8_t LED_STRIP_PIN = 4;
constexpr uint16_t LED_STRIP_COUNT = 24;
constexpr uint8_t LED_BRIGHTNESS = 52;
constexpr uint32_t LED_REFRESH_MS = 35;
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
Adafruit_NeoPixel ledStrip(
    Config::LED_STRIP_COUNT, Config::LED_STRIP_PIN, NEO_GRB + NEO_KHZ800);
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
bool lastReportedPrinterAlertCritical = false;
uint32_t printErrorCode = 0;
uint32_t lastReportedPrintErrorCode = 0;
String printState = "IDLE";
String activeJob = "0";
String activeFilamentType = "";
String activeFilamentColor = "";
int activeFilamentSlot = -1;
uint8_t materialSyncRequests = 0;
constexpr uint8_t MATERIAL_CACHE_SLOTS = 17;  // AMS 0...15 + external 16.
String cachedFilamentType[MATERIAL_CACHE_SLOTS];
String cachedFilamentColor[MATERIAL_CACHE_SLOTS];
int nozzleTemperature = -1;
int nozzleTargetTemperature = -1;
int leftNozzleTemperature = -1;
int leftNozzleTargetTemperature = -1;
int bedTemperature = -1;
int bedTargetTemperature = -1;
int partFanPercent = -1;
int auxiliaryFanPercent = -1;
int exhaustFanPercent = -1;
bool telemetryDirty = false;
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
uint32_t lastTelemetryNotifyAt = 0;
uint32_t lastMqttMessageAt = 0;
uint32_t lastPrintDataAt = 0;
uint32_t lastStatusRequestAt = 0;
uint32_t lastBleNotifyAt = 0;
uint32_t sequenceId = 0;
uint32_t captureFlashUntil = 0;
uint32_t lastLedRefreshAt = 0;

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

String printerModelFromSerial(const String &serial) {
  String normalized = serial;
  normalized.trim();
  normalized.toUpperCase();
  if (normalized.startsWith("039") || normalized.startsWith("030")) return "A1";
  if (normalized.startsWith("094")) return "H2D";
  if (normalized.startsWith("22E")) return "P2S";
  return "Bambu";
}

String safeEventField(String value) {
  value.replace(",", " ");
  value.replace("\r", " ");
  value.replace("\n", " ");
  value.trim();
  return value;
}

void reportPrinterIdentity() {
  queuePhoneEvent(String("H2D,PRINTER,") +
                  printerModelFromSerial(settings.printerSerial) + "," +
                  safeEventField(settings.printerSerial));
}

void reportMaterial() {
  queuePhoneEvent(String("H2D,MATERIAL,") +
                  safeEventField(activeFilamentType) + "," +
                  safeEventField(activeFilamentColor) + "," +
                  activeFilamentSlot);
}

void reportTelemetry(bool force = false) {
  const bool hasData = nozzleTemperature >= 0 || nozzleTargetTemperature >= 0 ||
                       leftNozzleTemperature >= 0 ||
                       leftNozzleTargetTemperature >= 0 ||
                       bedTemperature >= 0 || bedTargetTemperature >= 0 ||
                       partFanPercent >= 0 || auxiliaryFanPercent >= 0 ||
                       exhaustFanPercent >= 0;
  if (!hasData) return;
  const uint32_t now = millis();
  if (!force && (!telemetryDirty ||
                 now - lastTelemetryNotifyAt < Config::TELEMETRY_PERIOD_MS)) {
    return;
  }
  lastTelemetryNotifyAt = now;
  telemetryDirty = false;
  queuePhoneEvent(String("H2D,TELEMETRY,") + nozzleTemperature + "," +
                  nozzleTargetTemperature + "," + leftNozzleTemperature + "," +
                  leftNozzleTargetTemperature + "," + bedTemperature + "," +
                  bedTargetTemperature + "," + partFanPercent + "," +
                  auxiliaryFanPercent + "," + exhaustFanPercent);
}

void clearMaterialCache() {
  for (uint8_t i = 0; i < MATERIAL_CACHE_SLOTS; ++i) {
    cachedFilamentType[i] = "";
    cachedFilamentColor[i] = "";
  }
}

void clearActiveMaterial(bool notifyPhone = true) {
  activeFilamentType = "";
  activeFilamentColor = "";
  activeFilamentSlot = -1;
  materialSyncRequests = 0;
  if (notifyPhone) reportMaterial();
}

void clearPhoneEventQueue() {
  portENTER_CRITICAL(&eventMux);
  eventHead = eventTail = 0;
  portEXIT_CRITICAL(&eventMux);
}

void resetPrinterRuntimeForProfileSwitch() {
  statusDataSeen = false;
  finishSent = false;
  printWasRunning = false;
  hmsAlertActive = false;
  printErrorActive = false;
  lastReportedPrinterAlert = false;
  lastReportedPrinterAlertCritical = false;
  printErrorCode = 0;
  lastReportedPrintErrorCode = 0;
  printState = "IDLE";
  activeJob = "0";
  currentLayer = 0;
  totalLayers = 0;
  printPercent = 0;
  currentStage = -1;
  lastObservedLayer = 0;
  lastSnapLayer = 0;
  lastStatusNotifyAt = 0;
  lastPrintDataAt = 0;
  clearActiveMaterial(false);
  clearMaterialCache();
  nozzleTemperature = -1;
  nozzleTargetTemperature = -1;
  leftNozzleTemperature = -1;
  leftNozzleTargetTemperature = -1;
  bedTemperature = -1;
  bedTargetTemperature = -1;
  partFanPercent = -1;
  auxiliaryFanPercent = -1;
  exhaustFanPercent = -1;
  telemetryDirty = false;
  lastTelemetryNotifyAt = 0;
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
  const bool wroteAll =
      preferences.putString("ssid", pendingSettings.wifiSsid) ==
          pendingSettings.wifiSsid.length() &&
      preferences.putString("wifiPass", pendingSettings.wifiPassword) ==
          pendingSettings.wifiPassword.length() &&
      preferences.putString("printerIp", pendingSettings.printerIp) ==
          pendingSettings.printerIp.length() &&
      preferences.putString("serial", pendingSettings.printerSerial) ==
          pendingSettings.printerSerial.length() &&
      preferences.putString("access", pendingSettings.accessCode) ==
          pendingSettings.accessCode.length();
  if (!wroteAll) return false;

  // Read every field back before acknowledging SAVE. This prevents the app
  // from hiding the form when an interrupted/failed NVS write would otherwise
  // force the user to type the Access Code again after a restart.
  BridgeSettings verified;
  verified.wifiSsid = preferences.getString("ssid", "");
  verified.wifiPassword = preferences.getString("wifiPass", "");
  verified.printerIp = preferences.getString("printerIp", "");
  verified.printerSerial = preferences.getString("serial", "");
  verified.accessCode = preferences.getString("access", "");
  if (!verified.complete() || verified.wifiSsid != pendingSettings.wifiSsid ||
      verified.wifiPassword != pendingSettings.wifiPassword ||
      verified.printerIp != pendingSettings.printerIp ||
      verified.printerSerial != pendingSettings.printerSerial ||
      verified.accessCode != pendingSettings.accessCode) {
    return false;
  }
  settings = verified;
  pendingSettings = verified;
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

int normalizeFanPercent(int raw) {
  if (raw < 0) return -1;
  // Bambu normally reports fan gears in the 0...15 range. Keep compatibility
  // with firmware variants that expose either 0...100 or raw PWM 0...255.
  if (raw <= 15) return min(100, (raw * 100 + 7) / 15);
  if (raw <= 100) return raw;
  return min(100, (raw * 100 + 127) / 255);
}

bool updateIntIfPresent(const uint8_t *payload, size_t length,
                        const char *key, int &stored,
                        bool normalizeFan = false) {
  int incoming = -1;
  if (!extractLastJsonInt(payload, length, key, incoming)) return false;
  if (normalizeFan) incoming = normalizeFanPercent(incoming);
  if (incoming == stored) return false;
  stored = incoming;
  return true;
}

bool findObjectRangeAfterKey(const uint8_t *payload, size_t length,
                             const char *key, size_t &start, size_t &end);

bool updatePackedH2DNozzleTelemetry(const uint8_t *payload, size_t length,
                                    bool &foundPackedNozzles) {
  // H2D reports both hotends in print.extruder.info[]. Each packed `temp`
  // stores target temperature in the high 16 bits and actual temperature in
  // the low 16 bits. Extruder id 0 is right, id 1 is left.
  foundPackedNozzles = false;
  size_t extruderStart = 0;
  size_t extruderEnd = 0;
  if (!findObjectRangeAfterKey(payload, length, "extruder",
                               extruderStart, extruderEnd)) {
    return false;
  }
  const uint8_t *extruder = payload + extruderStart;
  const size_t extruderLength = extruderEnd - extruderStart;
  size_t infoPosition = 0;
  if (!findKey(extruder, extruderLength, "info", 0, infoPosition)) return false;
  size_t cursor = infoPosition;
  while (cursor < extruderLength && extruder[cursor] != '[') ++cursor;
  if (cursor >= extruderLength) return false;

  bool changed = false;
  ++cursor;
  while (cursor < extruderLength && extruder[cursor] != ']') {
    while (cursor < extruderLength && extruder[cursor] != '{' &&
           extruder[cursor] != ']') ++cursor;
    if (cursor >= extruderLength || extruder[cursor] == ']') break;
    const size_t objectStart = cursor;
    int depth = 0;
    bool inString = false;
    bool escaped = false;
    size_t objectEnd = objectStart;
    for (; objectEnd < extruderLength; ++objectEnd) {
      const char c = static_cast<char>(extruder[objectEnd]);
      if (inString) {
        if (escaped) escaped = false;
        else if (c == '\\') escaped = true;
        else if (c == '"') inString = false;
        continue;
      }
      if (c == '"') inString = true;
      else if (c == '{') ++depth;
      else if (c == '}' && --depth == 0) {
        ++objectEnd;
        break;
      }
    }
    if (objectEnd <= objectStart || objectEnd > extruderLength) break;

    int id = -1;
    uint32_t packed = 0;
    const uint8_t *object = extruder + objectStart;
    const size_t objectLength = objectEnd - objectStart;
    if (extractLastJsonInt(object, objectLength, "id", id) &&
        extractLastJsonUInt32(object, objectLength, "temp", packed) &&
        (id == 0 || id == 1)) {
      foundPackedNozzles = true;
      const int actual = static_cast<int>(packed & 0xFFFFU);
      const int target = static_cast<int>((packed >> 16U) & 0xFFFFU);
      int &storedActual = id == 0 ? nozzleTemperature : leftNozzleTemperature;
      int &storedTarget = id == 0 ? nozzleTargetTemperature
                                  : leftNozzleTargetTemperature;
      if (actual != storedActual || target != storedTarget) {
        storedActual = actual;
        storedTarget = target;
        changed = true;
      }
    }
    cursor = objectEnd;
  }
  return changed;
}

void updatePrinterTelemetry(const uint8_t *payload, size_t length) {
  bool changed = false;
  bool foundPackedNozzles = false;
  changed |= updatePackedH2DNozzleTelemetry(payload, length, foundPackedNozzles);
  const bool isH2D = printerModelFromSerial(settings.printerSerial) == "H2D";
  // During H2D preparation Bambu may publish only the generic nozzle fields.
  // Those fields describe whichever tool is currently active; they do not say
  // whether it is the left or right hotend. Never guess a physical side from
  // them. Wait for print.extruder.info[] where every value has an explicit id.
  // Single-nozzle A1/P2S printers continue to use the generic fields.
  if (!foundPackedNozzles && !isH2D) {
    changed |= updateIntIfPresent(payload, length, "nozzle_temper", nozzleTemperature);
    changed |= updateIntIfPresent(payload, length, "nozzle_target_temper",
                                  nozzleTargetTemperature);
  }
  changed |= updateIntIfPresent(payload, length, "bed_temper", bedTemperature);
  changed |= updateIntIfPresent(payload, length, "bed_target_temper",
                                bedTargetTemperature);
  changed |= updateIntIfPresent(payload, length, "cooling_fan_speed",
                                partFanPercent, true);
  changed |= updateIntIfPresent(payload, length, "big_fan1_speed",
                                auxiliaryFanPercent, true);
  changed |= updateIntIfPresent(payload, length, "big_fan2_speed",
                                exhaustFanPercent, true);
  if (changed) telemetryDirty = true;
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

// A pushall response may contain the same key in cached/nested objects and in
// the current print object. Keep the last valid string so a mid-job reconnect
// cannot turn a RUNNING print into a stale IDLE state.
bool extractLastJsonString(const uint8_t *payload, size_t length,
                           const char *key, String &output) {
  bool found = false;
  size_t searchFrom = 0;
  size_t valuePosition = 0;
  while (findKey(payload, length, key, searchFrom, valuePosition)) {
    size_t cursor = valuePosition;
    while (cursor < length &&
           (payload[cursor] == ' ' || payload[cursor] == '\t' ||
            payload[cursor] == '\r' || payload[cursor] == '\n')) {
      ++cursor;
    }
    if (cursor >= length || payload[cursor] != '"') {
      searchFrom = valuePosition;
      continue;
    }
    ++cursor;
    String value;
    while (cursor < length && payload[cursor] != '"') {
      if (payload[cursor] == '\\' && cursor + 1 < length) ++cursor;
      if (value.length() < 64) value += static_cast<char>(payload[cursor]);
      ++cursor;
    }
    if (cursor < length) {
      output = value;
      found = true;
    }
    searchFrom = valuePosition;
  }
  return found;
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

bool findObjectRangeAfterKey(const uint8_t *payload, size_t length,
                             const char *key, size_t &start, size_t &end) {
  size_t searchFrom = 0;
  size_t valuePosition = 0;
  while (findKey(payload, length, key, searchFrom, valuePosition)) {
    size_t cursor = valuePosition;
    while (cursor < length &&
           (payload[cursor] == ' ' || payload[cursor] == '\t' ||
            payload[cursor] == '\r' || payload[cursor] == '\n')) ++cursor;
    if (cursor < length && payload[cursor] == '{') {
      int depth = 0;
      bool inString = false;
      bool escaped = false;
      for (size_t i = cursor; i < length; ++i) {
        const char c = static_cast<char>(payload[i]);
        if (inString) {
          if (escaped) escaped = false;
          else if (c == '\\') escaped = true;
          else if (c == '"') inString = false;
          continue;
        }
        if (c == '"') inString = true;
        else if (c == '{') ++depth;
        else if (c == '}' && --depth == 0) {
          start = cursor;
          end = i + 1;
          return true;
        }
      }
      return false;
    }
    searchFrom = valuePosition;
  }
  return false;
}

String normalizedFilamentColor(String color) {
  color.trim();
  color.replace("#", "");
  color.toUpperCase();
  if (color.length() > 8) color = color.substring(0, 8);
  return color;
}

bool extractMaterialFromTrayIndex(const uint8_t *payload, size_t length,
                                  int trayIndex, String &type, String &color) {
  if (trayIndex < 0) return false;
  size_t amsStart = 0;
  size_t amsEnd = 0;
  if (!findObjectRangeAfterKey(payload, length, "ams", amsStart, amsEnd)) return false;

  const uint8_t *ams = payload + amsStart;
  const size_t amsLength = amsEnd - amsStart;
  size_t searchFrom = 0;
  size_t valuePosition = 0;
  int seen = 0;
  while (findKey(ams, amsLength, "tray_type", searchFrom, valuePosition)) {
    if (seen == trayIndex) {
      String parsedType;
      String parsedColor;
      const size_t typeStart = valuePosition >= 12 ? valuePosition - 12 : 0;
      if (!extractJsonString(ams + typeStart,
                             amsLength - typeStart,
                             "tray_type", parsedType)) {
        extractJsonString(ams + typeStart, amsLength - typeStart,
                          "tray_sub_brands", parsedType);
      }
      const size_t localStart = valuePosition > 16 ? valuePosition - 16 : 0;
      const size_t remaining = amsLength - localStart;
      const size_t localLength = remaining < 768 ? remaining : 768;
      extractJsonString(ams + localStart, localLength, "tray_color", parsedColor);
      if (parsedColor.length() < 6) {
        extractJsonString(ams + localStart, localLength, "cols", parsedColor);
      }
      parsedType.trim();
      if (parsedType.isEmpty()) {
        extractJsonString(ams + localStart, localLength,
                          "tray_info_idx", parsedType);
        parsedType.trim();
      }
      if (parsedType.isEmpty()) return false;
      type = parsedType;
      color = normalizedFilamentColor(parsedColor);
      return true;
    }
    ++seen;
    searchFrom = valuePosition;
  }
  return false;
}

bool extractExternalMaterial(const uint8_t *payload, size_t length,
                             String &type, String &color) {
  size_t start = 0;
  size_t end = 0;
  if (!findObjectRangeAfterKey(payload, length, "vt_tray", start, end)) return false;
  String parsedType;
  String parsedColor;
  if (!extractJsonString(payload + start, end - start, "tray_type", parsedType)) {
    extractJsonString(payload + start, end - start, "tray_sub_brands", parsedType);
  }
  if (parsedType.isEmpty()) {
    extractJsonString(payload + start, end - start, "tray_info_idx", parsedType);
  }
  extractJsonString(payload + start, end - start, "tray_color", parsedColor);
  if (parsedColor.length() < 6) {
    extractJsonString(payload + start, end - start, "cols", parsedColor);
  }
  parsedType.trim();
  if (parsedType.isEmpty()) return false;
  type = parsedType;
  color = normalizedFilamentColor(parsedColor);
  return true;
}

int materialCacheIndex(int trayIndex) {
  if (trayIndex >= 0 && trayIndex < 16) return trayIndex;
  if (trayIndex == 254) return 16;
  return -1;
}

void cacheMaterial(int trayIndex, const String &type, const String &color) {
  const int index = materialCacheIndex(trayIndex);
  if (index < 0 || type.isEmpty()) return;
  cachedFilamentType[index] = type;
  cachedFilamentColor[index] = color;
}

bool readCachedMaterial(int trayIndex, String &type, String &color) {
  const int index = materialCacheIndex(trayIndex);
  if (index < 0 || cachedFilamentType[index].isEmpty()) return false;
  type = cachedFilamentType[index];
  color = cachedFilamentColor[index];
  return true;
}

void refreshMaterialCache(const uint8_t *payload, size_t length) {
  // Full pushall packets contain all AMS trays. Cache them once so small MQTT
  // updates that only change tray_now can still switch the UI immediately to
  // the real filament type and color currently feeding the nozzle.
  size_t amsStart = 0;
  size_t amsEnd = 0;
  if (findObjectRangeAfterKey(payload, length, "ams", amsStart, amsEnd)) {
    for (int tray = 0; tray < 16; ++tray) {
      String type;
      String color;
      if (extractMaterialFromTrayIndex(payload, length, tray, type, color)) {
        cacheMaterial(tray, type, color);
      }
    }
  }
  String externalType;
  String externalColor;
  if (extractExternalMaterial(payload, length, externalType, externalColor)) {
    cacheMaterial(254, externalType, externalColor);
  }
}

void updateActiveMaterial(const uint8_t *payload, size_t length) {
  refreshMaterialCache(payload, length);
  int trayNow = 255;
  const bool hasTrayNow = extractLastJsonInt(payload, length, "tray_now", trayNow);
  if ((!hasTrayNow || trayNow == 255 || trayNow < 0) &&
      activeFilamentSlot >= 0) {
    // During a tool/filament transition Bambu briefly reports no current tray.
    // Keep the last truly active color instead of jumping early to tray_tar.
    trayNow = activeFilamentSlot;
  }
  if (trayNow == 255 || trayNow < 0) {
    int trayPrevious = 255;
    if (extractLastJsonInt(payload, length, "tray_pre", trayPrevious) &&
        trayPrevious >= 0 && trayPrevious != 255) {
      trayNow = trayPrevious;
    }
  }
  if (trayNow == 255 || trayNow < 0) {
    int trayTarget = 255;
    if (extractLastJsonInt(payload, length, "tray_tar", trayTarget) &&
        trayTarget >= 0 && trayTarget != 255) {
      trayNow = trayTarget;
    }
  }

  String type;
  String color;
  bool found = readCachedMaterial(trayNow, type, color);
  if (!found) {
    found = trayNow == 254
        ? extractExternalMaterial(payload, length, type, color)
        : trayNow >= 0 && trayNow < 254 &&
              extractMaterialFromTrayIndex(payload, length, trayNow, type, color);
    if (found) cacheMaterial(trayNow, type, color);
  }
  // A1/P2S without AMS can report tray_now=255 while idle even though the
  // external virtual tray already contains the selected material. Use that
  // data as a safe fallback; when printing, tray_now=254 takes precedence.
  if (!found && (trayNow == 255 || trayNow < 0)) {
    found = readCachedMaterial(254, type, color) ||
            extractExternalMaterial(payload, length, type, color);
    if (found) trayNow = 254;
  }
  if (!found) return;
  if (type == activeFilamentType && color == activeFilamentColor &&
      trayNow == activeFilamentSlot) return;
  activeFilamentType = type;
  activeFilamentColor = color;
  activeFilamentSlot = trayNow;
  materialSyncRequests = Config::MATERIAL_SYNC_RETRY_LIMIT;
  reportMaterial();
  Serial.printf("[MATERIAL] %s #%s slot=%d\n", activeFilamentType.c_str(),
                activeFilamentColor.c_str(), activeFilamentSlot);
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
  const bool failedState = printState == "FAILED" || printState == "ERROR";
  const bool critical = failedState || (printContext && printErrorActive);
  const bool active = critical || (printContext && hmsAlertActive);
  if (!force && active == lastReportedPrinterAlert &&
      critical == lastReportedPrinterAlertCritical &&
      printErrorCode == lastReportedPrintErrorCode) {
    return;
  }
  if (active) {
    if (critical) {
      char errorCode[11];
      snprintf(errorCode, sizeof(errorCode), "0x%08lX",
               static_cast<unsigned long>(printErrorCode));
      queuePhoneEvent(String("H2D,ALERT,1,ERROR,") +
                      printerModelFromSerial(settings.printerSerial) +
                      " báo lỗi máy in • mã " +
                      errorCode + " • xem màn hình máy in");
    } else {
      // HMS can contain an acknowledged advisory (for example a lens-cleaning
      // reminder) while H2D is legitimately cleaning the nozzle. Report it as
      // secondary information; only print_error/FAILED may turn the Island red.
      queuePhoneEvent(String("H2D,ALERT,1,WARN,") +
                      printerModelFromSerial(settings.printerSerial) +
                      " có lưu ý HMS • xem màn hình máy in");
    }
  } else {
    queuePhoneEvent("H2D,ALERT,0,CLEAR");
  }
  lastReportedPrinterAlert = active;
  lastReportedPrinterAlertCritical = critical;
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
  captureFlashUntil = millis() + 650;
  queuePhoneEvent(String("H2D,SNAP,") + layer + "," +
                  max(layer, totalLayers) + "," + activeJob);
  Serial.printf("[SNAP] completed layer %d/%d\n", layer, totalLayers);
}

void resetForNewPrint(const String &job, int layer) {
  activeJob = job;
  currentLayer = max(0, layer);
  lastObservedLayer = currentLayer;
  // A bridge restart in the middle of a job must establish a baseline, not
  // replay layers 1...N to the iPhone. The current layer becomes eligible
  // only when the printer advances to the next one.
  lastSnapLayer = max(0, currentLayer - 1);
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
      // a picture while the reported layer is still being printed. If a
      // report jumps over more than one layer, queue each missing completed
      // layer instead of silently turning the timelapse into a timer-like
      // sequence.
      const int lastCompletedLayer = currentLayer - 1;
      for (int completedLayer = max(1, lastSnapLayer + 1);
           completedLayer <= lastCompletedLayer; ++completedLayer) {
        sendSnapshot(completedLayer);
      }
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
  const bool hasState =
      extractLastJsonString(payload, length, "gcode_state", state);
  bool hasJob = extractJsonString(payload, length, "job_id", job);
  if (!hasJob) hasJob = extractJsonString(payload, length, "subtask_id", job);

  if (hasLayer || hasTotal || hasPercent || hasStage || hasState ||
      hasPrintError || hasHms) {
    statusDataSeen = true;
    lastPrintDataAt = millis();
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
  updateActiveMaterial(payload, length);
  updatePrinterTelemetry(payload, length);
  // A state transition to IDLE must clear a previously active warning even
  // when that incremental packet does not contain hms/print_error fields.
  if (hasPrintError || hasHms || hasState) reportPrinterAlert();
}

void publishStatusRequest() {
  if (!mqtt.connected()) return;
  lastStatusRequestAt = millis();
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
  lastPrintDataAt = 0;
  lastStatusRequestAt = 0;
  materialSyncRequests = 0;
  lastWifiAttemptAt = 0;
  lastMqttAttemptAt = 0;
}

void maintainWiFi() {
  if (!settings.complete()) return;
  if (WiFi.status() == WL_CONNECTED) return;
  const uint32_t now = millis();
  if (lastWifiAttemptAt != 0 &&
      now - lastWifiAttemptAt < Config::WIFI_RETRY_MS) return;
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
      if (activeFilamentType.isEmpty()) ++materialSyncRequests;
    }
    // Some H2D firmware revisions do not immediately answer the first
    // pushall sent right after MQTT subscription. Retry only while no fresh
    // print data is arriving, so opening SE in the middle of a job reliably
    // recovers RUNNING/layer/percent without flooding the printer.
    const uint32_t now = millis();
    const bool printDataStale =
        lastPrintDataAt == 0 || now - lastPrintDataAt > Config::PRINT_DATA_STALE_MS;
    const bool materialMissing =
        activeFilamentType.isEmpty() &&
        materialSyncRequests < Config::MATERIAL_SYNC_RETRY_LIMIT;
    if ((printDataStale || materialMissing) &&
        now - lastStatusRequestAt >= Config::STATUS_REQUEST_RETRY_MS) {
      publishStatusRequest();
      if (materialMissing) ++materialSyncRequests;
    }
    if (!statusDataSeen && lastMqttMessageAt > 0 &&
        millis() - lastMqttMessageAt > Config::DATA_TIMEOUT_MS) {
      queuePhoneEvent(String("H2D,ERROR,") +
                      printerModelFromSerial(settings.printerSerial) +
                      " không trả dữ liệu • bật LAN Only và Developer Mode");
      lastMqttMessageAt = millis();
    }
    return;
  }

  if (mqttWasConnected) {
    Serial.printf("[MQTT] disconnected, state=%d; reconnecting\n", mqtt.state());
  }
  mqttWasConnected = false;
  const uint32_t now = millis();
  if (lastMqttAttemptAt != 0 &&
      now - lastMqttAttemptAt < Config::MQTT_RETRY_MS) return;
  lastMqttAttemptAt = now;
  reportStatus("MQTT_CONNECTING");
  const uint64_t chip = ESP.getEfuseMac();
  char clientId[32];
  snprintf(clientId, sizeof(clientId), "SE-Bambu-%08lX",
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
    const int mqttState = mqtt.state();
    if (mqttState == MQTT_CONNECT_BAD_CREDENTIALS ||
        mqttState == MQTT_CONNECT_UNAUTHORIZED) {
      reportStatus("MQTT_AUTH_FAILED");
    } else {
      reportStatus("MQTT_RETRY");
    }
    return;
  }
  const String reportTopic = "device/" + settings.printerSerial + "/report";
  mqtt.subscribe(reportTopic.c_str(), 0);
  lastMqttMessageAt = millis();
  statusDataSeen = false;
  lastPrintDataAt = 0;
  lastStatusRequestAt = 0;
  Serial.println("[MQTT] connected and subscribed to Bambu report topic");
}

void sendCurrentStatus() {
  queuePhoneEvent("H2D,ESP32,SE_BAMBU_ESP32_BRIDGE,1.8.3");
  reportPrinterIdentity();
  if (!activeFilamentType.isEmpty()) reportMaterial();
  reportTelemetry(true);
  if (!settings.complete()) {
    reportStatus("CONFIG_REQUIRED");
  } else if (WiFi.status() != WL_CONNECTED) {
    reportStatus("WIFI_CONNECTING");
  } else if (!mqtt.connected()) {
    reportStatus("MQTT_CONNECTING");
  } else {
    if (!statusDataSeen) {
      // Never label a job IDLE from boot-time defaults while the first H2D
      // packet is still in flight.
      reportStatus("SYNCING");
    } else {
      reportStatus(timelapseArmed ? "ARMED" : "READY");
      reportPrintStatus(true);
      reportPrinterAlert(true);
    }
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
      // A profile switch (A1/H2D/P2S) must never expose queued status,
      // material, temperature or fan data from the previous printer.
      resetPrinterRuntimeForProfileSwitch();
      clearPhoneEventQueue();
      queuePhoneEvent("H2D,CFG_ACK,SAVE");
      reportStatus("CONFIG_SAVED");
      disconnectNetwork();
    } else {
      queuePhoneEvent("H2D,ERROR,Cấu hình thiếu hoặc IP máy in chưa đúng");
    }
  } else if (head == "H2D_ARM") {
    timelapseArmed = argument == "1";
    if (timelapseArmed) {
      // Arm at the current layer so reconnecting in the middle of a print does
      // not invent frames for layers that the iPhone never observed.
      lastObservedLayer = currentLayer;
      // Resume from the layer currently being printed. On the next transition
      // only that just-finished layer is emitted; old layers are never filled.
      lastSnapLayer = max(0, currentLayer - 1);
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

uint32_t scaledLedColor(uint8_t red, uint8_t green, uint8_t blue,
                        uint8_t scale) {
  return ledStrip.Color(
      static_cast<uint16_t>(red) * scale / 255,
      static_cast<uint16_t>(green) * scale / 255,
      static_cast<uint16_t>(blue) * scale / 255);
}

void fillLedStrip(uint32_t color) {
  for (uint16_t i = 0; i < Config::LED_STRIP_COUNT; ++i) {
    ledStrip.setPixelColor(i, color);
  }
}

void updateLedStrip() {
  const uint32_t now = millis();
  if (now - lastLedRefreshAt < Config::LED_REFRESH_MS) return;
  lastLedRefreshAt = now;
  ledStrip.clear();

  const bool criticalError = printErrorActive || printState == "FAILED" ||
                             printState == "ERROR";
  if (criticalError) {
    fillLedStrip(ledStrip.Color(255, 0, 0));
  } else if (static_cast<int32_t>(captureFlashUntil - now) > 0) {
    // Same meaning as the blue border on iPhone: one layer photo was ordered.
    fillLedStrip(ledStrip.Color(0, 105, 255));
  } else if (printState == "RUNNING" &&
             (currentStage == 0 || currentStage == -1)) {
    // LED 0 is the 12 o'clock point. Install the strip clockwise so the
    // physical progress follows the iPhone border in the same direction.
    uint16_t lit = printPercent >= 100
        ? Config::LED_STRIP_COUNT
        : (Config::LED_STRIP_COUNT * printPercent + 99) / 100;
    if (lit < 1) lit = 1;
    for (uint16_t i = 0; i < lit; ++i) {
      uint8_t scale = 150;
      if (i + 1 == lit) scale = 255;
      else if (i + 2 == lit) scale = 215;
      ledStrip.setPixelColor(i, scaledLedColor(0, 255, 65, scale));
    }
    for (uint16_t i = lit; i < Config::LED_STRIP_COUNT; ++i) {
      ledStrip.setPixelColor(i, ledStrip.Color(0, 9, 2));
    }
  } else {
    // Waiting, connecting and every preparation/cleaning/calibration stage:
    // breathe yellow on a two-second cycle exactly like the iPhone UI.
    const uint16_t phase = now % 2000;
    const uint16_t ramp = phase < 1000 ? phase : 2000 - phase;
    const uint8_t scale = 35 + static_cast<uint32_t>(ramp) * 220 / 1000;
    fillLedStrip(scaledLedColor(255, 190, 0, scale));
  }
  ledStrip.show();
}

void setup() {
  Serial.begin(115200);
  delay(250);
  Serial.println("\nSE Bambu Timelapse Bridge ESP32 v1.8.5");
  ledStrip.begin();
  ledStrip.setBrightness(Config::LED_BRIGHTNESS);
  ledStrip.clear();
  ledStrip.show();
  loadSettings();
  setupBle();

  tlsClient.setInsecure();  // Bambu uses a per-device/self-signed LAN certificate.
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
  reportTelemetry(false);
  flushPhoneEvents();
  updateLedStrip();
  delay(2);
}

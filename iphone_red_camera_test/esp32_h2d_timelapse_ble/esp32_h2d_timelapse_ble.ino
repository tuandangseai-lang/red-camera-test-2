#include <Arduino.h>
#include <Adafruit_NeoPixel.h>
#include <NimBLEDevice.h>
#include <Preferences.h>
#include <PubSubClient.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <mbedtls/base64.h>
#include <memory>

// SE Bambu Timelapse Bridge for classic ESP32 v1.15.9
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
// The largest H2D status packet measured on the target printer is 21,775
// bytes.  A 24-KB primary buffer leaves safe protocol headroom while freeing
// enough classic-ESP32 heap for the rotating background-printer TLS sample.
constexpr uint16_t MQTT_BUFFER_BYTES = 24576;
constexpr uint16_t MQTT_FALLBACK_BUFFER_BYTES = 23552;
// TLS needs a large contiguous heap block during its handshake. PubSubClient's
// payload buffer is kept small until TLS is established, then expanded before
// subscribing to Bambu reports.
constexpr uint16_t MQTT_CONNECT_BUFFER_BYTES = 1024;
// While a background profile is sampled the selected client's receive buffer
// is temporarily released. This lets the short-lived scanner use a full-size
// buffer too; Bambu pushall packets are about 22 KB and were silently dropped
// by the former 4-KB scanner, leaving an active printer yellow until its tab
// was selected manually.
constexpr uint16_t FLEET_MQTT_BUFFER_BYTES = 24576;
constexpr uint16_t FLEET_MQTT_FALLBACK_BUFFER_BYTES = 23552;
constexpr uint32_t WIFI_RETRY_MS = 12000;
// A printer profile switch keeps the Wi-Fi association alive and only
// rebuilds MQTT.  A short retry interval makes an idle/offline target fail
// quickly without leaving the iPhone waiting through a ten-second dead time.
constexpr uint32_t MQTT_RETRY_MS = 2500;
constexpr uint32_t MQTT_TCP_TIMEOUT_MS = 2000;
constexpr uint32_t FLEET_TCP_TIMEOUT_MS = 1200;
constexpr uint32_t MQTT_TLS_HANDSHAKE_TIMEOUT_SECONDS = 3;
constexpr uint32_t FLEET_TLS_HANDSHAKE_TIMEOUT_SECONDS = 2;
// Keep Bambu's established 60-second MQTT interval. Active print/status
// packets keep the session alive; stale writes are closed explicitly below.
constexpr uint16_t MQTT_KEEPALIVE_SECONDS = 60;
// A lightweight TCP reachability sweep is independent from MQTT. This lets
// the three status pixels distinguish a powered printer (yellow) from a truly
// offline printer (black), even while the selected printer is reconnecting.
constexpr uint32_t FLEET_PROBE_PERIOD_MS = 900;
constexpr uint32_t FLEET_PROBE_TIMEOUT_MS = 350;
constexpr uint32_t FLEET_ONLINE_GRACE_MS = 6500;
constexpr uint8_t FLEET_OFFLINE_FAILURES = 3;
// Every fifteen seconds, temporarily preserve the selected profile, scan both
// non-selected printers in sequence, then restore the user's selected profile.
// The longer interval prevents rapid TLS reconnects from fragmenting heap or
// making the iPhone state flash between colours.
constexpr uint32_t FLEET_REFRESH_PERIOD_MS = 15000;
constexpr uint8_t FLEET_SAMPLES_PER_REFRESH = 2;
// H2D's full 22-KB pushall can arrive noticeably later than A1/P2S. Keep the
// short-lived scanner open long enough to receive that packet, otherwise an
// H2D fault could be missed until its profile was selected manually.
constexpr uint32_t FLEET_MONITOR_DWELL_MS = 3000;
constexpr uint32_t FLEET_MONITOR_RETRY_GAP_MS = 250;
constexpr uint32_t PRINT_COMPLETE_BLUE_MS = 3UL * 60UL * 60UL * 1000UL;
constexpr uint32_t PRINT_COMPLETE_PULSE_MS = 4000;
constexpr uint32_t STATUS_PERIOD_MS = 2000;
constexpr uint32_t TELEMETRY_PERIOD_MS = 1000;
constexpr uint32_t STATUS_REQUEST_RETRY_MS = 3500;
constexpr uint32_t PRINT_DATA_STALE_MS = 10000;
constexpr uint32_t DATA_TIMEOUT_MS = 45000;
constexpr uint8_t MATERIAL_SYNC_RETRY_LIMIT = 5;
constexpr uint8_t NOZZLE_SYNC_RETRY_LIMIT = 8;
constexpr uint32_t BLE_NOTIFY_GAP_MS = 22;
constexpr uint32_t CONFIG_NETWORK_QUIET_MS = 8000;
constexpr uint8_t EVENT_QUEUE_SIZE = 24;
constexpr size_t EVENT_LENGTH = 150;
// Seven WS2812B packages are active: pixels 0...2 hold the steady state colour
// and pixels 3...6 show the configured animation/progress.
// DATA -> GPIO5 through 330 ohms; 5V/GND must share GND with the ESP32.
constexpr uint8_t LED_STRIP_PIN = 5;
constexpr uint16_t LED_STATUS_COUNT = 3;
constexpr uint16_t LED_ANIMATED_COUNT = 4;
constexpr uint16_t LED_ACTIVE_COUNT = LED_STATUS_COUNT + LED_ANIMATED_COUNT;
// The installed strip contains ten packages, but only the first seven are in
// use. Keep the final three in each transmitted frame so they are actively
// cleared instead of retaining a colour from an earlier firmware build.
constexpr uint16_t LED_PHYSICAL_COUNT = 10;
// Controls use INPUT_PULLUP: each button/switch contact closes to GND.
constexpr uint8_t HOLD_BUTTON_PIN = 27;
constexpr uint8_t MODE_TIMELAPSE_PIN = 25;
constexpr uint8_t MODE_TORCH_PIN = 26;
// Three-pin active buzzer module: S -> GPIO33, + -> module supply, - -> GND.
// Use a common ground with ESP32. Set false for modules whose input is active LOW.
constexpr uint8_t BUZZER_PIN = 33;
constexpr bool BUZZER_ACTIVE_HIGH = true;
constexpr uint32_t BUZZER_ON_MS = 180;
constexpr uint32_t BUZZER_OFF_MS = 100;
// The three-pin active buzzer is an on/off oscillator, so changing the length
// of one solid pulse does not change its instantaneous loudness. Modulate its
// enable input at 100 Hz instead: this is slow enough for the module to start,
// fast enough to remain one continuous notification, and gives the volume
// slider a clearly audible range. A quadratic curve gives the lower half of
// the slider more useful travel without making quiet settings disappear.
constexpr uint32_t BUZZER_VOLUME_PWM_HZ = 100;
constexpr uint8_t BUZZER_VOLUME_PWM_BITS = 10;
constexpr uint16_t BUZZER_VOLUME_PWM_MAX =
    (1u << BUZZER_VOLUME_PWM_BITS) - 1u;
// Active three-pin buzzer modules can stall when their supply pulse becomes
// too narrow. Keep every non-zero setting above the reliable start threshold;
// the quadratic curve still provides a clearly quieter lower half.
constexpr uint16_t BUZZER_MIN_AUDIBLE_DUTY = 220;
constexpr uint8_t LED_MIN_BRIGHTNESS = 0;
constexpr uint8_t LED_MAX_BRIGHTNESS = 255;
constexpr uint8_t LED_DEFAULT_BRIGHTNESS_PERCENT = 95;
constexpr uint8_t LED_IDLE_MAX_SCALE = 102;  // 40% of the normal LED level.
constexpr uint32_t LED_REFRESH_MS = 35;
constexpr uint32_t INPUT_REFRESH_MS = 20;
constexpr uint32_t INPUT_DEBOUNCE_MS = 140;
// The maintained three-position rotary contact can chatter for much longer
// than a momentary button. Accept a new position only after it has remained
// continuously stable; hardwareMode then guarantees one event/beep per
// accepted position without suppressing a quick deliberate 1 -> 2 -> 3 move.
constexpr uint32_t MODE_INPUT_DEBOUNCE_MS = 220;
constexpr uint32_t BUZZER_BEEP_MS = 150;
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

constexpr uint8_t FLEET_PRINTER_COUNT = 3;
constexpr uint8_t BACKGROUND_MONITOR_COUNT = 2;

struct FleetProfile {
  String kind;
  String printerIp;
  String printerSerial;
  String accessCode;

  bool complete() const {
    IPAddress address;
    return (kind == "A1" || kind == "H2D" || kind == "P2S") &&
           address.fromString(printerIp) && !printerSerial.isEmpty() &&
           !accessCode.isEmpty();
  }
};

struct FleetRuntime {
  String state = "OFFLINE";
  int percent = 0;
  bool online = false;
  bool printErrorActive = false;
  bool criticalLatched = false;
  bool physicalAlarmAcknowledged = false;
  uint32_t printErrorCode = 0;
  uint32_t lastMessageAt = 0;
  uint32_t lastReachableAt = 0;
  uint8_t consecutiveProbeFailures = 0;
  bool lastReportedConfigured = false;
  bool lastReportedOnline = false;
  bool lastReportedActive = false;
  bool lastReportedCritical = false;
  String lastReportedState = "";
  int lastReportedPercent = -1;
};

Preferences preferences;
BridgeSettings settings;
BridgeSettings pendingSettings;
WiFiClientSecure tlsClient;
PubSubClient mqtt(tlsClient);
// Only one background printer is sampled at a time.  Keeping four separate
// TLS objects on a classic ESP32 fragmented the heap badly enough that H2D's
// large status packet could no longer be received by the selected session.
WiFiClientSecure fleetTls;
WiFiClient fleetProbeClient;
PubSubClient fleetMqtt(fleetTls);
FleetProfile fleetProfiles[FLEET_PRINTER_COUNT];
FleetRuntime fleetRuntimes[FLEET_PRINTER_COUNT];
int8_t selectedFleetIndex = -1;
int8_t monitorProfileIndex[BACKGROUND_MONITOR_COUNT] = {-1, -1};
uint32_t monitorLastAttemptAt[BACKGROUND_MONITOR_COUNT] = {0, 0};
uint32_t monitorSequenceId[BACKGROUND_MONITOR_COUNT] = {0, 0};
int8_t activeFleetMonitorSlot = -1;
int8_t activeFleetProfileIndex = -1;
bool fleetSampleReceived = false;
// The classic ESP32 cannot hold two TLS sessions plus a 24-KB Bambu pushall
// buffer reliably. A fleet refresh therefore parks the selected MQTT session,
// samples the two background profiles in sequence, then reconnects the selected
// profile without changing the iPhone's visible selection.
bool fleetPrimaryPaused = false;
uint32_t activeFleetMonitorSince = 0;
uint32_t lastFleetRefreshAt = 0;
uint32_t nextFleetMonitorAttemptAt = 0;
uint8_t fleetMonitorCursor = 0;
uint8_t nextFleetMonitorSlot = 0;
uint8_t fleetSamplesThisRefresh = 0;
volatile bool fleetRefreshRequested = true;
bool fleetRefreshInProgress = false;
uint32_t lastFleetProbeAt = 0;
uint8_t nextFleetProbeIndex = 0;
Adafruit_NeoPixel ledStrip(
    Config::LED_PHYSICAL_COUNT, Config::LED_STRIP_PIN, NEO_GRB + NEO_KHZ800);
NimBLECharacteristic *eventCharacteristic = nullptr;

portMUX_TYPE eventMux = portMUX_INITIALIZER_UNLOCKED;
char eventQueue[Config::EVENT_QUEUE_SIZE][Config::EVENT_LENGTH];
uint8_t eventHead = 0;
uint8_t eventTail = 0;

volatile bool phoneConnected = false;
volatile bool networkResetPending = false;
// H2D_SELECT changes only the MQTT target.  H2D_SAVE may change the Wi-Fi
// network and therefore still performs a full Wi-Fi reset.
volatile bool keepWifiOnNetworkReset = false;
volatile bool fleetAssignmentsPending = false;
volatile bool statusRequestPending = false;
bool timelapseArmed = false;
bool mqttWasConnected = false;
bool statusDataSeen = false;
bool finishSent = false;
bool printWasRunning = false;
bool hmsAlertActive = false;
bool printErrorActive = false;
bool criticalAlarmLatched = false;
bool physicalCriticalAcknowledged = false;
volatile bool buzzerEnabled = true;
volatile uint8_t buzzerVolumePercent = 100;
volatile uint8_t ledBrightnessPercent = Config::LED_DEFAULT_BRIGHTNESS_PERCENT;
bool lastReportedPrinterAlert = false;
bool lastReportedPrinterAlertCritical = false;
uint32_t printErrorCode = 0;
uint32_t lastReportedPrintErrorCode = 0;
String printState = "IDLE";
String activeJob = "0";
String activeFilamentType = "";
int activeFilamentSlot = -1;
uint8_t materialSyncRequests = 0;
uint8_t nozzleSyncRequests = 0;
constexpr uint8_t MATERIAL_CACHE_SLOTS = 17;  // AMS 0...15 + external 16.
String cachedFilamentType[MATERIAL_CACHE_SLOTS];
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
int remainingMinutes = -1;
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
uint8_t consecutiveStatusPublishFailures = 0;
uint32_t lastBleNotifyAt = 0;
uint32_t sequenceId = 0;
uint32_t captureFlashUntil = 0;
uint32_t lastLedRefreshAt = 0;
uint32_t modeEntryFlashUntil = 0;
uint32_t printCompleteBlueUntil = 0;
uint32_t buzzerBeepUntil = 0;
bool buzzerOutputRequested = false;
uint32_t settingsPreviewUntil = 0;
uint8_t settingsPreviewPercent = 0;
uint8_t settingsPreviewType = 0;  // 1 = buzzer, 2 = LED brightness.
uint32_t lastInputRefreshAt = 0;
uint32_t modeCandidateSince = 0;
uint32_t holdCandidateSince = 0;
uint32_t lastProgressTickAt = 0;
volatile uint32_t lastConfigurationCommandAt = 0;
int8_t hardwareMode = 0;  // -1 = torch, 0 = normal, +1 = timelapse.
int8_t modeCandidate = 0;
bool hardwareHoldPressed = false;
bool holdCandidate = false;
float displayedPrintPercent = 0.0f;

void reportHardwareControls();
void queueHardwareControl(const char *name, int value);
void setBuzzerOutput(bool enabled);
void requestBuzzerBeep(uint32_t durationMs = Config::BUZZER_BEEP_MS);
void pauseSelectedMqttForFleetScan();
void resumeSelectedMqttAfterFleetScan();

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
                  "," + totalLayers + "," + printPercent + "," + currentStage +
                  "," + remainingMinutes + "," + settings.printerSerial);
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

int8_t fleetIndexForKind(String kind) {
  kind.trim();
  kind.toUpperCase();
  if (kind == "A1") return 0;
  if (kind == "H2D") return 1;
  if (kind == "P2S") return 2;
  return -1;
}

int8_t fleetIndexForSerial(const String &serial) {
  String normalized = serial;
  normalized.trim();
  normalized.toUpperCase();
  for (uint8_t i = 0; i < FLEET_PRINTER_COUNT; ++i) {
    String candidate = fleetProfiles[i].printerSerial;
    candidate.trim();
    candidate.toUpperCase();
    if (!normalized.isEmpty() && candidate == normalized) return i;
  }
  // Compatibility fallback for settings saved by firmware <= 1.13.0, where
  // A1/H2D/P2S were hard-wired to slots 0/1/2.
  return fleetIndexForKind(printerModelFromSerial(serial));
}

bool isActivePrintState(const String &state) {
  return state == "RUNNING" || state == "PREPARE" ||
         state == "PREPARING" || state == "PAUSE" ||
         state == "PAUSED" || state == "SLICING" || state == "INIT" ||
         state == "HEATING";
}

bool isStoppedPrintState(const String &state) {
  return state == "STOP" || state == "STOPPED" || state == "CANCEL" ||
         state == "CANCELED" || state == "CANCELLED";
}

bool isCompletedPrintState(const String &state) {
  return state == "FINISH" || state == "COMPLETE" || state == "COMPLETED";
}

bool fleetRuntimeCritical(const FleetRuntime &runtime) {
  return !isStoppedPrintState(runtime.state) && runtime.criticalLatched;
}

bool fleetRuntimePhysicalCritical(const FleetRuntime &runtime) {
  return fleetRuntimeCritical(runtime) && !runtime.physicalAlarmAcknowledged;
}

void reportFleetStatus(uint8_t index, bool force = false) {
  if (index >= FLEET_PRINTER_COUNT) return;
  FleetProfile &profile = fleetProfiles[index];
  FleetRuntime &runtime = fleetRuntimes[index];
  const bool configured = profile.complete();
  const bool online = configured && runtime.online;
  const bool active = online && isActivePrintState(runtime.state);
  const bool critical = configured && fleetRuntimeCritical(runtime);
  if (!force && configured == runtime.lastReportedConfigured &&
      online == runtime.lastReportedOnline &&
      active == runtime.lastReportedActive &&
      critical == runtime.lastReportedCritical &&
      runtime.state == runtime.lastReportedState &&
      runtime.percent == runtime.lastReportedPercent) {
    return;
  }
  const String kind = profile.kind.isEmpty()
                          ? (index == 0 ? "A1" : index == 1 ? "H2D" : "P2S")
                          : profile.kind;
  queuePhoneEvent(String("H2D,FLEET,") + kind + "," +
                  (configured ? 1 : 0) + "," + (online ? 1 : 0) + "," +
                  (active ? 1 : 0) + "," + (critical ? 1 : 0) + "," +
                  (online ? runtime.state : "OFFLINE") + "," +
                  constrain(runtime.percent, 0, 100) + "," +
                  static_cast<unsigned long>(runtime.printErrorCode));
  queuePhoneEvent(String("H2D,FLEET_SLOT,") + index + "," + kind + "," +
                  (configured ? 1 : 0) + "," + (online ? 1 : 0) + "," +
                  (active ? 1 : 0) + "," + (critical ? 1 : 0) + "," +
                  (online ? runtime.state : "OFFLINE") + "," +
                  constrain(runtime.percent, 0, 100) + "," +
                  static_cast<unsigned long>(runtime.printErrorCode) + "," +
                  safeEventField(profile.printerSerial));
  runtime.lastReportedConfigured = configured;
  runtime.lastReportedOnline = online;
  runtime.lastReportedActive = active;
  runtime.lastReportedCritical = critical;
  runtime.lastReportedState = runtime.state;
  runtime.lastReportedPercent = runtime.percent;
}

void syncSelectedFleetRuntime(bool forceReport = false) {
  if (selectedFleetIndex < 0 || selectedFleetIndex >= FLEET_PRINTER_COUNT) {
    selectedFleetIndex = fleetIndexForSerial(settings.printerSerial);
  }
  if (selectedFleetIndex < 0) return;
  FleetRuntime &runtime = fleetRuntimes[selectedFleetIndex];
  // Never turn a reachable printer black merely because the selected MQTT
  // session is between handshakes. The independent TCP probe owns OFFLINE;
  // MQTT supplies the authoritative print state whenever data is available.
  if (mqttWasConnected) {
    runtime.online = true;
    runtime.lastReachableAt = millis();
    runtime.consecutiveProbeFailures = 0;
    if (runtime.state == "OFFLINE") runtime.state = "IDLE";
  }
  if (mqttWasConnected && statusDataSeen) {
    runtime.state = printState;
    runtime.percent = printPercent;
    runtime.printErrorActive = printErrorActive;
    runtime.printErrorCode = printErrorCode;
    runtime.criticalLatched = criticalAlarmLatched;
    runtime.physicalAlarmAcknowledged = physicalCriticalAcknowledged;
    runtime.lastMessageAt = lastMqttMessageAt;
  }
  reportFleetStatus(selectedFleetIndex, forceReport);
}

bool hasAnyFleetCriticalError() {
  if (criticalAlarmLatched && !isStoppedPrintState(printState)) return true;
  for (uint8_t i = 0; i < FLEET_PRINTER_COUNT; ++i) {
    if (fleetProfiles[i].complete() && fleetRuntimeCritical(fleetRuntimes[i])) {
      return true;
    }
  }
  return false;
}

bool hasAnyFleetPhysicalCriticalError() {
  if (criticalAlarmLatched && !isStoppedPrintState(printState) &&
      !physicalCriticalAcknowledged) {
    return true;
  }
  for (uint8_t i = 0; i < FLEET_PRINTER_COUNT; ++i) {
    // The selected printer is represented by the primary runtime above.
    if (static_cast<int8_t>(i) == selectedFleetIndex) continue;
    if (fleetProfiles[i].complete() &&
        fleetRuntimePhysicalCritical(fleetRuntimes[i])) {
      return true;
    }
  }
  return false;
}

bool hasBackgroundFleetCriticalError() {
  for (uint8_t i = 0; i < FLEET_PRINTER_COUNT; ++i) {
    if (static_cast<int8_t>(i) == selectedFleetIndex) continue;
    if (fleetProfiles[i].complete() && fleetRuntimeCritical(fleetRuntimes[i])) {
      return true;
    }
  }
  return false;
}

bool hasBackgroundFleetPhysicalCriticalError() {
  for (uint8_t i = 0; i < FLEET_PRINTER_COUNT; ++i) {
    if (static_cast<int8_t>(i) == selectedFleetIndex) continue;
    if (fleetProfiles[i].complete() &&
        fleetRuntimePhysicalCritical(fleetRuntimes[i])) {
      return true;
    }
  }
  return false;
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
                  safeEventField(activeFilamentType));
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
  }
}

void clearActiveMaterial(bool notifyPhone = true) {
  activeFilamentType = "";
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
  criticalAlarmLatched = false;
  lastReportedPrinterAlert = false;
  lastReportedPrinterAlertCritical = false;
  printErrorCode = 0;
  lastReportedPrintErrorCode = 0;
  printState = "IDLE";
  activeJob = "0";
  currentLayer = 0;
  totalLayers = 0;
  printPercent = 0;
  remainingMinutes = -1;
  currentStage = -1;
  lastObservedLayer = 0;
  lastSnapLayer = 0;
  lastStatusNotifyAt = 0;
  lastPrintDataAt = 0;
  nozzleSyncRequests = 0;
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

bool primeSelectedPrintFromFleet(int8_t profileIndex) {
  if (profileIndex < 0 || profileIndex >= FLEET_PRINTER_COUNT) return false;
  const FleetRuntime &cached = fleetRuntimes[profileIndex];
  if (!cached.online || !isActivePrintState(cached.state)) return false;

  // The selected MQTT connection is rebuilt during a profile switch. If this
  // printer was already monitored in the background, expose its last known
  // active state immediately instead of showing IDLE until the next pushall.
  // The following primary MQTT packet replaces this provisional layer/percent
  // data with the printer's authoritative values.
  printState = cached.state;
  printState.toUpperCase();
  printPercent = constrain(cached.percent, 0, 100);
  currentStage = printState == "RUNNING" ? 0 : -1;
  currentLayer = 0;
  totalLayers = 0;
  remainingMinutes = -1;
  statusDataSeen = true;
  printWasRunning = true;
  lastMqttMessageAt = millis();
  return true;
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

String fleetPreferenceKey(uint8_t index, const char *suffix) {
  return String("f") + index + suffix;
}

void loadFleetProfiles() {
  for (uint8_t i = 0; i < FLEET_PRINTER_COUNT; ++i) {
    const String legacyKind = i == 0 ? "A1" : i == 1 ? "H2D" : i == 2 ? "P2S" : "";
    fleetProfiles[i].kind = preferences.getString(
        fleetPreferenceKey(i, "kind").c_str(), legacyKind);
    fleetProfiles[i].printerIp =
        preferences.getString(fleetPreferenceKey(i, "ip").c_str(), "");
    fleetProfiles[i].printerSerial =
        preferences.getString(fleetPreferenceKey(i, "ser").c_str(), "");
    fleetProfiles[i].accessCode =
        preferences.getString(fleetPreferenceKey(i, "acc").c_str(), "");
  }
}

bool saveFleetProfile(uint8_t index, const FleetProfile &profile) {
  if (index >= FLEET_PRINTER_COUNT || !profile.complete()) return false;
  const bool changed = fleetProfiles[index].printerIp != profile.printerIp ||
                       fleetProfiles[index].kind != profile.kind ||
                       fleetProfiles[index].printerSerial !=
                           profile.printerSerial ||
                       fleetProfiles[index].accessCode != profile.accessCode;
  const bool wrote =
      preferences.putString(fleetPreferenceKey(index, "kind").c_str(),
                            profile.kind) == profile.kind.length() &&
      preferences.putString(fleetPreferenceKey(index, "ip").c_str(),
                            profile.printerIp) == profile.printerIp.length() &&
      preferences.putString(fleetPreferenceKey(index, "ser").c_str(),
                            profile.printerSerial) ==
          profile.printerSerial.length() &&
      preferences.putString(fleetPreferenceKey(index, "acc").c_str(),
                            profile.accessCode) == profile.accessCode.length();
  if (!wrote) return false;
  if (changed) fleetRuntimes[index] = FleetRuntime();
  fleetProfiles[index] = profile;
  reportFleetStatus(index, true);
  return true;
}

void clearFleetProfile(uint8_t index) {
  if (index >= FLEET_PRINTER_COUNT) return;
  preferences.remove(fleetPreferenceKey(index, "kind").c_str());
  preferences.remove(fleetPreferenceKey(index, "ip").c_str());
  preferences.remove(fleetPreferenceKey(index, "ser").c_str());
  preferences.remove(fleetPreferenceKey(index, "acc").c_str());
  fleetProfiles[index].kind = "";
  fleetProfiles[index].printerIp = "";
  fleetProfiles[index].printerSerial = "";
  fleetProfiles[index].accessCode = "";
  fleetRuntimes[index] = FleetRuntime();
  reportFleetStatus(index, true);
}

void loadSettings() {
  preferences.begin("se-h2d-tl", false);
  settings.wifiSsid = preferences.getString("ssid", "");
  settings.wifiPassword = preferences.getString("wifiPass", "");
  settings.printerIp = preferences.getString("printerIp", "");
  settings.printerSerial = preferences.getString("serial", "");
  settings.accessCode = preferences.getString("access", "");
  buzzerEnabled = preferences.getBool("buzzer", true);
  buzzerVolumePercent = preferences.getUChar("buzzVol", 100);
  ledBrightnessPercent = preferences.getUChar(
      "ledLevel", Config::LED_DEFAULT_BRIGHTNESS_PERCENT);
  pendingSettings = settings;
  loadFleetProfiles();
  selectedFleetIndex = fleetIndexForSerial(settings.printerSerial);
  if (settings.complete() && selectedFleetIndex >= 0 &&
      !fleetProfiles[selectedFleetIndex].complete()) {
    FleetProfile migrated;
    migrated.kind = printerModelFromSerial(settings.printerSerial);
    migrated.printerIp = settings.printerIp;
    migrated.printerSerial = settings.printerSerial;
    migrated.accessCode = settings.accessCode;
    saveFleetProfile(selectedFleetIndex, migrated);
  }
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
  selectedFleetIndex = fleetIndexForSerial(settings.printerSerial);
  if (selectedFleetIndex >= 0) {
    FleetProfile selected;
    selected.kind = printerModelFromSerial(settings.printerSerial);
    selected.printerIp = settings.printerIp;
    selected.printerSerial = settings.printerSerial;
    selected.accessCode = settings.accessCode;
    if (!saveFleetProfile(selectedFleetIndex, selected)) return false;
  }
  return true;
}

bool findKey(const uint8_t *payload, size_t length, const char *key,
             size_t start, size_t &valuePosition) {
  if (payload == nullptr || key == nullptr) return false;
  const size_t keyLength = strlen(key);
  const size_t patternLength = keyLength + 2;
  if (length < patternLength || start >= length) return false;
  // Do not allocate a temporary Arduino String for every search. With the
  // 49-KB Bambu pushall packet and BLE active, those tiny repeated allocations
  // could fragment the remaining heap and leave memcmp with an invalid pattern
  // pointer, rebooting the bridge just as the phone entered capture mode.
  for (size_t i = start; i <= length - patternLength; ++i) {
    if (payload[i] != '"' || payload[i + keyLength + 1] != '"') continue;
    bool matches = true;
    for (size_t character = 0; character < keyLength; ++character) {
      if (payload[i + character + 1] != static_cast<uint8_t>(key[character])) {
        matches = false;
        break;
      }
    }
    if (!matches) continue;
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
  // the low 16 bits. Verified on the physical H2D: extruder id 0 is the right
  // hotend and id 1 is the left hotend. Keep that physical mapping here before
  // sending telemetry to the matching labels in the iPhone app.
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
  uint8_t entryIndex = 0;
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
    const bool hasExplicitId = extractLastJsonInt(object, objectLength, "id", id);
    // Normal H2D pushall packets include id 0/1. Some incremental firmware
    // packets omit id but preserve the documented two-entry order, so retain
    // that order as a fallback instead of dropping the left nozzle entirely.
    if (!hasExplicitId && entryIndex < 2) id = entryIndex;
    if (extractLastJsonUInt32(object, objectLength, "temp", packed) &&
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
    ++entryIndex;
    cursor = objectEnd;
  }
  if (nozzleTemperature >= 0 && leftNozzleTemperature >= 0) {
    nozzleSyncRequests = Config::NOZZLE_SYNC_RETRY_LIMIT;
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

bool extractMaterialFromTrayIndex(const uint8_t *payload, size_t length,
                                  int trayIndex, String &type) {
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
      parsedType.trim();
      if (parsedType.isEmpty()) {
        extractJsonString(ams + localStart, localLength,
                          "tray_info_idx", parsedType);
        parsedType.trim();
      }
      if (parsedType.isEmpty()) return false;
      type = parsedType;
      return true;
    }
    ++seen;
    searchFrom = valuePosition;
  }
  return false;
}

bool extractExternalMaterial(const uint8_t *payload, size_t length,
                             String &type) {
  size_t start = 0;
  size_t end = 0;
  if (!findObjectRangeAfterKey(payload, length, "vt_tray", start, end)) return false;
  String parsedType;
  if (!extractJsonString(payload + start, end - start, "tray_type", parsedType)) {
    extractJsonString(payload + start, end - start, "tray_sub_brands", parsedType);
  }
  if (parsedType.isEmpty()) {
    extractJsonString(payload + start, end - start, "tray_info_idx", parsedType);
  }
  parsedType.trim();
  if (parsedType.isEmpty()) return false;
  type = parsedType;
  return true;
}

int materialCacheIndex(int trayIndex) {
  if (trayIndex >= 0 && trayIndex < 16) return trayIndex;
  if (trayIndex == 254) return 16;
  return -1;
}

void cacheMaterial(int trayIndex, const String &type) {
  const int index = materialCacheIndex(trayIndex);
  if (index < 0 || type.isEmpty()) return;
  cachedFilamentType[index] = type;
}

bool readCachedMaterial(int trayIndex, String &type) {
  const int index = materialCacheIndex(trayIndex);
  if (index < 0 || cachedFilamentType[index].isEmpty()) return false;
  type = cachedFilamentType[index];
  return true;
}

void refreshMaterialCache(const uint8_t *payload, size_t length) {
  // Full pushall packets contain all AMS trays. Cache them once so small MQTT
  // updates that only change tray_now can still switch the UI immediately to
  // the real filament type currently feeding the nozzle.
  size_t amsStart = 0;
  size_t amsEnd = 0;
  if (findObjectRangeAfterKey(payload, length, "ams", amsStart, amsEnd)) {
    for (int tray = 0; tray < 16; ++tray) {
      String type;
      if (extractMaterialFromTrayIndex(payload, length, tray, type)) {
        cacheMaterial(tray, type);
      }
    }
  }
  String externalType;
  if (extractExternalMaterial(payload, length, externalType)) {
    cacheMaterial(254, externalType);
  }
}

void updateActiveMaterial(const uint8_t *payload, size_t length) {
  refreshMaterialCache(payload, length);
  int trayNow = 255;
  const bool hasTrayNow = extractLastJsonInt(payload, length, "tray_now", trayNow);
  if ((!hasTrayNow || trayNow == 255 || trayNow < 0) &&
      activeFilamentSlot >= 0) {
    // During a tool/filament transition Bambu briefly reports no current tray.
    // Keep the last truly active material instead of jumping early to tray_tar.
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
  bool found = readCachedMaterial(trayNow, type);
  if (!found) {
    found = trayNow == 254
        ? extractExternalMaterial(payload, length, type)
        : trayNow >= 0 && trayNow < 254 &&
              extractMaterialFromTrayIndex(payload, length, trayNow, type);
    if (found) cacheMaterial(trayNow, type);
  }
  // A1/P2S without AMS can report tray_now=255 while idle even though the
  // external virtual tray already contains the selected material. Use that
  // data as a safe fallback; when printing, tray_now=254 takes precedence.
  if (!found && (trayNow == 255 || trayNow < 0)) {
    found = readCachedMaterial(254, type) ||
            extractExternalMaterial(payload, length, type);
    if (found) trayNow = 254;
  }
  if (!found) return;
  if (type == activeFilamentType && trayNow == activeFilamentSlot) return;
  activeFilamentType = type;
  activeFilamentSlot = trayNow;
  materialSyncRequests = Config::MATERIAL_SYNC_RETRY_LIMIT;
  reportMaterial();
  Serial.printf("[MATERIAL] %s slot=%d\n", activeFilamentType.c_str(),
                activeFilamentSlot);
}

bool isExplicitlyStoppedState() {
  return printState == "STOP" || printState == "STOPPED" ||
         printState == "CANCEL" || printState == "CANCELED" ||
         printState == "CANCELLED";
}

bool isPausedState() {
  return printState == "PAUSE" || printState == "PAUSED";
}

bool hasCriticalPrinterError() {
  // Bambu can publish FAILED when the operator deliberately cancels a job.
  // A bare FAILED state is therefore not an alarm: require a real non-zero
  // print_error. ERROR remains critical by itself. Explicit stop/cancel wins
  // even if an older incremental packet left a stale error code in memory.
  if (isExplicitlyStoppedState()) return false;
  return criticalAlarmLatched;
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
  const bool critical = hasCriticalPrinterError();
  const bool active = critical ||
                      (!isExplicitlyStoppedState() && printContext &&
                       hmsAlertActive);
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
      // secondary information; only a real print_error/ERROR may turn the
      // Island red. A user-cancelled job stays silent.
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

void sendSnapshot(int layer, bool isLayerTransition = true) {
  if (!timelapseArmed || layer <= 0 || layer <= lastSnapLayer) return;
  lastSnapLayer = layer;
  captureFlashUntil = millis() + 650;
  queuePhoneEvent(String("H2D,SNAP,") + layer + "," +
                  max(layer, totalLayers) + "," + activeJob + "," +
                  (isLayerTransition ? "LAYER" : "FINAL"));
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
                        int newPercent, int newStage, int newRemainingMinutes,
                        const String &jobToken) {
  const String previousState = printState;
  const bool wasActiveSession = isActivePrintState(previousState);
  const bool wasRunning = printWasRunning;
  if (!newState.isEmpty()) {
    printState = newState;
    printState.toUpperCase();
  }
  if (newLayer >= 0) currentLayer = newLayer;
  if (newTotal >= 0) totalLayers = newTotal;
  if (newPercent >= 0) printPercent = constrain(newPercent, 0, 100);
  if (newStage != -999) currentStage = newStage;
  if (newRemainingMinutes >= 0) remainingMinutes = newRemainingMinutes;

  // A real preparation/running state means a new print command has arrived,
  // so the previous job's three-hour blue completion indication ends now.
  if (isActivePrintState(printState)) {
    printCompleteBlueUntil = 0;
    // Beep only at a genuine new-job start. Transient RUNNING/PAUSE/PREPARE
    // packets during a layer transition must never produce a standby beep.
    if (!wasActiveSession && !wasRunning) {
      requestBuzzerBeep(80);
    }
  }

  // PREPARE may already report layer 0/1 while the bed is heating. Baseline
  // only on the first real RUNNING packet, otherwise layer 1 is photographed
  // before it has actually finished.
  const bool stateRunning = printState == "RUNNING";
  const bool layerAdvanced =
      currentLayer > 0 && currentLayer > lastObservedLayer;
  const bool actualLayerPrinting =
      stateRunning &&
      (currentStage == 0 || currentStage == -1 || layerAdvanced ||
       (currentLayer > 0 && printPercent > 0));
  if (actualLayerPrinting) {
    if (!wasRunning || (jobToken != "0" && jobToken != activeJob)) {
      resetForNewPrint(jobToken, currentLayer);
    } else if (currentLayer > lastObservedLayer) {
      // Never guess the duration of the next layer: its geometry can make it
      // several seconds shorter or longer than the previous one. The iPhone
      // keeps seven preview frames 0.15 s apart and, at this confirmed
      // transition, saves the least-obstructed pre-transition frame from that
      // rolling 0.9-second window.
      const int lastCompletedLayer = currentLayer - 1;
      sendSnapshot(lastCompletedLayer, true);
      lastObservedLayer = currentLayer;
    }
    printWasRunning = true;
  }

  if (isCompletedPrintState(printState) &&
      (wasRunning || previousState == "RUNNING") &&
      !finishSent) {
    const int finalLayer = max(max(currentLayer, totalLayers), lastObservedLayer);
    sendSnapshot(finalLayer, false);
    queuePhoneEvent(String("H2D,DONE,") + finalLayer + "," +
                    max(finalLayer, totalLayers) + "," + activeJob);
    finishSent = true;
    printWasRunning = false;
    printCompleteBlueUntil = millis() + Config::PRINT_COMPLETE_BLUE_MS;
    requestBuzzerBeep(240);
    Serial.printf("[PRINT] finished at layer %d\n", finalLayer);
  } else if (printState == "FAILED" || printState == "ERROR" ||
             printState == "IDLE" || printState == "STOP" ||
             printState == "STOPPED" || printState == "CANCEL" ||
             printState == "CANCELED" ||
             printState == "CANCELLED" || printState == "FINISH" ||
             printState == "COMPLETE" || printState == "COMPLETED") {
    printWasRunning = false;
  }
  reportPrintStatus(true);
}

void onMqttMessage(char *topic, uint8_t *payload, unsigned int length) {
  const bool firstStatusPacket = !statusDataSeen;
  lastMqttMessageAt = millis();
  const String previousStateForAlarm = printState;
  const uint32_t previousPrintError = printErrorCode;
  const auto selectedAlarmAlreadyAcknowledged = [&](uint32_t code) {
    if (selectedFleetIndex < 0 || selectedFleetIndex >= FLEET_PRINTER_COUNT) {
      return physicalCriticalAcknowledged;
    }
    const FleetRuntime &cached = fleetRuntimes[selectedFleetIndex];
    return cached.physicalAlarmAcknowledged &&
           (code == 0 || cached.printErrorCode == code);
  };
  int layer = -1;
  int total = -1;
  int percent = -1;
  int stage = -999;
  int remaining = -1;
  uint32_t incomingPrintError = 0;
  bool incomingHmsAlert = false;
  String state;
  String job;
  const bool hasLayer = extractLastJsonInt(payload, length, "layer_num", layer);
  const bool hasTotal =
      extractLastJsonInt(payload, length, "total_layer_num", total);
  const bool hasPercent = extractLastJsonInt(payload, length, "mc_percent", percent);
  const bool hasStage = extractLastJsonInt(payload, length, "stg_cur", stage);
  const bool hasRemaining =
      extractLastJsonInt(payload, length, "mc_remaining_time", remaining);
  const bool hasPrintError =
      extractLastJsonUInt32(payload, length, "print_error", incomingPrintError);
  const bool hasHms =
      extractJsonArrayHasItems(payload, length, "hms", incomingHmsAlert);
  const bool hasState =
      extractLastJsonString(payload, length, "gcode_state", state);
  bool hasJob = extractJsonString(payload, length, "job_id", job);
  if (!hasJob) hasJob = extractJsonString(payload, length, "subtask_id", job);

  if (hasLayer || hasTotal || hasPercent || hasStage || hasRemaining || hasState ||
      hasPrintError || hasHms) {
    statusDataSeen = true;
    lastPrintDataAt = millis();
    if (firstStatusPacket) {
      Serial.printf("[MQTT] first printer status packet: %u bytes, state=%s, "
                    "layer=%d/%d, percent=%d\n",
                    length, hasState ? state.c_str() : "-", hasLayer ? layer : -1,
                    hasTotal ? total : -1, hasPercent ? percent : -1);
    }
  }
  if (hasLayer || hasTotal || hasPercent || hasStage || hasRemaining || hasState) {
    processPrintUpdate(hasState ? state : "", hasLayer ? layer : -1,
                       hasTotal ? total : -1, hasPercent ? percent : -1,
                       hasStage ? stage : -999,
                       hasRemaining ? remaining : -1,
                       hasJob ? safeJobID(job) : activeJob);
  }
  if (hasPrintError) {
    printErrorCode = incomingPrintError;
    printErrorActive = incomingPrintError != 0;
    if (incomingPrintError == 0) {
      // A zero error code is the printer's acknowledgement/clear signal.
      criticalAlarmLatched = false;
      physicalCriticalAcknowledged = false;
    } else if (isActivePrintState(printState) || printState == "FAILED" ||
               printState == "ERROR") {
      // Ignore old error codes contained in an idle pushall packet, but once a
      // real job fault is seen keep the alarm latched until the printer clears it.
      criticalAlarmLatched = true;
      if (incomingPrintError != previousPrintError &&
          !selectedAlarmAlreadyAcknowledged(incomingPrintError)) {
        physicalCriticalAcknowledged = false;
      }
    }
  }
  if (hasState && printState == "ERROR") {
    criticalAlarmLatched = true;
    if (previousStateForAlarm != "ERROR" &&
        !selectedAlarmAlreadyAcknowledged(printErrorCode)) {
      physicalCriticalAcknowledged = false;
    }
  }
  if (hasState && isExplicitlyStoppedState()) {
    criticalAlarmLatched = false;
    physicalCriticalAcknowledged = false;
  }
  if (hasHms) hmsAlertActive = incomingHmsAlert;
  updateActiveMaterial(payload, length);
  updatePrinterTelemetry(payload, length);
  // A state transition to IDLE must clear a previously active warning even
  // when that incremental packet does not contain hms/print_error fields.
  if (hasPrintError || hasHms || hasState) reportPrinterAlert();
  syncSelectedFleetRuntime();
}

void processFleetMqttMessageForProfile(int8_t profileIndex, uint8_t *payload,
                                       unsigned int length) {
  if (profileIndex < 0 || profileIndex >= FLEET_PRINTER_COUNT) return;
  FleetRuntime &runtime = fleetRuntimes[profileIndex];
  const String previousState = runtime.state;
  const bool wasActiveSession = isActivePrintState(previousState);
  const bool wasCritical = runtime.criticalLatched;
  const uint32_t previousError = runtime.printErrorCode;
  String state;
  int percent = -1;
  uint32_t incomingError = 0;
  const bool hasState = extractLastJsonString(payload, length, "gcode_state", state);
  const bool hasPercent =
      extractLastJsonInt(payload, length, "mc_percent", percent);
  const bool hasPrintError =
      extractLastJsonUInt32(payload, length, "print_error", incomingError);
  if (!hasState && !hasPercent && !hasPrintError) return;

  runtime.online = true;
  runtime.lastMessageAt = millis();
  runtime.lastReachableAt = runtime.lastMessageAt;
  runtime.consecutiveProbeFailures = 0;
  if (hasState) {
    state.trim();
    state.toUpperCase();
    runtime.state = state;
    if (state == "ERROR") {
      runtime.criticalLatched = true;
      // Preserve a physical acknowledgement while the same incident remains
      // latched. Some printers alternate ERROR/PREPARE status packets during
      // recovery; re-arming on every state oscillation made the strip jump
      // continuously between red and yellow.
      if (!wasCritical) runtime.physicalAlarmAcknowledged = false;
    }
    if (isStoppedPrintState(state)) {
      runtime.criticalLatched = false;
      runtime.physicalAlarmAcknowledged = false;
    }
  }
  if (hasPercent) runtime.percent = constrain(percent, 0, 100);
  if (hasPrintError) {
    runtime.printErrorCode = incomingError;
    runtime.printErrorActive = incomingError != 0;
    if (incomingError == 0) {
      runtime.criticalLatched = false;
      runtime.physicalAlarmAcknowledged = false;
    } else if (isActivePrintState(runtime.state) || runtime.state == "FAILED" ||
               runtime.state == "ERROR") {
      runtime.criticalLatched = true;
      if (incomingError != previousError) {
        runtime.physicalAlarmAcknowledged = false;
      }
    }
  }
  if (hasState && isActivePrintState(runtime.state) && !wasActiveSession) {
    // A background printer may be discovered a few seconds after it started,
    // so its first observed percentage is sometimes already above 1%.
    // The IDLE -> active edge is the reliable one-shot signal; do not require
    // an early percentage or non-selected printers can begin silently.
    requestBuzzerBeep(80);
  }
  if (hasState && isCompletedPrintState(runtime.state) && wasActiveSession) {
    requestBuzzerBeep(240);
  }
  if (wasCritical != runtime.criticalLatched ||
      (hasPrintError && incomingError != previousError)) {
    Serial.printf("[FLEET] %s critical=%d error=0x%08lX state=%s\n",
                  fleetProfiles[profileIndex].kind.c_str(),
                  runtime.criticalLatched ? 1 : 0,
                  static_cast<unsigned long>(runtime.printErrorCode),
                  runtime.state.c_str());
  }
  // The very first complete packet owns this background sample. Publish it to
  // the phone immediately, then let maintainFleetMonitors close the scanner
  // and restore the selected printer on the next loop iteration.
  Serial.printf("[FLEET] sampled %s: %u bytes, state=%s, percent=%d\n",
                fleetProfiles[profileIndex].kind.c_str(), length,
                runtime.state.c_str(), runtime.percent);
  fleetSampleReceived = true;
  reportFleetStatus(profileIndex, true);
}

void onFleetMqtt(char *, uint8_t *payload, unsigned int length) {
  processFleetMqttMessageForProfile(activeFleetProfileIndex, payload, length);
}

void publishFleetStatusRequest(uint8_t slot) {
  if (slot >= BACKGROUND_MONITOR_COUNT) return;
  const int8_t profileIndex = monitorProfileIndex[slot];
  if (profileIndex < 0 || profileIndex >= FLEET_PRINTER_COUNT) return;
  PubSubClient &client = fleetMqtt;
  if (!fleetRuntimes[profileIndex].online) return;
  const FleetProfile &profile = fleetProfiles[profileIndex];
  const String topic = "device/" + profile.printerSerial + "/request";
  const String pushAll = String("{\"pushing\":{\"sequence_id\":\"") +
                         ++monitorSequenceId[slot] +
                         "\",\"command\":\"pushall\",\"version\":1,"
                         "\"push_target\":1}}";
  client.publish(topic.c_str(), pushAll.c_str());
}

void refreshFleetMonitorAssignments() {
  int8_t desired[BACKGROUND_MONITOR_COUNT] = {-1, -1};
  uint8_t count = 0;
  bool assignmentsChanged = false;
  for (uint8_t i = 0; i < FLEET_PRINTER_COUNT && count < BACKGROUND_MONITOR_COUNT;
       ++i) {
    if (static_cast<int8_t>(i) == selectedFleetIndex ||
        !fleetProfiles[i].complete()) {
      continue;
    }
    desired[count++] = i;
  }

  for (uint8_t slot = 0; slot < BACKGROUND_MONITOR_COUNT; ++slot) {
    if (monitorProfileIndex[slot] == desired[slot]) continue;
    assignmentsChanged = true;
    // Reassigning a polling socket is deliberate and says nothing about the
    // printer's power state. Preserve the last confirmed status; the separate
    // reachability sweep will turn it black only after repeated failures.
    if (activeFleetMonitorSlot == static_cast<int8_t>(slot)) {
      if (fleetMqtt.connected()) fleetMqtt.disconnect();
      fleetMqtt.setBufferSize(Config::MQTT_CONNECT_BUFFER_BYTES);
      activeFleetMonitorSlot = -1;
      activeFleetProfileIndex = -1;
      fleetSampleReceived = false;
    }
    monitorProfileIndex[slot] = desired[slot];
    monitorLastAttemptAt[slot] = 0;
  }
  if (assignmentsChanged) {
    activeFleetMonitorSlot = -1;
    activeFleetMonitorSince = 0;
    fleetSampleReceived = false;
    fleetRefreshInProgress = false;
    fleetRefreshRequested = true;
    fleetMonitorCursor = 0;
  }
}

void disconnectFleetMonitors(bool markOffline = true) {
  if (fleetMqtt.connected()) fleetMqtt.disconnect();
  fleetMqtt.setBufferSize(Config::MQTT_CONNECT_BUFFER_BYTES);
  for (uint8_t slot = 0; slot < BACKGROUND_MONITOR_COUNT; ++slot) {
    const int8_t profileIndex = monitorProfileIndex[slot];
    if (markOffline && profileIndex >= 0 &&
        profileIndex < FLEET_PRINTER_COUNT) {
      fleetRuntimes[profileIndex].online = false;
      fleetRuntimes[profileIndex].state = "OFFLINE";
      reportFleetStatus(profileIndex, true);
    }
    monitorLastAttemptAt[slot] = 0;
  }
  activeFleetMonitorSlot = -1;
  activeFleetProfileIndex = -1;
  activeFleetMonitorSince = 0;
  fleetSampleReceived = false;
}

void pauseSelectedMqttForFleetScan() {
  if (fleetPrimaryPaused) return;
  Serial.printf("[FLEET] pausing selected %s for fast background scan\n",
                printerModelFromSerial(settings.printerSerial).c_str());
  if (mqtt.connected()) mqtt.disconnect();
  tlsClient.stop();
  mqtt.setBufferSize(Config::MQTT_CONNECT_BUFFER_BYTES);
  mqttWasConnected = false;
  fleetPrimaryPaused = true;
  consecutiveStatusPublishFailures = 0;
}

void resumeSelectedMqttAfterFleetScan() {
  if (!fleetPrimaryPaused) return;
  if (fleetMqtt.connected()) fleetMqtt.disconnect();
  fleetTls.stop();
  fleetMqtt.setBufferSize(Config::MQTT_CONNECT_BUFFER_BYTES);
  fleetPrimaryPaused = false;
  lastMqttAttemptAt = 0;
  lastStatusRequestAt = 0;
  statusRequestPending = false;
  Serial.printf("[FLEET] returning to selected %s\n",
                printerModelFromSerial(settings.printerSerial).c_str());
}

bool startFleetMonitor(uint8_t slot) {
  if (slot >= BACKGROUND_MONITOR_COUNT) return false;
  const int8_t profileIndex = monitorProfileIndex[slot];
  if (profileIndex < 0 || profileIndex >= FLEET_PRINTER_COUNT) return false;
  const FleetProfile &profile = fleetProfiles[profileIndex];
  if (!profile.complete() || !fleetRuntimes[profileIndex].online) return false;

  // Release the selected TLS session before opening the scanner. Merely
  // shrinking its MQTT buffer is not sufficient: mbedTLS still owns enough
  // heap to make a 24-KB background pushall allocation fail.
  pauseSelectedMqttForFleetScan();
  PubSubClient &client = fleetMqtt;
  fleetSampleReceived = false;
  client.setServer(profile.printerIp.c_str(), Config::MQTT_PORT);
  client.setBufferSize(Config::MQTT_CONNECT_BUFFER_BYTES);
  const uint64_t chip = ESP.getEfuseMac();
  char clientId[40];
  snprintf(clientId, sizeof(clientId), "SE-Fleet-%u-%08lX-%lu", slot,
           static_cast<unsigned long>(chip & 0xFFFFFFFF),
           static_cast<unsigned long>(++monitorSequenceId[slot]));
  Serial.printf("[FLEET] sampling %s MQTT at %s\n", profile.kind.c_str(),
                profile.printerIp.c_str());
  if (!client.connect(clientId, "bblp", profile.accessCode.c_str())) {
    Serial.printf("[FLEET] %s MQTT sample failed, state=%d, heap=%u\n",
                  profile.kind.c_str(), client.state(), ESP.getFreeHeap());
    client.disconnect();
    client.setBufferSize(Config::MQTT_CONNECT_BUFFER_BYTES);
    activeFleetProfileIndex = -1;
    return false;
  }
  const String reportTopic = "device/" + profile.printerSerial + "/report";
  if (!client.subscribe(reportTopic.c_str(), 0)) {
    Serial.printf("[FLEET] %s sample subscribe failed\n", profile.kind.c_str());
    client.disconnect();
    client.setBufferSize(Config::MQTT_CONNECT_BUFFER_BYTES);
    activeFleetProfileIndex = -1;
    return false;
  }
  activeFleetMonitorSlot = slot;
  activeFleetProfileIndex = profileIndex;
  activeFleetMonitorSince = millis();
  // Subscribe and publish while the buffer is still small so TLS has enough
  // contiguous heap for outgoing records. No incoming packet is processed
  // until client.loop(), after the receive buffer is expanded below.
  publishFleetStatusRequest(slot);
  if (!client.setBufferSize(Config::FLEET_MQTT_BUFFER_BYTES) &&
      !client.setBufferSize(Config::FLEET_MQTT_FALLBACK_BUFFER_BYTES) &&
      !client.setBufferSize(22528)) {
    Serial.printf("[FLEET] %s cannot allocate full status buffer\n",
                  profile.kind.c_str());
    client.disconnect();
    client.setBufferSize(Config::MQTT_CONNECT_BUFFER_BYTES);
    activeFleetMonitorSlot = -1;
    activeFleetProfileIndex = -1;
    return false;
  }
  return true;
}

void markFleetReachable(uint8_t profileIndex, uint32_t now) {
  if (profileIndex >= FLEET_PRINTER_COUNT) return;
  FleetRuntime &runtime = fleetRuntimes[profileIndex];
  const bool changed = !runtime.online;
  runtime.online = true;
  runtime.lastReachableAt = now;
  runtime.consecutiveProbeFailures = 0;
  if (runtime.state == "OFFLINE" || runtime.state.isEmpty()) {
    runtime.state = "IDLE";
  }
  if (changed) {
    Serial.printf("[FLEET] %s reachable at %s\n",
                  fleetProfiles[profileIndex].kind.c_str(),
                  fleetProfiles[profileIndex].printerIp.c_str());
  }
  reportFleetStatus(profileIndex, changed);
}

void maintainFleetReachability() {
  const uint32_t now = millis();
  if (now - lastFleetProbeAt < Config::FLEET_PROBE_PERIOD_MS) return;
  lastFleetProbeAt = now;

  if (WiFi.status() != WL_CONNECTED) {
    for (uint8_t i = 0; i < FLEET_PRINTER_COUNT; ++i) {
      if (!fleetRuntimes[i].online) continue;
      fleetRuntimes[i].online = false;
      fleetRuntimes[i].state = "OFFLINE";
      reportFleetStatus(i, true);
    }
    return;
  }

  uint8_t profileIndex = nextFleetProbeIndex;
  bool found = false;
  for (uint8_t attempt = 0; attempt < FLEET_PRINTER_COUNT; ++attempt) {
    profileIndex = (nextFleetProbeIndex + attempt) % FLEET_PRINTER_COUNT;
    if (fleetProfiles[profileIndex].complete()) {
      found = true;
      nextFleetProbeIndex = (profileIndex + 1) % FLEET_PRINTER_COUNT;
      break;
    }
  }
  if (!found) return;

  // The selected MQTT connection itself is stronger proof of reachability and
  // avoids opening a redundant socket to that printer.
  if (static_cast<int8_t>(profileIndex) == selectedFleetIndex &&
      mqttWasConnected) {
    markFleetReachable(profileIndex, now);
    return;
  }

  IPAddress address;
  if (!address.fromString(fleetProfiles[profileIndex].printerIp)) return;
  fleetProbeClient.stop();
  const bool reachable = fleetProbeClient.connect(
      address, Config::MQTT_PORT, Config::FLEET_PROBE_TIMEOUT_MS);
  fleetProbeClient.stop();
  FleetRuntime &runtime = fleetRuntimes[profileIndex];
  if (reachable) {
    markFleetReachable(profileIndex, now);
    return;
  }

  if (runtime.consecutiveProbeFailures < 255) {
    ++runtime.consecutiveProbeFailures;
  }
  const bool graceExpired = runtime.lastReachableAt == 0 ||
                            now - runtime.lastReachableAt >=
                                Config::FLEET_ONLINE_GRACE_MS;
  if (runtime.online && graceExpired &&
      runtime.consecutiveProbeFailures >= Config::FLEET_OFFLINE_FAILURES) {
    runtime.online = false;
    runtime.state = "OFFLINE";
    runtime.percent = 0;
    Serial.printf("[FLEET] %s offline after %u probes\n",
                  fleetProfiles[profileIndex].kind.c_str(),
                  runtime.consecutiveProbeFailures);
    reportFleetStatus(profileIndex, true);
  }
}

void maintainFleetMonitors() {
  refreshFleetMonitorAssignments();
  const uint32_t now = millis();
  // The selected printer owns the primary TLS session and all timelapse layer
  // transitions.  Do not start a second TLS handshake until the first valid
  // selected-printer packet has arrived; this prevents a large H2D pushall
  // from being starved by background monitoring during startup/reconnect.
  const bool selectedReady = mqttWasConnected && statusDataSeen;
  const bool configurationQuiet =
      lastConfigurationCommandAt != 0 &&
      now - lastConfigurationCommandAt < Config::CONFIG_NETWORK_QUIET_MS;
  if (WiFi.status() != WL_CONNECTED || configurationQuiet ||
      (!fleetPrimaryPaused && !fleetRefreshInProgress && !selectedReady)) {
    if (activeFleetMonitorSlot >= 0) {
      disconnectFleetMonitors(false);
    }
    fleetRefreshInProgress = false;
    resumeSelectedMqttAfterFleetScan();
    return;
  }

  if (activeFleetMonitorSlot >= 0) {
    PubSubClient &client = fleetMqtt;
    const bool sessionAlive = client.connected() && client.loop();
    if (sessionAlive && !fleetSampleReceived &&
        now - activeFleetMonitorSince < Config::FLEET_MONITOR_DWELL_MS) {
      return;
    }
    const uint8_t completedSlot = activeFleetMonitorSlot;
    client.disconnect();
    client.setBufferSize(Config::MQTT_CONNECT_BUFFER_BYTES);
    activeFleetMonitorSlot = -1;
    activeFleetProfileIndex = -1;
    fleetSampleReceived = false;
    activeFleetMonitorSince = 0;
    ++fleetSamplesThisRefresh;
    // fleetMonitorCursor is the offset from the pass's starting slot. Keep
    // nextFleetMonitorSlot unchanged until the entire pass ends; updating both
    // values here would select the same background printer twice.
    if (fleetSamplesThisRefresh >= Config::FLEET_SAMPLES_PER_REFRESH) {
      fleetMonitorCursor = BACKGROUND_MONITOR_COUNT;
    } else {
      ++fleetMonitorCursor;
    }
    nextFleetMonitorAttemptAt = now + Config::FLEET_MONITOR_RETRY_GAP_MS;
  }

  if (!fleetRefreshInProgress) {
    if (!fleetRefreshRequested && lastFleetRefreshAt != 0 &&
        now - lastFleetRefreshAt < Config::FLEET_REFRESH_PERIOD_MS) {
      return;
    }
    fleetRefreshRequested = false;
    fleetRefreshInProgress = true;
    // Measure the refresh period from the start of the scan, not its end. This
    // prevents the TLS handshake/dwell time from being added to every cycle
    // and keeps the start-event latency bounded and predictable.
    lastFleetRefreshAt = now;
    fleetMonitorCursor = 0;
    fleetSamplesThisRefresh = 0;
    nextFleetMonitorAttemptAt = now;
  }

  if (fleetMonitorCursor >= BACKGROUND_MONITOR_COUNT) {
    fleetRefreshInProgress = false;
    // Rotate which background printer is sampled first on the next pass while
    // always returning MQTT to the user's currently selected profile below.
    nextFleetMonitorSlot =
        (nextFleetMonitorSlot + 1) % BACKGROUND_MONITOR_COUNT;
    for (uint8_t i = 0; i < FLEET_PRINTER_COUNT; ++i) {
      reportFleetStatus(i, true);
    }
    resumeSelectedMqttAfterFleetScan();
    return;
  }
  if (static_cast<int32_t>(nextFleetMonitorAttemptAt - now) > 0) return;

  const uint8_t slot =
      (nextFleetMonitorSlot + fleetMonitorCursor) %
      BACKGROUND_MONITOR_COUNT;
  if (!startFleetMonitor(slot)) {
    ++fleetMonitorCursor;
    nextFleetMonitorAttemptAt = millis() + Config::FLEET_MONITOR_RETRY_GAP_MS;
  }
}

bool expandSelectedMqttReceiveBuffer() {
  if (mqtt.setBufferSize(Config::MQTT_BUFFER_BYTES)) return true;
  if (mqtt.setBufferSize(Config::MQTT_FALLBACK_BUFFER_BYTES)) {
    Serial.printf("[MQTT] using %u-byte fallback receive buffer\n",
                  Config::MQTT_FALLBACK_BUFFER_BYTES);
    return true;
  }
  if (mqtt.setBufferSize(22528)) {
    Serial.println("[MQTT] using 22528-byte emergency receive buffer");
    return true;
  }
  Serial.println("[MQTT] cannot allocate a safe selected-printer buffer");
  return false;
}

void publishStatusRequest() {
  if (!mqttWasConnected) return;
  lastStatusRequestAt = millis();
  const String topic = "device/" + settings.printerSerial + "/request";
  const String pushAll = String("{\"pushing\":{\"sequence_id\":\"") +
                         ++sequenceId +
                         "\",\"command\":\"pushall\",\"version\":1,"
                         "\"push_target\":1}}";
  // PubSubClient uses the same allocation for TX and RX. H2D needs a large RX
  // packet, while mbedTLS needs free heap to encrypt TX. Send the tiny request
  // with a tiny MQTT buffer, then grow it again before mqtt.loop() reads the
  // printer response. Keeping the large buffer during write starved TLS and
  // produced an endless CONNECTED -> CONNECTION_LOST cycle.
  mqtt.setBufferSize(Config::MQTT_CONNECT_BUFFER_BYTES);
  const bool published = mqtt.publish(topic.c_str(), pushAll.c_str());
  const bool receiveBufferReady = expandSelectedMqttReceiveBuffer();
  if (!receiveBufferReady) {
    reportStatus("BUFFER_ERROR");
    mqtt.disconnect();
    mqttWasConnected = false;
    consecutiveStatusPublishFailures = 0;
    return;
  }
  if (!published) {
    ++consecutiveStatusPublishFailures;
    // A Bambu broker can accept SUBSCRIBE and need a short settling interval
    // before accepting the first pushall. Preserve the live TLS session and
    // retry instead of reconnecting immediately; the old reconnect loop made
    // the iPhone alternate between SYNCING and "chưa bắt đầu" forever.
    Serial.printf("[MQTT] pushall deferred, state=%d, retry=%u\n", mqtt.state(),
                  consecutiveStatusPublishFailures);
    if (consecutiveStatusPublishFailures >= 3 ||
        mqtt.state() != MQTT_CONNECTED) {
      mqtt.disconnect();
      mqtt.setBufferSize(Config::MQTT_CONNECT_BUFFER_BYTES);
      mqttWasConnected = false;
      consecutiveStatusPublishFailures = 0;
    }
  } else {
    consecutiveStatusPublishFailures = 0;
  }
}

void disconnectNetwork(bool keepWifi = false) {
  if (mqttWasConnected || mqtt.connected()) {
    mqtt.disconnect();
  }
  mqtt.setBufferSize(Config::MQTT_CONNECT_BUFFER_BYTES);
  mqtt.setCallback(onMqttMessage);
  // Switching the selected profile intentionally closes sockets. Preserve the
  // last confirmed fleet state; reachability probes decide whether a printer
  // is actually powered off.
  disconnectFleetMonitors(false);
  fleetPrimaryPaused = false;
  if (!keepWifi) WiFi.disconnect(false, false);
  mqttWasConnected = false;
  statusDataSeen = false;
  lastPrintDataAt = 0;
  lastStatusRequestAt = 0;
  consecutiveStatusPublishFailures = 0;
  materialSyncRequests = 0;
  nozzleSyncRequests = 0;
  lastWifiAttemptAt = 0;
  lastMqttAttemptAt = 0;
}

void processDeferredNetworkWork() {
  // NimBLE invokes command callbacks from its host task. Never touch a
  // PubSubClient/WiFiClientSecure object from that callback while loop() may
  // be inside mqtt.loop(); serialize all network mutations here.
  if (networkResetPending) {
    networkResetPending = false;
    const bool keepWifi = keepWifiOnNetworkReset;
    keepWifiOnNetworkReset = false;
    disconnectNetwork(keepWifi);
  }
  if (fleetAssignmentsPending) {
    fleetAssignmentsPending = false;
    refreshFleetMonitorAssignments();
  }
  if (statusRequestPending && mqttWasConnected && !fleetPrimaryPaused &&
      !fleetRefreshInProgress && activeFleetMonitorSlot < 0) {
    statusRequestPending = false;
    publishStatusRequest();
  }
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
  if (lastConfigurationCommandAt != 0 &&
      millis() - lastConfigurationCommandAt < Config::CONFIG_NETWORK_QUIET_MS) {
    return;
  }
  // A fleet refresh deliberately owns the only practical TLS session.
  // Reconnecting the selected printer here would recreate the heap collision
  // that caused background profiles to remain yellow until manually selected.
  if (fleetPrimaryPaused || fleetRefreshInProgress ||
      activeFleetMonitorSlot >= 0) {
    return;
  }
  if (mqttWasConnected) {
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
    const bool nozzleTelemetryMissing =
        printerModelFromSerial(settings.printerSerial) == "H2D" &&
        (nozzleTemperature < 0 || leftNozzleTemperature < 0) &&
        nozzleSyncRequests < Config::NOZZLE_SYNC_RETRY_LIMIT;
    if ((printDataStale || materialMissing || nozzleTelemetryMissing) &&
        now - lastStatusRequestAt >= Config::STATUS_REQUEST_RETRY_MS) {
      publishStatusRequest();
      if (materialMissing) ++materialSyncRequests;
      if (nozzleTelemetryMissing) ++nozzleSyncRequests;
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
  // A fleet TLS context can consume tens of kilobytes. Release every
  // background connection before rebuilding the selected printer's 49-KB
  // receive buffer, otherwise a short H2D Wi-Fi drop leaves no contiguous
  // heap block for the next handshake.
  disconnectFleetMonitors(false);
  const uint32_t now = millis();
  if (lastMqttAttemptAt != 0 &&
      now - lastMqttAttemptAt < Config::MQTT_RETRY_MS) return;
  lastMqttAttemptAt = now;
  reportStatus("MQTT_CONNECTING");
  // The 49-KB Bambu receive buffer must not occupy the largest heap block
  // during TLS certificate/key exchange.
  mqtt.setBufferSize(Config::MQTT_CONNECT_BUFFER_BYTES);
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
  if (!mqtt.subscribe(reportTopic.c_str(), 0)) {
    Serial.printf("[MQTT] subscribe failed, state=%d; closing selected "
                  "session\n",
                  mqtt.state());
    mqtt.disconnect();
    mqtt.setBufferSize(Config::MQTT_CONNECT_BUFFER_BYTES);
    reportStatus("MQTT_RETRY");
    return;
  }
  lastMqttMessageAt = millis();
  statusDataSeen = false;
  lastPrintDataAt = 0;
  lastStatusRequestAt = 0;
  consecutiveStatusPublishFailures = 0;
  mqttWasConnected = true;
  reportStatus("READY");
  if (activeFilamentType.isEmpty()) ++materialSyncRequests;
  if (printerModelFromSerial(settings.printerSerial) == "H2D" &&
      (nozzleTemperature < 0 || leftNozzleTemperature < 0)) {
    ++nozzleSyncRequests;
  }
  Serial.println("[MQTT] connected and subscribed to Bambu report topic");
  publishStatusRequest();
  syncSelectedFleetRuntime(true);
}

void sendCurrentStatus() {
  queuePhoneEvent("H2D,ESP32,SE_BAMBU_ESP32_BRIDGE,1.15.9");
  reportHardwareControls();
  reportPrinterIdentity();
  syncSelectedFleetRuntime(true);
  for (uint8_t i = 0; i < FLEET_PRINTER_COUNT; ++i) {
    reportFleetStatus(i, true);
  }
  if (!activeFilamentType.isEmpty()) reportMaterial();
  reportTelemetry(true);
  if (!settings.complete()) {
    reportStatus("CONFIG_REQUIRED");
  } else if (WiFi.status() != WL_CONNECTED) {
    reportStatus("WIFI_CONNECTING");
  } else if (!mqttWasConnected && !fleetPrimaryPaused) {
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

  // Keep MQTT/TLS out of the way only while Wi-Fi and primary-printer fields
  // are being rewritten. Fleet inventory synchronization is idempotent and
  // must not pause a healthy selected-printer session for eight seconds every
  // time the iPhone comes to the foreground.
  if (head == "H2D_WIFI_SSID" || head == "H2D_WIFI_PASS" ||
      head == "H2D_IP" || head == "H2D_SERIAL" || head == "H2D_CODE" ||
      head == "H2D_SAVE") {
    lastConfigurationCommandAt = millis();
  }

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
      keepWifiOnNetworkReset = false;
      networkResetPending = true;
    } else {
      queuePhoneEvent("H2D,ERROR,Cấu hình thiếu hoặc IP máy in chưa đúng");
    }
  } else if (head == "H2D_PROFILE_SLOT") {
    const int first = argument.indexOf(',');
    const int second = first < 0 ? -1 : argument.indexOf(',', first + 1);
    const int third = second < 0 ? -1 : argument.indexOf(',', second + 1);
    const int fourth = third < 0 ? -1 : argument.indexOf(',', third + 1);
    if (first <= 0 || second <= first || third <= second || fourth <= third) {
      queuePhoneEvent("H2D,ERROR,Hồ sơ theo vị trí không đúng định dạng");
      return;
    }
    const int slot = argument.substring(0, first).toInt();
    FleetProfile profile;
    profile.kind = argument.substring(first + 1, second);
    profile.kind.toUpperCase();
    profile.printerIp = decodeBase64(argument.substring(second + 1, third));
    profile.printerSerial = decodeBase64(argument.substring(third + 1, fourth));
    profile.accessCode = decodeBase64(argument.substring(fourth + 1));
    if (slot < 0 || slot >= FLEET_PRINTER_COUNT || !profile.complete() ||
        !saveFleetProfile(slot, profile)) {
      queuePhoneEvent("H2D,ERROR,Không lưu được hồ sơ máy in theo vị trí");
      return;
    }
    fleetAssignmentsPending = true;
    queuePhoneEvent(String("H2D,CFG_ACK,PROFILE_SLOT_") + slot);
  } else if (head == "H2D_PROFILE_SLOT_CLEAR") {
    const int slot = argument.toInt();
    if (slot >= 0 && slot < FLEET_PRINTER_COUNT) {
      clearFleetProfile(slot);
      fleetAssignmentsPending = true;
    }
    queuePhoneEvent(String("H2D,CFG_ACK,PROFILE_SLOT_CLEAR_") + slot);
  } else if (head == "H2D_SELECT_SLOT") {
    const int8_t index = argument.toInt();
    if (index < 0 || index >= FLEET_PRINTER_COUNT ||
        !fleetProfiles[index].complete()) {
      queuePhoneEvent("H2D,ERROR,Chưa có hồ sơ máy được chọn để chụp");
      return;
    }
    const FleetProfile &profile = fleetProfiles[index];
    const bool needsReconnect =
        selectedFleetIndex != index || settings.printerIp != profile.printerIp ||
        settings.printerSerial != profile.printerSerial ||
        settings.accessCode != profile.accessCode;
    selectedFleetIndex = index;
    physicalCriticalAcknowledged = fleetRuntimes[index].physicalAlarmAcknowledged;
    if (needsReconnect) {
      settings.printerIp = profile.printerIp;
      settings.printerSerial = profile.printerSerial;
      settings.accessCode = profile.accessCode;
      pendingSettings = settings;
      preferences.putString("printerIp", settings.printerIp);
      preferences.putString("serial", settings.printerSerial);
      preferences.putString("access", settings.accessCode);
      resetPrinterRuntimeForProfileSwitch();
      clearPhoneEventQueue();
      queuePhoneEvent("H2D,CFG_ACK,SELECT");
      if (primeSelectedPrintFromFleet(index)) reportPrintStatus(true);
      keepWifiOnNetworkReset = true;
      networkResetPending = true;
      lastConfigurationCommandAt = 0;
    } else {
      fleetAssignmentsPending = true;
      syncSelectedFleetRuntime(true);
      queuePhoneEvent("H2D,CFG_ACK,SELECT");
      lastConfigurationCommandAt = 0;
    }
  } else if (head == "H2D_PROFILE") {
    const int first = argument.indexOf(',');
    const int second = first < 0 ? -1 : argument.indexOf(',', first + 1);
    const int third = second < 0 ? -1 : argument.indexOf(',', second + 1);
    if (first <= 0 || second <= first || third <= second) {
      queuePhoneEvent("H2D,ERROR,Hồ sơ giám sát không đúng định dạng");
      return;
    }
    String requestedKind = argument.substring(0, first);
    requestedKind.toUpperCase();
    const int8_t requestedIndex = fleetIndexForKind(requestedKind);
    FleetProfile profile;
    profile.kind = requestedKind;
    profile.printerIp = decodeBase64(argument.substring(first + 1, second));
    profile.printerSerial =
        decodeBase64(argument.substring(second + 1, third));
    profile.accessCode = decodeBase64(argument.substring(third + 1));
    const int8_t detectedIndex = fleetIndexForSerial(profile.printerSerial);
    if (requestedIndex < 0 || detectedIndex != requestedIndex ||
        !saveFleetProfile(requestedIndex, profile)) {
      queuePhoneEvent(String("H2D,ERROR,Không lưu được hồ sơ ") +
                      requestedKind + " • kiểm tra serial và Access Code");
      return;
    }
    fleetAssignmentsPending = true;
    queuePhoneEvent(String("H2D,CFG_ACK,PROFILE_") + requestedKind);
  } else if (head == "H2D_PROFILE_CLEAR") {
    const int8_t index = fleetIndexForKind(argument);
    if (index >= 0 && index != selectedFleetIndex) {
      clearFleetProfile(index);
      fleetAssignmentsPending = true;
    }
    queuePhoneEvent(String("H2D,CFG_ACK,PROFILE_CLEAR_") + argument);
  } else if (head == "H2D_SELECT") {
    const int8_t index = fleetIndexForKind(argument);
    if (index < 0 || !fleetProfiles[index].complete()) {
      queuePhoneEvent("H2D,ERROR,Chưa có hồ sơ máy được chọn để chụp");
      return;
    }
    const FleetProfile &profile = fleetProfiles[index];
    const bool needsReconnect =
        selectedFleetIndex != index || settings.printerIp != profile.printerIp ||
        settings.printerSerial != profile.printerSerial ||
        settings.accessCode != profile.accessCode;
    selectedFleetIndex = index;
    physicalCriticalAcknowledged =
        fleetRuntimes[index].physicalAlarmAcknowledged;
    if (needsReconnect) {
      // Profiles already contain the printer credentials. Switch the primary
      // MQTT target directly instead of replaying Wi-Fi fields and waiting for
      // a full configuration transaction on every tab change.
      settings.printerIp = profile.printerIp;
      settings.printerSerial = profile.printerSerial;
      settings.accessCode = profile.accessCode;
      pendingSettings = settings;
      preferences.putString("printerIp", settings.printerIp);
      preferences.putString("serial", settings.printerSerial);
      preferences.putString("access", settings.accessCode);
      resetPrinterRuntimeForProfileSwitch();
      clearPhoneEventQueue();
      queuePhoneEvent("H2D,CFG_ACK,SELECT");
      if (primeSelectedPrintFromFleet(index)) {
        // reportPrintStatus() includes the selected serial so the iPhone can
        // safely accept this provisional state while the profile switch is in
        // progress and ignore any late packet from the previous printer.
        reportPrintStatus(true);
      }
      // All saved printer profiles share the configured LAN.  Keep the Wi-Fi
      // association alive during a tab switch; only MQTT needs to move to the
      // new printer, which removes the several-second reconnect pause.
      keepWifiOnNetworkReset = true;
      networkResetPending = true;
      // Do not hold the normal configuration quiet period after this direct
      // switch; Wi-Fi/MQTT may reconnect on the next loop immediately.
      lastConfigurationCommandAt = 0;
    } else {
      fleetAssignmentsPending = true;
      syncSelectedFleetRuntime(true);
      queuePhoneEvent("H2D,CFG_ACK,SELECT");
      // H2D_PROFILE is persisted before SELECT is sent. If the selected
      // profile was already active there is no network restart to protect;
      // do not leave the normal 8-second configuration quiet period behind.
      lastConfigurationCommandAt = 0;
    }
  } else if (head == "H2D_ARM") {
    const bool requestedArmed = argument == "1";
    if (requestedArmed) {
      // The iPhone deliberately repeats ARM as a delivery handshake. Only the
      // first transition may establish a layer baseline; resetting it for
      // every retry could swallow the layer transition that should be shot.
      if (!timelapseArmed) {
        // Arm at the current layer so reconnecting in the middle of a print
        // does not invent frames for layers that the iPhone never observed.
        lastObservedLayer = currentLayer;
        // Resume from the layer currently being printed. On the next
        // transition only that just-finished layer is emitted.
        lastSnapLayer = max(lastSnapLayer, max(0, currentLayer - 1));
        finishSent = false;
      }
      timelapseArmed = true;
      reportStatus("ARMED");
    } else {
      timelapseArmed = false;
      reportStatus("DISARMED");
    }
  } else if (head == "H2D_COMPLETE_ACK") {
    // Tapping the completed state on iPhone dismisses the blue indication on
    // both devices immediately. The printer remains FINISH/IDLE; only the
    // presentation timer is cleared.
    printCompleteBlueUntil = 0;
    queuePhoneEvent("H2D,COMPLETE_ACK");
  } else if (head == "H2D_FLEET_REFRESH") {
    // The phone may repeat its refresh request while profile acknowledgements
    // are still draining over BLE. Coalesce those retries so a just-completed
    // scan is not immediately run a second time.
    if (!fleetRefreshInProgress && activeFleetMonitorSlot < 0 &&
        (lastFleetRefreshAt == 0 ||
         millis() - lastFleetRefreshAt >= 15000)) {
      fleetRefreshRequested = true;
    }
    for (uint8_t i = 0; i < FLEET_PRINTER_COUNT; ++i) {
      reportFleetStatus(i, true);
    }
    queuePhoneEvent("H2D,FLEET_REFRESH,QUEUED");
  } else if (head == "H2D_BUZZER") {
    buzzerEnabled = argument != "0";
    preferences.putBool("buzzer", buzzerEnabled);
    if (!buzzerEnabled) setBuzzerOutput(false);
    queueHardwareControl("BUZZER", buzzerEnabled ? 1 : 0);
  } else if (head == "H2D_BUZZER_VOLUME") {
    const uint8_t requestedVolume = constrain(argument.toInt(), 0, 100);
    const bool volumeChanged = requestedVolume != buzzerVolumePercent;
    buzzerVolumePercent = requestedVolume;
    if (volumeChanged) {
      preferences.putUChar("buzzVol", buzzerVolumePercent);
    }
    settingsPreviewPercent = buzzerVolumePercent;
    settingsPreviewType = 1;
    settingsPreviewUntil = millis() + 3000;
    // One short preview confirms the final slider value. Duplicate retry
    // packets are idempotent and therefore never produce a second beep.
    if (volumeChanged) requestBuzzerBeep(110);
    queueHardwareControl("BUZZER_VOLUME", buzzerVolumePercent);
  } else if (head == "H2D_LED_BRIGHTNESS") {
    ledBrightnessPercent = constrain(argument.toInt(), 0, 100);
    preferences.putUChar("ledLevel", ledBrightnessPercent);
    settingsPreviewPercent = ledBrightnessPercent;
    settingsPreviewType = 2;
    settingsPreviewUntil = millis() + 3000;
    queueHardwareControl("LED_BRIGHTNESS", ledBrightnessPercent);
  } else if (head == "H2D_BEEP") {
    requestBuzzerBeep();
  } else if (head == "H2D_ALARM_ACK") {
    // The iPhone OK button acknowledges the incidents that are active right
    // now, regardless of which printer tab is selected. The fault remains red
    // in the UI; a new error code/state transition clears this acknowledgement
    // and immediately re-arms the repeating physical alarm.
    if (criticalAlarmLatched && !isStoppedPrintState(printState)) {
      physicalCriticalAcknowledged = true;
    }
    for (uint8_t i = 0; i < FLEET_PRINTER_COUNT; ++i) {
      if (fleetRuntimeCritical(fleetRuntimes[i])) {
        fleetRuntimes[i].physicalAlarmAcknowledged = true;
      }
    }
    syncSelectedFleetRuntime(true);
    queuePhoneEvent("H2D,ALARM_ACK");
  } else if (head == "H2D_STATUS" || head == "APP_READY" || head == "PING") {
    sendCurrentStatus();
    // The command callback runs on NimBLE's host task. Defer publishStatus-
    // Request so it cannot race mqtt.loop() on the Arduino loop task.
    statusRequestPending = true;
  } else if (head == "H2D_ACK") {
    // BLE indications are already ordered. ACK is retained for diagnostics and
    // future retry logic; credentials and camera data never travel in this path.
  }
}

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer *server, NimBLEConnInfo &connection) override {
    phoneConnected = true;
    // TLS negotiation and one 22-KB H2D pushall may briefly monopolize the
    // shared Wi-Fi/Bluetooth radio.  A twelve-second supervision window keeps
    // the BLE control channel alive through that bounded LAN transaction.
    server->updateConnParams(connection.getConnHandle(), 12, 24, 0, 1200);
    Serial.println("[BLE] iPhone connected");
  }

  void onDisconnect(NimBLEServer *, NimBLEConnInfo &, int reason) override {
    phoneConnected = false;
    portENTER_CRITICAL(&eventMux);
    eventHead = eventTail = 0;
    portEXIT_CRITICAL(&eventMux);
    Serial.printf("[BLE] iPhone disconnected, reason=%d\n", reason);
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
  NimBLEDevice::setPower(ESP_PWR_LVL_P9);
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

int8_t readHardwareModeRaw() {
  const bool timelapseSelected =
      digitalRead(Config::MODE_TIMELAPSE_PIN) == LOW;
  const bool torchSelected = digitalRead(Config::MODE_TORCH_PIN) == LOW;
  if (timelapseSelected && !torchSelected) return 1;
  if (torchSelected && !timelapseSelected) return -1;
  // Centre position (or both contacts during a mechanical transition).
  return 0;
}

void queueHardwareControl(const char *name, int value) {
  queuePhoneEvent(String("H2D,CONTROL,") + name + "," + value);
}

void reportHardwareControls() {
  queueHardwareControl("MODE", hardwareMode);
  queueHardwareControl("HOLD", hardwareHoldPressed ? 1 : 0);
  queueHardwareControl("BUZZER", buzzerEnabled ? 1 : 0);
  queueHardwareControl("BUZZER_VOLUME", buzzerVolumePercent);
  queueHardwareControl("LED_BRIGHTNESS", ledBrightnessPercent);
}

uint8_t fixedLedBrightness() {
  // The potentiometer has been removed. Brightness is controlled by the SE
  // app and persisted on ESP32, so every mode uses the same predictable level.
  return static_cast<uint16_t>(Config::LED_MAX_BRIGHTNESS) *
         constrain(ledBrightnessPercent, 0, 100) / 100;
}

void updateHardwareInputs() {
  const uint32_t now = millis();
  if (now - lastInputRefreshAt < Config::INPUT_REFRESH_MS) return;
  lastInputRefreshAt = now;

  const int8_t rawMode = readHardwareModeRaw();
  if (rawMode != modeCandidate) {
    modeCandidate = rawMode;
    modeCandidateSince = now;
  } else if (hardwareMode != modeCandidate &&
             now - modeCandidateSince >= Config::MODE_INPUT_DEBOUNCE_MS) {
    hardwareMode = modeCandidate;
    // A physical mode change dismisses the temporary volume/brightness meter
    // immediately and returns the strip to printer/error/idle presentation.
    settingsPreviewUntil = 0;
    settingsPreviewType = 0;
    // Rotating to another position is the physical acknowledgement gesture.
    // It clears this ESP32's completion light and silences every currently
    // latched alarm without clearing the error shown by the iPhone/printer.
    printCompleteBlueUntil = 0;
    if (criticalAlarmLatched) physicalCriticalAcknowledged = true;
    for (uint8_t i = 0; i < FLEET_PRINTER_COUNT; ++i) {
      if (fleetRuntimeCritical(fleetRuntimes[i])) {
        fleetRuntimes[i].physicalAlarmAcknowledged = true;
      }
    }
    if (hardwareMode == 1) {
      // A short red acknowledgement makes the physical transition into
      // timelapse mode unambiguous before live printer colours take over.
      modeEntryFlashUntil = now + 1000;
    }
    // One accepted stable position produces exactly one short beep. A quick
    // deliberate move through all three positions is not rate-limited.
    requestBuzzerBeep();
    queueHardwareControl("MODE", hardwareMode);
    Serial.printf("[CONTROL] rotary mode %d\n", hardwareMode);
  }

  const bool rawHold = digitalRead(Config::HOLD_BUTTON_PIN) == LOW;
  if (rawHold != holdCandidate) {
    holdCandidate = rawHold;
    holdCandidateSince = now;
  } else if (hardwareHoldPressed != holdCandidate &&
             now - holdCandidateSince >= Config::INPUT_DEBOUNCE_MS) {
    hardwareHoldPressed = holdCandidate;
    queueHardwareControl("HOLD", hardwareHoldPressed ? 1 : 0);
    Serial.printf("[CONTROL] film button %s\n",
                  hardwareHoldPressed ? "held" : "released");
  }

}

uint32_t scaledLedColor(uint8_t red, uint8_t green, uint8_t blue,
                        uint8_t scale) {
  const uint16_t fixedBrightness = fixedLedBrightness();
  return ledStrip.Color(
      static_cast<uint32_t>(red) * scale * fixedBrightness / 65025,
      static_cast<uint32_t>(green) * scale * fixedBrightness / 65025,
      static_cast<uint32_t>(blue) * scale * fixedBrightness / 65025);
}

uint32_t ledColor(uint8_t red, uint8_t green, uint8_t blue) {
  return scaledLedColor(red, green, blue, 255);
}

void fillLedStrip(uint32_t color) {
  for (uint16_t i = 0; i < Config::LED_ACTIVE_COUNT; ++i) {
    ledStrip.setPixelColor(i, color);
  }
}

void fillStatusLeds(uint32_t color) {
  for (uint16_t i = 0; i < Config::LED_STATUS_COUNT; ++i) {
    ledStrip.setPixelColor(i, color);
  }
}

void fillAnimatedLeds(uint32_t color) {
  for (uint16_t i = 0; i < Config::LED_ANIMATED_COUNT; ++i) {
    ledStrip.setPixelColor(Config::LED_STATUS_COUNT + i, color);
  }
}

void drawSettingsLevel() {
  if (settingsPreviewType == 2) {
    // Brightness is a global intensity control, not a bar graph. Keep every
    // active LED on and dim/brighten the entire strip together so lowering the
    // slider never looks like LEDs are being removed from the effect.
    const uint8_t scale = static_cast<uint16_t>(
        constrain(settingsPreviewPercent, 0, 100)) * 255 / 100;
    fillLedStrip(ledStrip.Color(
        static_cast<uint16_t>(255) * scale / 255,
        static_cast<uint16_t>(190) * scale / 255, 0));
    return;
  }
  const float filled = static_cast<float>(settingsPreviewPercent) *
                       Config::LED_ACTIVE_COUNT / 100.0f;
  const uint8_t red = settingsPreviewType == 1 ? 0 : 255;
  const uint8_t green = settingsPreviewType == 1 ? 145 : 190;
  const uint8_t blue = settingsPreviewType == 1 ? 255 : 0;
  for (uint16_t i = 0; i < Config::LED_ACTIVE_COUNT; ++i) {
    const float portion = constrain(filled - i, 0.0f, 1.0f);
    if (portion <= 0.001f) continue;
    const uint8_t scale = static_cast<uint8_t>(55.0f + portion * 200.0f);
    // Setting feedback remains visible even while the requested normal LED
    // brightness is near zero; it is only a three-second level meter.
    ledStrip.setPixelColor(
        i, ledStrip.Color(static_cast<uint16_t>(red) * scale / 255,
                          static_cast<uint16_t>(green) * scale / 255,
                          static_cast<uint16_t>(blue) * scale / 255));
  }
}

void setBuzzerOutput(bool enabled) {
  const uint8_t volume = constrain(buzzerVolumePercent, 0, 100);
  buzzerOutputRequested = enabled && volume > 0;
  uint32_t activeDuty = 0;
  if (buzzerOutputRequested) {
    const uint32_t curved = static_cast<uint32_t>(volume) * volume;
    activeDuty = Config::BUZZER_MIN_AUDIBLE_DUTY +
        static_cast<uint32_t>(Config::BUZZER_VOLUME_PWM_MAX -
                              Config::BUZZER_MIN_AUDIBLE_DUTY) *
            curved / 10000u;
  }
  const uint32_t duty = Config::BUZZER_ACTIVE_HIGH
      ? activeDuty
      : Config::BUZZER_VOLUME_PWM_MAX - activeDuty;
  ledcWrite(Config::BUZZER_PIN, duty);
}

void requestBuzzerBeep(uint32_t durationMs) {
  if (!buzzerEnabled || buzzerVolumePercent == 0) return;
  buzzerBeepUntil = millis() + (durationMs < 40 ? 40 : durationMs);
}

void updateBuzzerAlarm() {
  // ESP32 is the independent safety alarm. Every unacknowledged printer fault
  // sounds here even while the iPhone is connected; the phone may play its own
  // siren too, but Bluetooth state can never silence the physical buzzer.
  if (!buzzerEnabled) {
    setBuzzerOutput(false);
    return;
  }
  const bool shouldAlarm = hasAnyFleetPhysicalCriticalError();
  const uint32_t now = millis();
  if (shouldAlarm) {
    const uint32_t period = Config::BUZZER_ON_MS + Config::BUZZER_OFF_MS;
    setBuzzerOutput((now % period) < Config::BUZZER_ON_MS);
    return;
  }
  setBuzzerOutput(static_cast<int32_t>(buzzerBeepUntil - now) > 0);
}

uint8_t breathingScale(uint32_t now) {
  const uint16_t phase = now % 2000;
  const uint16_t ramp = phase < 1000 ? phase : 2000 - phase;
  return 35 + static_cast<uint32_t>(ramp) * 220 / 1000;
}

uint8_t smoothPulseScale(uint32_t now, uint32_t period, uint8_t minimum,
                         uint8_t maximum) {
  const uint32_t halfPeriod = period < 2 ? 1 : period / 2;
  const uint32_t phase = now % period;
  const float ramp = phase <= halfPeriod
      ? static_cast<float>(phase) / halfPeriod
      : static_cast<float>(period - phase) / halfPeriod;
  const float eased = ramp * ramp * (3.0f - 2.0f * ramp);
  return minimum + static_cast<uint8_t>(
      eased * static_cast<float>(maximum - minimum));
}

float smoothLedProgress(uint32_t now) {
  const float target = constrain(static_cast<float>(printPercent), 0.0f, 100.0f);
  if (lastProgressTickAt == 0 || target + 2.0f < displayedPrintPercent) {
    displayedPrintPercent = target;
    lastProgressTickAt = now;
    return displayedPrintPercent;
  }
  const float elapsedSeconds =
      min(0.25f, static_cast<float>(now - lastProgressTickAt) / 1000.0f);
  lastProgressTickAt = now;

  // mc_percent is integral. Interpolate each new percentage over about 0.8 s,
  // then advance very slowly toward the next percentage using remaining time.
  // This makes each of the four animated pixels brighten continuously instead
  // of jumping whenever another MQTT packet arrives.
  const float estimatedRate = remainingMinutes > 0
      ? max(0.003f, (100.0f - target) /
                        (static_cast<float>(remainingMinutes) * 60.0f))
      : 0.012f;
  if (target > displayedPrintPercent) {
    const float catchUpRate = max(estimatedRate,
                                  (target - displayedPrintPercent) / 0.8f);
    displayedPrintPercent = min(target,
                                displayedPrintPercent +
                                    catchUpRate * elapsedSeconds);
  } else {
    displayedPrintPercent = min(target + 0.95f,
                                displayedPrintPercent +
                                    estimatedRate * elapsedSeconds);
  }
  return constrain(displayedPrintPercent, 0.0f, 100.0f);
}

void updateLedStrip() {
  const uint32_t now = millis();
  if (now - lastLedRefreshAt < Config::LED_REFRESH_MS) return;
  lastLedRefreshAt = now;
  ledStrip.clear();

  const bool anyCriticalError = hasAnyFleetPhysicalCriticalError();
  if (anyCriticalError) {
    // Every printer fault overrides the physical strip immediately, selected
    // or background. The phone does not need to be open and no profile switch
    // is required. Three leading LEDs stay red while the four effect LEDs
    // flash rapidly until the printer itself clears its error.
    const bool alarmOn = (now % 260) < 150;
    fillStatusLeds(ledColor(255, 0, 0));
    fillAnimatedLeds(alarmOn ? ledColor(255, 0, 0)
                             : ledStrip.Color(0, 0, 0));
  } else if (settingsPreviewType != 0 &&
             static_cast<int32_t>(settingsPreviewUntil - now) > 0) {
    // Buzzer volume uses a segment meter. LED brightness keeps the whole strip
    // at one intensity. Both expire after three seconds or immediately when
    // the rotary mode moves.
    drawSettingsLevel();
  } else if (printCompleteBlueUntil != 0 &&
             static_cast<int32_t>(printCompleteBlueUntil - now) > 0) {
    // Completion is blue for three hours. The leading three stay blue while
    // the four effect LEDs fade smoothly in and out over a slow four-second
    // cycle instead of switching abruptly.
    fillStatusLeds(ledColor(0, 105, 255));
    fillAnimatedLeds(scaledLedColor(
        0, 105, 255,
        smoothPulseScale(now, Config::PRINT_COMPLETE_PULSE_MS, 0, 255)));
  } else if (static_cast<int32_t>(modeEntryFlashUntil - now) > 0) {
    // Entering timelapse is acknowledged at the fixed 95% LED power for one
    // complete second at the fixed 95% output.
    fillLedStrip(ledColor(255, 0, 0));
  } else if (static_cast<int32_t>(captureFlashUntil - now) > 0) {
    // Same meaning as the blue border on iPhone: one layer photo was ordered.
    fillLedStrip(ledColor(0, 105, 255));
  } else if (hardwareHoldPressed) {
    // Pressing the film button keeps the strip yellow and steady. Only the
    // iPhone torch follows the button's flash cadence.
    fillLedStrip(ledColor(255, 190, 0));
  } else if (isPausedState() || isExplicitlyStoppedState() ||
             printState == "FAILED") {
    // A deliberate pause/stop is red but steady and never sounds the alarm.
    fillStatusLeds(ledColor(255, 0, 0));
    fillAnimatedLeds(scaledLedColor(255, 0, 0, breathingScale(now)));
  } else if (isActivePrintState(printState)) {
    // A print command owns green immediately, including heating, homing,
    // calibration, nozzle cleaning and filament changes. Yellow is reserved
    // for an idle/flash state only.
    // Pixels 0...2 stay green. Pixels 3...6 are the four progress pixels.
    // Future progress is white at exactly 30% of the green channel level. The
    // active segment cross-fades continuously from that dim white to full
    // green, and completed segments remain solid green.
    fillStatusLeds(ledColor(0, 255, 58));
    const float filledPixels =
        smoothLedProgress(now) * Config::LED_ANIMATED_COUNT / 100.0f;
    for (uint16_t i = 0; i < Config::LED_ANIMATED_COUNT; ++i) {
      const uint16_t pixel = Config::LED_STATUS_COUNT + i;
      const float portion = constrain(filledPixels - i, 0.0f, 1.0f);
      if (portion <= 0.001f) {
        ledStrip.setPixelColor(pixel, ledColor(77, 77, 77));
        continue;
      }
      if (portion >= 0.999f) {
        // A completed segment is the only progress state allowed to reach the
        // fixed 95% power, so it remains unmistakable from the active segment.
        ledStrip.setPixelColor(pixel, ledColor(0, 255, 58));
        continue;
      }
      // Interpolate from 30%-white (77/255) to the full green state. This keeps
      // unfinished LEDs visible without making them look completed.
      const float eased = portion * portion * (3.0f - 2.0f * portion);
      const uint8_t red = static_cast<uint8_t>((1.0f - eased) * 77.0f);
      const uint8_t green = static_cast<uint8_t>(
          77.0f + eased * (255.0f - 77.0f));
      const uint8_t blue = static_cast<uint8_t>(
          77.0f + eased * (58.0f - 77.0f));
      ledStrip.setPixelColor(pixel, ledColor(red, green, blue));
    }
  } else if (hardwareMode == 0) {
    // Centre is the normal waiting position. Match the iPhone standby effect
    // with one smooth yellow rise/fall every two seconds, capped at 40% of the
    // normal 95% LED power. An active print has already taken a branch above.
    fillStatusLeds(scaledLedColor(255, 190, 0, Config::LED_IDLE_MAX_SCALE));
    fillAnimatedLeds(scaledLedColor(
        255, 190, 0,
        smoothPulseScale(now, 2000, 18, Config::LED_IDLE_MAX_SCALE)));
  } else {
    // Torch (-1) is steady yellow until a printer session takes over above.
    // Timelapse (+1) also remains visibly yellow before its first print state.
    fillStatusLeds(ledColor(255, 190, 0));
    fillAnimatedLeds(ledColor(255, 190, 0));
  }
  // The installed strip may contain additional packages. Force every pixel
  // outside the seven-LED layout to black in every frame so LED 8+ can never
  // retain green from a previous firmware/layout.
  for (uint16_t i = Config::LED_ACTIVE_COUNT;
       i < Config::LED_PHYSICAL_COUNT; ++i) {
    ledStrip.setPixelColor(i, 0);
  }
  ledStrip.show();
}

void setup() {
  Serial.begin(115200);
  ledcAttach(Config::BUZZER_PIN, Config::BUZZER_VOLUME_PWM_HZ,
             Config::BUZZER_VOLUME_PWM_BITS);
  setBuzzerOutput(false);
  // Drive a known waiting colour before Wi-Fi/BLE/MQTT startup. This prevents
  // the strip from briefly retaining the green/red frame shown before reset.
  ledStrip.begin();
  ledStrip.setBrightness(255);
  fillLedStrip(ledColor(255, 190, 0));
  ledStrip.show();
  delay(250);
  Serial.println("\nSE Bambu Timelapse Bridge ESP32 v1.15.9");
  pinMode(Config::HOLD_BUTTON_PIN, INPUT_PULLUP);
  pinMode(Config::MODE_TIMELAPSE_PIN, INPUT_PULLUP);
  pinMode(Config::MODE_TORCH_PIN, INPUT_PULLUP);
  hardwareMode = modeCandidate = readHardwareModeRaw();
  hardwareHoldPressed = holdCandidate =
      digitalRead(Config::HOLD_BUTTON_PIN) == LOW;
  fillLedStrip(ledColor(255, 190, 0));
  ledStrip.show();
  loadSettings();
  setupBle();

  tlsClient.setInsecure();  // Bambu uses a per-device/self-signed LAN certificate.
  fleetTls.setInsecure();
  // The library defaults to a 30-second TCP wait and a 120-second TLS wait.
  // An offline A1/P2S would therefore freeze BLE and leave the iPhone stuck on
  // “đang kết nối”. LAN printers should answer within these short bounds.
  tlsClient.setConnectionTimeout(Config::MQTT_TCP_TIMEOUT_MS);
  tlsClient.setHandshakeTimeout(Config::MQTT_TLS_HANDSHAKE_TIMEOUT_SECONDS);
  fleetTls.setConnectionTimeout(Config::FLEET_TCP_TIMEOUT_MS);
  fleetTls.setHandshakeTimeout(Config::FLEET_TLS_HANDSHAKE_TIMEOUT_SECONDS);
  mqtt.setServer(settings.printerIp.c_str(), Config::MQTT_PORT);
  mqtt.setCallback(onMqttMessage);
  mqtt.setKeepAlive(Config::MQTT_KEEPALIVE_SECONDS);
  mqtt.setSocketTimeout(2);
  mqtt.setBufferSize(Config::MQTT_CONNECT_BUFFER_BYTES);
  fleetMqtt.setCallback(onFleetMqtt);
  fleetMqtt.setKeepAlive(60);
  fleetMqtt.setSocketTimeout(2);
  fleetMqtt.setBufferSize(Config::MQTT_CONNECT_BUFFER_BYTES);
  refreshFleetMonitorAssignments();
  if (settings.complete()) {
    reportStatus("WIFI_CONNECTING");
  } else {
    reportStatus("CONFIG_REQUIRED");
  }
}

void loop() {
  // Pump Bluetooth and physical feedback before any potentially blocking
  // Wi-Fi/TLS work so the iPhone never mistakes a delayed ACK for old firmware.
  flushPhoneEvents();
  updateHardwareInputs();
  updateLedStrip();
  updateBuzzerAlarm();
  processDeferredNetworkWork();
  // setServer is repeated because the IP can be changed from the app at runtime.
  mqtt.setServer(settings.printerIp.c_str(), Config::MQTT_PORT);
  maintainWiFi();
  maintainMqtt();
  if (mqttWasConnected && !fleetPrimaryPaused && !fleetRefreshInProgress &&
      activeFleetMonitorSlot < 0) {
    const bool mqttLoopOk = mqtt.loop();
    // PubSubClient changes its state to MQTT_CONNECTION_LOST when available()
    // detects a remote close. Use state(), not another TLS connected() probe;
    // the latter can touch an already-freed mbedTLS context on ESP32.
    const int mqttState = mqtt.state();
    if (!mqttLoopOk || mqttState != MQTT_CONNECTED) {
      Serial.printf("[MQTT] selected session lost at %lu ms, loop=%d state=%d, "
                    "WiFi=%d, heap=%u, max=%u\n",
                    static_cast<unsigned long>(millis()), mqttLoopOk ? 1 : 0,
                    mqttState, WiFi.status(), ESP.getFreeHeap(),
                    ESP.getMaxAllocHeap());
      mqttWasConnected = false;
    }
  }
  maintainFleetReachability();
  maintainFleetMonitors();
  reportPrintStatus(false);
  reportTelemetry(false);
  flushPhoneEvents();
  delay(2);
}

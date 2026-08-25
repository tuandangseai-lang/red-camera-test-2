#include <Arduino.h>
#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <ESP32Servo.h>
#include <Preferences.h>

// SE Rocket Tracker v3.2.1 - tap-select + dual-camera alignment + stable predictive gimbal
// MaixCAM = vision authority, ESP32 = deterministic servo controller,
// iPhone = recording/control UI. Do not send AI coordinates from the phone.

namespace Config {
constexpr uint8_t PAN_SERVO_PIN = 19;   // horizontal / left-right axis
constexpr uint8_t TILT_SERVO_PIN = 18;  // vertical / up-down axis
constexpr uint8_t MAIX_RX_PIN = 21;     // <- MaixCAM Type-C adapter TX (UART0/A16)
constexpr uint8_t MAIX_TX_PIN = 17;     // -> MaixCAM Type-C adapter RX (UART0/A17)
constexpr uint8_t STATUS_LED_PIN = 25;
constexpr uint8_t PHONE_CHARGE_RELAY_PIN = 26;

constexpr uint8_t PHONE_CHARGING_LEVEL = HIGH;
constexpr uint8_t PHONE_CHARGE_CUT_LEVEL = LOW;
constexpr uint32_t CHARGE_RESUME_DELAY_MS = 10000;

// Module 0.8 gear set supplied with the SE mount:
//   30T / 96T pan  = 3.20:1
//   30T / 48T tilt = 1.60:1
// Rates computed from the camera image are output-axis rates.  The servo must
// turn this many times faster to produce the requested camera movement.
constexpr float PAN_GEAR_RATIO = 96.0f / 30.0f;
constexpr float TILT_GEAR_RATIO = 48.0f / 30.0f;

constexpr float PAN_HOME_DEG = 90.0f;
constexpr float TILT_HOME_DEG = 30.0f;
constexpr float PAN_MIN_DEG = 5.0f;
constexpr float PAN_MAX_DEG = 175.0f;
constexpr float TILT_MIN_DEG = 5.0f;
constexpr float TILT_MAX_DEG = 175.0f;
// One external gear mesh reverses each output axis. These are the geared-rig
// defaults. If one physical axis moves away from the target, change only that
// axis sign; do not swap GPIO 18/19 or the Maix X/Y coordinates.
constexpr float PAN_DIRECTION = 1.0f;
constexpr float TILT_DIRECTION = 1.0f;
constexpr int SERVO_MIN_US = 900;
constexpr int SERVO_MAX_US = 2100;

constexpr uint32_t UART_BAUD = 115200;
constexpr uint32_t MAIX_FIRST_REPLY_TIMEOUT_MS = 1500;
constexpr uint32_t MAIX_PING_RETRY_MS = 500;
constexpr uint32_t CONTROL_PERIOD_US = 20000;  // MG996R: 50 Hz
constexpr uint32_t TARGET_STALE_MS = 180;
constexpr uint32_t COAST_LIMIT_MS = 420;
constexpr uint32_t SEARCH_LIMIT_MS = 850;
constexpr uint32_t TELEMETRY_PERIOD_MS = 80;
constexpr uint32_t BLE_NOTIFY_PERIOD_MS = 18;
constexpr uint8_t BLE_EVENT_QUEUE_SIZE = 20;
constexpr size_t BLE_EVENT_MAX_LENGTH = 144;

// Maix detector coordinates are 0...1000. On a 320-pixel model one pixel is
// already 3.1 units, so the previous 2.6-unit deadband reacted to sub-pixel
// detector noise and continually reversed the geared MG995/996.
constexpr float START_DEADBAND = 10.0f;
constexpr float STOP_DEADBAND = 5.0f;
constexpr float FAST_START_DEADBAND = 4.0f;
constexpr float FAST_STOP_DEADBAND = 2.0f;
constexpr float MAX_PAN_SPEED_DPS = 255.0f;
constexpr float MAX_TILT_SPEED_DPS = 300.0f;
constexpr float MAX_PAN_ACCEL_DPS2 = 2250.0f;
constexpr float MAX_TILT_ACCEL_DPS2 = 2450.0f;
constexpr float ROCKET_BOOST_PAN_SPEED_DPS = 320.0f;
constexpr float ROCKET_BOOST_TILT_SPEED_DPS = 360.0f;
constexpr float ROCKET_BOOST_PAN_ACCEL_DPS2 = 3400.0f;
constexpr float ROCKET_BOOST_TILT_ACCEL_DPS2 = 3450.0f;
constexpr float MAX_DECEL_DPS2 = 2800.0f;
constexpr float MAX_PAN_JERK_DPS3 = 16500.0f;
constexpr float MAX_TILT_JERK_DPS3 = 14500.0f;
constexpr float ROCKET_BOOST_PAN_JERK_DPS3 = 23500.0f;
constexpr float ROCKET_BOOST_TILT_JERK_DPS3 = 20500.0f;
constexpr float HOME_SPEED_DPS = 65.0f;
constexpr float SEARCH_SPEED_LIMIT_DPS = 92.0f;

constexpr uint32_t CENTER_CALIBRATION_SETTLE_MS = 1800;
constexpr uint32_t CENTER_CALIBRATION_MS = 2200;
constexpr uint32_t CENTER_CALIBRATION_TIMEOUT_MS = 10000;
constexpr uint8_t CENTER_CALIBRATION_MIN_SAMPLES = 14;
constexpr int CENTER_CALIBRATION_MAX_DEVIATION = 80;
constexpr int CENTER_CALIBRATION_MIN_CONFIDENCE = 55;
constexpr float CENTER_CALIBRATION_MAX_SPEED = 80.0f;

constexpr int MIN_LOCK_CONFIDENCE = 38;
constexpr int MIN_WEAK_CONFIDENCE = 12;
constexpr uint8_t CONSISTENT_LOCK_PACKETS = 2;
constexpr int MAX_LOCK_JUMP = 260;

constexpr char DEVICE_NAME[] = "RocketTracker-Test";
constexpr char SERVICE_UUID[] = "7E57A000-8E3A-4D6A-9B2B-13B10A000001";
constexpr char EVENT_UUID[] = "7E57A001-8E3A-4D6A-9B2B-13B10A000001";
constexpr char COMMAND_UUID[] = "7E57A002-8E3A-4D6A-9B2B-13B10A000001";
}  // namespace Config

enum VisionState : uint8_t {
  VISION_IDLE = 0,
  VISION_ACQUIRE = 1,
  VISION_LOCKED = 2,
  VISION_WEAK = 3,
  VISION_LOST = 4,
};

struct TargetPacket {
  uint16_t sequence = 0;
  uint32_t sourceMs = 0;
  int x = 500;
  int y = 500;
  int width = 0;
  int height = 0;
  int confidence = 0;
  int velocityX = 0;
  int velocityY = 0;
  VisionState state = VISION_IDLE;
  uint32_t receivedAtMs = 0;
  bool valid = false;
};

Servo panServo;
Servo tiltServo;
Preferences calibrationPreferences;
BLECharacteristic *eventCharacteristic = nullptr;
HardwareSerial maixSerial(2);

portMUX_TYPE targetMux = portMUX_INITIALIZER_UNLOCKED;
portMUX_TYPE phoneEventMux = portMUX_INITIALIZER_UNLOCKED;
TargetPacket latestTarget;
char phoneEventQueue[Config::BLE_EVENT_QUEUE_SIZE][Config::BLE_EVENT_MAX_LENGTH];
uint8_t phoneEventHead = 0;
uint8_t phoneEventTail = 0;
uint32_t lastPhoneNotifyAtMs = 0;

volatile bool phoneConnected = false;
bool sessionArmed = false;
bool homeRequested = true;
String selectedTrackingMode = "ROCKET";
bool searchActive = false;
bool panMoving = false;
bool tiltMoving = false;
bool chargeResumePending = false;
bool phoneChargeCut = false;
bool enrollmentActive = false;
uint8_t enrollmentProgress = 0;
bool centerCalibrationActive = false;
bool alignmentReady = false;
String lockedTargetToken = "WATER_ROCKET";

float panAngle = Config::PAN_HOME_DEG;
float tiltAngle = Config::TILT_HOME_DEG;
float panRate = 0.0f;
float tiltRate = 0.0f;
float panAcceleration = 0.0f;
float tiltAcceleration = 0.0f;
float filteredX = 500.0f;
float filteredY = 500.0f;
float filteredVX = 0.0f;
float filteredVY = 0.0f;
float filteredAX = 0.0f;
float filteredAY = 0.0f;
float previousVisionVX = 0.0f;
float previousVisionVY = 0.0f;
bool filterReady = false;
uint8_t consistentLockCount = 0;
int previousLockX = 500;
int previousLockY = 500;
uint16_t lastEvaluatedTargetSequence = 0;
uint16_t lastAppliedTargetSequence = 0;
uint32_t lastDynamicsAtMs = 0;
bool acceptedVisionLock = false;
int lastPanPulse = -1;
int lastTiltPulse = -1;
uint16_t commandSequence = 0;
uint32_t lostStartedAtMs = 0;
uint32_t lastControlAtUs = 0;
uint32_t lastTelemetryAtMs = 0;
uint32_t lastSerialLogAtMs = 0;
uint32_t chargeResumeAtMs = 0;
uint32_t armStartedAtMs = 0;
uint32_t lastMaixPingAtMs = 0;
uint32_t lastMaixPacketAtMs = 0;
bool maixRxSeenThisSession = false;
bool maixLinkFaultReported = false;
float targetCenterX = 500.0f;
float targetCenterY = 500.0f;
uint32_t centerCalibrationStartedAtMs = 0;
uint32_t centerCalibrationFirstSampleAtMs = 0;
uint32_t lastCenterCalibrationNotifyAtMs = 0;
uint32_t centerCalibrationSumX = 0;
uint32_t centerCalibrationSumY = 0;
uint16_t centerCalibrationSamples = 0;
uint16_t lastCenterCalibrationSequence = 0;

char uartLine[192];
size_t uartLineLength = 0;

float clampFloat(float value, float low, float high) {
  return value < low ? low : (value > high ? high : value);
}

float moveToward(float value, float target, float maxDelta) {
  if (value < target) return min(value + maxDelta, target);
  if (value > target) return max(value - maxDelta, target);
  return value;
}

float updateJerkLimitedRate(float rate, float desiredRate, float &acceleration,
                            float maximumAcceleration, float maximumDeceleration,
                            float maximumJerk, float dt) {
  // A position command that changes abruptly makes an MG995/996 kick its gear
  // train.  Shape the *velocity* command instead: bounded acceleration and
  // bounded change of acceleration (jerk), like a small camera gimbal.
  const bool reversing = rate * desiredRate < 0.0f;
  const bool slowing = reversing || fabsf(desiredRate) < fabsf(rate);
  const float accelerationLimit =
      slowing ? maximumDeceleration : maximumAcceleration;
  const float responseSeconds = slowing ? 0.060f : 0.085f;
  const float targetAcceleration = clampFloat(
      (desiredRate - rate) / responseSeconds, -accelerationLimit,
      accelerationLimit);
  acceleration = moveToward(acceleration, targetAcceleration,
                            maximumJerk * dt);

  const float previousError = desiredRate - rate;
  rate += acceleration * dt;
  const float nextError = desiredRate - rate;
  if (previousError * nextError <= 0.0f) {
    rate = desiredRate;
    acceleration *= 0.28f;
  }
  if (fabsf(desiredRate) < 0.05f && fabsf(rate) < 0.45f &&
      fabsf(acceleration) < 18.0f) {
    rate = 0.0f;
    acceleration = 0.0f;
  }
  return rate;
}

uint8_t crc8Xor(const char *text, size_t length) {
  uint8_t crc = 0;
  for (size_t i = 0; i < length; ++i) crc ^= static_cast<uint8_t>(text[i]);
  return crc;
}

int angleToPulse(float angle) {
  const float ratio = clampFloat(angle / 180.0f, 0.0f, 1.0f);
  return lroundf(Config::SERVO_MIN_US +
                 ratio * (Config::SERVO_MAX_US - Config::SERVO_MIN_US));
}

void writeServos(bool force = false) {
  const int panPulse = angleToPulse(panAngle);
  const int tiltPulse = angleToPulse(tiltAngle);
  if (force || lastPanPulse < 0 || abs(panPulse - lastPanPulse) >= 2) {
    panServo.writeMicroseconds(panPulse);
    lastPanPulse = panPulse;
  }
  if (force || lastTiltPulse < 0 || abs(tiltPulse - lastTiltPulse) >= 2) {
    tiltServo.writeMicroseconds(tiltPulse);
    lastTiltPulse = tiltPulse;
  }
}

void notifyPhone(const String &message) {
  if (!phoneConnected || eventCharacteristic == nullptr) return;
  portENTER_CRITICAL(&phoneEventMux);
  uint8_t next = (phoneEventHead + 1) % Config::BLE_EVENT_QUEUE_SIZE;
  if (next == phoneEventTail) {
    // Drop the oldest UI packet, never block UART parsing or servo timing.
    phoneEventTail = (phoneEventTail + 1) % Config::BLE_EVENT_QUEUE_SIZE;
  }
  strlcpy(phoneEventQueue[phoneEventHead], message.c_str(),
          Config::BLE_EVENT_MAX_LENGTH);
  phoneEventHead = next;
  portEXIT_CRITICAL(&phoneEventMux);
}

void flushPhoneNotifications() {
  if (!phoneConnected || eventCharacteristic == nullptr) return;
  const uint32_t now = millis();
  if (now - lastPhoneNotifyAtMs < Config::BLE_NOTIFY_PERIOD_MS) return;

  char message[Config::BLE_EVENT_MAX_LENGTH];
  bool available = false;
  portENTER_CRITICAL(&phoneEventMux);
  if (phoneEventTail != phoneEventHead) {
    strlcpy(message, phoneEventQueue[phoneEventTail], sizeof(message));
    phoneEventTail = (phoneEventTail + 1) % Config::BLE_EVENT_QUEUE_SIZE;
    available = true;
  }
  portEXIT_CRITICAL(&phoneEventMux);
  if (!available) return;

  eventCharacteristic->setValue(message);
  eventCharacteristic->notify();
  lastPhoneNotifyAtMs = now;
}

void sendMaixCommand(const char *command, const char *argument = "0") {
  char body[96];
  snprintf(body, sizeof(body), "C,%u,%s,%s", ++commandSequence, command,
           argument);
  const uint8_t crc = crc8Xor(body, strlen(body));
  char packet[112];
  snprintf(packet, sizeof(packet), "$%s*%02X\n", body, crc);
  maixSerial.print(packet);
}

void setPhoneCharging(bool charging) {
  digitalWrite(Config::PHONE_CHARGE_RELAY_PIN,
               charging ? Config::PHONE_CHARGING_LEVEL
                        : Config::PHONE_CHARGE_CUT_LEVEL);
  phoneChargeCut = !charging;
}

void resetTrackingFilter() {
  portENTER_CRITICAL(&targetMux);
  latestTarget = TargetPacket();
  portEXIT_CRITICAL(&targetMux);
  filteredX = filteredY = 500.0f;
  filteredVX = filteredVY = 0.0f;
  filteredAX = filteredAY = 0.0f;
  previousVisionVX = previousVisionVY = 0.0f;
  lastDynamicsAtMs = 0;
  filterReady = false;
  consistentLockCount = 0;
  previousLockX = previousLockY = 500;
  lastEvaluatedTargetSequence = 0;
  lastAppliedTargetSequence = 0;
  acceptedVisionLock = false;
  panRate = tiltRate = 0.0f;
  panAcceleration = tiltAcceleration = 0.0f;
  panMoving = tiltMoving = false;
  searchActive = false;
  lostStartedAtMs = 0;
}

void cancelCenterCalibration() {
  centerCalibrationActive = false;
  centerCalibrationStartedAtMs = 0;
  centerCalibrationFirstSampleAtMs = 0;
  centerCalibrationSamples = 0;
  centerCalibrationSumX = centerCalibrationSumY = 0;
  lastCenterCalibrationSequence = 0;
}

void beginCenterCalibration() {
  if (!sessionArmed || enrollmentActive) {
    notifyPhone("CALIBRATE,FAILED,LOCK_FIRST");
    return;
  }
  centerCalibrationActive = true;
  alignmentReady = false;
  centerCalibrationStartedAtMs = millis();
  centerCalibrationFirstSampleAtMs = 0;
  lastCenterCalibrationNotifyAtMs = 0;
  centerCalibrationSamples = 0;
  centerCalibrationSumX = centerCalibrationSumY = 0;
  lastCenterCalibrationSequence = 0;
  panRate = tiltRate = 0.0f;
  panAcceleration = tiltAcceleration = 0.0f;
  panMoving = tiltMoving = false;
  notifyPhone("CALIBRATE,PREPARE,0,20CM");
  Serial.println("[CALIBRATE] Put target on iPhone +, >=20 cm away; settling");
}

void armSession() {
  cancelCenterCalibration();
  resetTrackingFilter();
  sessionArmed = true;
  enrollmentActive = true;
  alignmentReady = false;
  enrollmentProgress = 0;
  armStartedAtMs = millis();
  lastMaixPingAtMs = 0;
  maixRxSeenThisSession = false;
  maixLinkFaultReported = false;
  homeRequested = false;
  setPhoneCharging(false);
  chargeResumePending = false;
  sendMaixCommand("MODE", selectedTrackingMode.c_str());
  sendMaixCommand("ARM");
  notifyPhone("CANDIDATES,CLEAR");
  notifyPhone(String("ENROLL,0,") + selectedTrackingMode + ",START");
  notifyPhone("STATE,ACQUIRE,0");
  Serial.println("[SESSION] ARMED - MaixCAM is vision authority");
}

bool isSupportedTrackingMode(const String &mode) {
  return mode == "ROCKET" || mode == "PERSON" || mode == "ANIMAL" ||
         mode == "OBJECT";
}

void selectTrackingMode(String mode) {
  mode.trim();
  mode.toUpperCase();
  if (!isSupportedTrackingMode(mode)) return;
  selectedTrackingMode = mode;
  lockedTargetToken = mode == "ROCKET" ? "WATER_ROCKET" : mode;
  enrollmentActive = false;
  alignmentReady = false;
  enrollmentProgress = 0;
  cancelCenterCalibration();
  resetTrackingFilter();
  sendMaixCommand("MODE", selectedTrackingMode.c_str());
  notifyPhone("CANDIDATES,CLEAR");
  notifyPhone(String("MODE,") + selectedTrackingMode);
  notifyPhone(sessionArmed ? "STATE,ACQUIRE,0" : "STATE,IDLE,0");
  Serial.printf("[MODE] %s\n", selectedTrackingMode.c_str());
}

void stopSession() {
  sessionArmed = false;
  enrollmentActive = false;
  alignmentReady = false;
  enrollmentProgress = 0;
  cancelCenterCalibration();
  resetTrackingFilter();
  sendMaixCommand("DISARM");
  notifyPhone("CANDIDATES,CLEAR");
  chargeResumePending = true;
  chargeResumeAtMs = millis() + Config::CHARGE_RESUME_DELAY_MS;
  notifyPhone("STATE,IDLE,0");
  Serial.println("[SESSION] STOPPED");
}

void requestHome() {
  sessionArmed = false;
  enrollmentActive = false;
  alignmentReady = false;
  enrollmentProgress = 0;
  cancelCenterCalibration();
  resetTrackingFilter();
  homeRequested = true;
  sendMaixCommand("HOME");
  notifyPhone("CANDIDATES,CLEAR");
  notifyPhone("STATE,HOME,0");
  Serial.println("[SERVO] Smooth HOME requested");
}

bool parseInteger(const char *text, long &value) {
  if (text == nullptr || *text == '\0') return false;
  char *end = nullptr;
  value = strtol(text, &end, 10);
  return end != text && *end == '\0';
}

bool parseTargetBody(char *body, TargetPacket &out) {
  char *save = nullptr;
  char *token = strtok_r(body, ",", &save);
  if (token == nullptr || strcmp(token, "T") != 0) return false;
  long values[10];
  for (int i = 0; i < 10; ++i) {
    token = strtok_r(nullptr, ",", &save);
    if (!parseInteger(token, values[i])) return false;
  }
  if (values[2] < 0 || values[2] > 1000 || values[3] < 0 ||
      values[3] > 1000 || values[4] < 0 || values[4] > 1000 ||
      values[5] < 0 || values[5] > 1000 || values[6] < 0 ||
      values[6] > 100 || values[9] < VISION_IDLE ||
      values[9] > VISION_LOST) {
    return false;
  }
  out.sequence = static_cast<uint16_t>(values[0]);
  out.sourceMs = static_cast<uint32_t>(values[1]);
  out.x = values[2];
  out.y = values[3];
  out.width = values[4];
  out.height = values[5];
  out.confidence = values[6];
  out.velocityX = constrain(values[7], -2500L, 2500L);
  out.velocityY = constrain(values[8], -2500L, 2500L);
  out.state = static_cast<VisionState>(values[9]);
  out.receivedAtMs = millis();
  out.valid = true;
  return true;
}

void processMaixLine(char *line) {
  if (line[0] != '$') return;
  char *star = strrchr(line, '*');
  if (star == nullptr || strlen(star + 1) < 2) return;
  *star = '\0';
  const char *bodyText = line + 1;
  char *end = nullptr;
  const long receivedCrc = strtol(star + 1, &end, 16);
  if (end == star + 1 ||
      static_cast<uint8_t>(receivedCrc) !=
          crc8Xor(bodyText, strlen(bodyText))) {
    return;
  }

  lastMaixPacketAtMs = millis();
  maixRxSeenThisSession = true;
  if (maixLinkFaultReported) {
    maixLinkFaultReported = false;
    notifyPhone("LINK,MAIX_OK");
    Serial.println("[MAIX LINK] RX recovered");
  }

  if (strncmp(bodyText, "T,", 2) == 0) {
    char mutableBody[160];
    strlcpy(mutableBody, bodyText, sizeof(mutableBody));
    TargetPacket packet;
    if (parseTargetBody(mutableBody, packet)) {
      portENTER_CRITICAL(&targetMux);
      latestTarget = packet;
      portEXIT_CRITICAL(&targetMux);
    }
  } else if (strncmp(bodyText, "B,", 2) == 0) {
    Serial.printf("[MAIX] %s\n", bodyText);
    notifyPhone(String("MAIX,") + bodyText + 2);
  } else if (strncmp(bodyText, "A,", 2) == 0) {
    Serial.printf("[MAIX ACK] %s\n", bodyText);
  } else if (strncmp(bodyText, "E,", 2) == 0) {
    const String enrollment = String(bodyText + 2);
    const int firstComma = enrollment.indexOf(',');
    if (firstComma > 0) {
      enrollmentProgress = static_cast<uint8_t>(
          constrain(enrollment.substring(0, firstComma).toInt(), 0, 100));
    }
    const int readyMarker = enrollment.indexOf(",READY,");
    const bool ready = readyMarker >= 0 || enrollment.endsWith(",READY");
    enrollmentActive = !ready;
    if (readyMarker >= 0) {
      lockedTargetToken = enrollment.substring(readyMarker + 7);
      lockedTargetToken.trim();
    }
    notifyPhone(String("ENROLL,") + enrollment);
    if (ready) {
      notifyPhone(String("TARGET,") + lockedTargetToken);
      beginCenterCalibration();
    }
    Serial.printf("[MAIX ENROLL] %s\n", enrollment.c_str());
  } else if (strncmp(bodyText, "D,", 2) == 0) {
    // Candidate packet: slot, track id, class id, confidence and normalised
    // box.  ESP32 forwards it untouched; the iPhone is the only selector.
    const String candidate = String(bodyText + 2);
    notifyPhone(String("CANDIDATE,") + candidate);
    Serial.printf("[MAIX CANDIDATE] %s\n", candidate.c_str());
  }
}

void readMaixUart() {
  while (maixSerial.available() > 0) {
    const char character = static_cast<char>(maixSerial.read());
    if (character == '\n') {
      uartLine[uartLineLength] = '\0';
      processMaixLine(uartLine);
      uartLineLength = 0;
    } else if (character != '\r') {
      if (uartLineLength + 1 < sizeof(uartLine)) {
        uartLine[uartLineLength++] = character;
      } else {
        uartLineLength = 0;
      }
    }
  }
}

void monitorMaixLink() {
  if (!sessionArmed || !enrollmentActive || maixRxSeenThisSession) return;

  const uint32_t now = millis();
  const uint32_t elapsed = now - armStartedAtMs;
  if (elapsed >= Config::MAIX_PING_RETRY_MS &&
      (lastMaixPingAtMs == 0 ||
       now - lastMaixPingAtMs >= Config::MAIX_PING_RETRY_MS)) {
    lastMaixPingAtMs = now;
    sendMaixCommand("PING");
  }

  if (elapsed >= Config::MAIX_FIRST_REPLY_TIMEOUT_MS &&
      !maixLinkFaultReported) {
    maixLinkFaultReported = true;
    notifyPhone("LINK,MAIX_TX_MISSING");
    Serial.println(
        "[MAIX LINK ERROR] Maix received commands but ESP32 received no reply; "
        "check Maix TX/A16 -> ESP32 GPIO21 and common GND");
  }
}

bool lockPacketIsConsistent(const TargetPacket &target) {
  // The servo loop runs at 50 Hz and can see one Maix packet several times.
  // Count consistency only once per real vision frame; otherwise one false
  // detection could be promoted to a lock simply by rereading the same packet.
  if (target.sequence == lastEvaluatedTargetSequence) {
    return acceptedVisionLock && target.state == VISION_LOCKED &&
           target.confidence >= Config::MIN_LOCK_CONFIDENCE;
  }
  lastEvaluatedTargetSequence = target.sequence;
  if (target.state != VISION_LOCKED ||
      target.confidence < Config::MIN_LOCK_CONFIDENCE) {
    consistentLockCount = 0;
    acceptedVisionLock = false;
    return false;
  }
  const float targetSpeed = hypotf(target.velocityX, target.velocityY);
  const int dynamicJump = Config::MAX_LOCK_JUMP +
                          min(160, static_cast<int>(targetSpeed * 0.07f));
  if (consistentLockCount == 0 ||
      (abs(target.x - previousLockX) <= dynamicJump &&
       abs(target.y - previousLockY) <= dynamicJump)) {
    consistentLockCount = min<uint8_t>(consistentLockCount + 1, 20);
  } else {
    consistentLockCount = 1;
  }
  previousLockX = target.x;
  previousLockY = target.y;
  // A high-confidence rocket is allowed to steer on the first independent
  // frame.  Waiting for a second 30-fps frame costs most of its launch travel.
  const uint8_t packetsRequired =
      (selectedTrackingMode == "ROCKET" && target.confidence >= 60)
          ? 1
          : Config::CONSISTENT_LOCK_PACKETS;
  acceptedVisionLock = consistentLockCount >= packetsRequired;
  return acceptedVisionLock;
}

float adaptiveGainFromSize(const TargetPacket &target) {
  const float largest = max(target.width, target.height);
  // A small distant target crosses the frame quickly in angular terms. Give
  // it more authority; large nearby targets get softer correction. This is a
  // smooth gain schedule, not a mode switch, so zoom/scale changes cannot kick
  // the mount.
  return clampFloat(1.40f - largest / 1500.0f, 1.03f, 1.38f);
}

float axisDesiredRate(float error, float velocity, float direction,
                      float gearRatio,
                      float maxSpeed, float sizeGain, float startDeadband,
                      float stopDeadband, float proportionalGain,
                      float feedForwardGain, float minimumRate, bool &moving) {
  const float absoluteError = fabsf(error);
  if (moving) {
    if (absoluteError <= stopDeadband && fabsf(velocity) < 30.0f) moving = false;
  } else if (absoluteError >= startDeadband || fabsf(velocity) >= 45.0f) {
    moving = true;
  }
  if (!moving) return 0.0f;

  const float proportional = error * proportionalGain;
  float stableVelocity = fabsf(velocity) < 18.0f ? 0.0f : velocity;
  float feedForward = stableVelocity * feedForwardGain;
  // Close to centre, a noisy velocity estimate must not reverse the axis away
  // from the measured error. Farther out, retain the full predictive lead.
  if (proportional * feedForward < 0.0f &&
      absoluteError < startDeadband * 2.6f) {
    feedForward *= 0.28f;
  }
  // Convert the requested output/camera rate to motor-shaft rate. The final
  // clamp remains a physical MG996 safety limit.
  float desired = direction * (proportional + feedForward) * sizeGain *
                  gearRatio;
  if (absoluteError > startDeadband * 1.8f && fabsf(desired) < minimumRate) {
    desired = copysignf(minimumRate, desired);
  }
  return clampFloat(desired, -maxSpeed, maxSpeed);
}

void runHome(float dt) {
  const float panError = Config::PAN_HOME_DEG - panAngle;
  const float tiltError = Config::TILT_HOME_DEG - tiltAngle;
  const float desiredPan = clampFloat(panError * 3.0f, -Config::HOME_SPEED_DPS,
                                      Config::HOME_SPEED_DPS);
  const float desiredTilt = clampFloat(tiltError * 3.0f, -Config::HOME_SPEED_DPS,
                                       Config::HOME_SPEED_DPS);
  panRate = updateJerkLimitedRate(
      panRate, desiredPan, panAcceleration, 900.0f, 1200.0f,
      Config::MAX_PAN_JERK_DPS3 * 0.45f, dt);
  tiltRate = updateJerkLimitedRate(
      tiltRate, desiredTilt, tiltAcceleration, 800.0f, 1100.0f,
      Config::MAX_TILT_JERK_DPS3 * 0.45f, dt);
  panAngle += panRate * dt;
  tiltAngle += tiltRate * dt;
  if (fabsf(panError) < 0.20f && fabsf(tiltError) < 0.20f &&
      fabsf(panRate) < 0.5f && fabsf(tiltRate) < 0.5f) {
    panAngle = Config::PAN_HOME_DEG;
    tiltAngle = Config::TILT_HOME_DEG;
    panRate = tiltRate = 0.0f;
    panAcceleration = tiltAcceleration = 0.0f;
    homeRequested = false;
    notifyPhone("STATE,HOME_DONE,0");
  }
}

void holdServos(float dt) {
  panRate = updateJerkLimitedRate(
      panRate, 0.0f, panAcceleration, Config::MAX_PAN_ACCEL_DPS2,
      Config::MAX_DECEL_DPS2, Config::MAX_PAN_JERK_DPS3, dt);
  tiltRate = updateJerkLimitedRate(
      tiltRate, 0.0f, tiltAcceleration, Config::MAX_TILT_ACCEL_DPS2,
      Config::MAX_DECEL_DPS2, Config::MAX_TILT_JERK_DPS3, dt);
  panAngle += panRate * dt;
  tiltAngle += tiltRate * dt;
  panMoving = tiltMoving = false;
}

void updateCenterCalibration(float dt, const TargetPacket &target,
                             uint32_t nowMs) {
  holdServos(dt);
  const uint32_t settleElapsed = nowMs - centerCalibrationStartedAtMs;
  if (settleElapsed < Config::CENTER_CALIBRATION_SETTLE_MS) {
    if (nowMs - lastCenterCalibrationNotifyAtMs >= 80) {
      lastCenterCalibrationNotifyAtMs = nowMs;
      const int prepareProgress = constrain(
          static_cast<int>(settleElapsed * 100 /
                           Config::CENTER_CALIBRATION_SETTLE_MS),
          0, 99);
      notifyPhone(String("CALIBRATE,PREPARE,") + prepareProgress + ",20CM");
    }
    return;
  }

  const bool freshLock = target.valid &&
                         nowMs - target.receivedAtMs <= Config::TARGET_STALE_MS &&
                         target.state == VISION_LOCKED &&
                         target.confidence >=
                             Config::CENTER_CALIBRATION_MIN_CONFIDENCE &&
                         hypotf(target.velocityX, target.velocityY) <=
                             Config::CENTER_CALIBRATION_MAX_SPEED;

  if (freshLock && target.sequence != lastCenterCalibrationSequence) {
    lastCenterCalibrationSequence = target.sequence;
    bool acceptSample = true;
    if (centerCalibrationSamples >= 4) {
      const int meanX = centerCalibrationSumX / centerCalibrationSamples;
      const int meanY = centerCalibrationSumY / centerCalibrationSamples;
      acceptSample = abs(target.x - meanX) <=
                         Config::CENTER_CALIBRATION_MAX_DEVIATION &&
                     abs(target.y - meanY) <=
                         Config::CENTER_CALIBRATION_MAX_DEVIATION;
    }
    if (acceptSample) {
      if (centerCalibrationFirstSampleAtMs == 0)
        centerCalibrationFirstSampleAtMs = nowMs;
      centerCalibrationSumX += target.x;
      centerCalibrationSumY += target.y;
      centerCalibrationSamples++;
    }
  }

  if (nowMs - lastCenterCalibrationNotifyAtMs >= 100) {
    lastCenterCalibrationNotifyAtMs = nowMs;
    int progress = 0;
    if (centerCalibrationFirstSampleAtMs != 0) {
      progress = constrain(
          static_cast<int>((nowMs - centerCalibrationFirstSampleAtMs) * 100 /
                           Config::CENTER_CALIBRATION_MS),
          0, 99);
    }
    notifyPhone(String("CALIBRATE,PROGRESS,") + progress);
  }

  const bool enoughTime = centerCalibrationFirstSampleAtMs != 0 &&
                          nowMs - centerCalibrationFirstSampleAtMs >=
                              Config::CENTER_CALIBRATION_MS;
  if (enoughTime &&
      centerCalibrationSamples >= Config::CENTER_CALIBRATION_MIN_SAMPLES) {
    targetCenterX = clampFloat(
        static_cast<float>(centerCalibrationSumX) / centerCalibrationSamples,
        200.0f, 800.0f);
    targetCenterY = clampFloat(
        static_cast<float>(centerCalibrationSumY) / centerCalibrationSamples,
        200.0f, 800.0f);
    calibrationPreferences.putUShort("centerX", lroundf(targetCenterX));
    calibrationPreferences.putUShort("centerY", lroundf(targetCenterY));
    centerCalibrationActive = false;
    alignmentReady = true;
    filteredX = targetCenterX;
    filteredY = targetCenterY;
    filteredVX = filteredVY = 0.0f;
    filteredAX = filteredAY = 0.0f;
    previousVisionVX = previousVisionVY = 0.0f;
    lastDynamicsAtMs = 0;
    notifyPhone(String("CALIBRATE,DONE,") + lroundf(targetCenterX) + "," +
                lroundf(targetCenterY));
    Serial.printf("[CALIBRATE] center=%.0f,%.0f samples=%u\n", targetCenterX,
                  targetCenterY, centerCalibrationSamples);
    return;
  }

  if (nowMs - centerCalibrationStartedAtMs >=
      Config::CENTER_CALIBRATION_TIMEOUT_MS) {
    cancelCenterCalibration();
    alignmentReady = false;
    notifyPhone("CALIBRATE,FAILED,NO_STABLE_TARGET");
    Serial.println("[CALIBRATE] failed - no stable target");
  }
}

void runTracking(float dt, const TargetPacket &target, uint32_t nowMs) {
  const uint32_t age = nowMs - target.receivedAtMs;
  const bool freshTarget = age <= Config::TARGET_STALE_MS;
  const bool targetLooksLocked =
      freshTarget && target.state == VISION_LOCKED &&
      target.confidence >= Config::MIN_LOCK_CONFIDENCE;
  const bool strongLock = freshTarget && lockPacketIsConsistent(target);
  const bool weakTrack = age <= Config::COAST_LIMIT_MS &&
                         target.state == VISION_WEAK &&
                         target.confidence >= Config::MIN_WEAK_CONFIDENCE &&
                         filterReady;

  if (strongLock) {
    if (target.sequence != lastAppliedTargetSequence) {
      const float rawSpeed = hypotf(target.velocityX, target.velocityY);
      const float rawError = hypotf(target.x - targetCenterX,
                                    target.y - targetCenterY);
      const bool rocketFast = selectedTrackingMode == "ROCKET" &&
                              (rawSpeed > 65.0f || rawError > 45.0f);
      const bool quietMeasurement = rawSpeed < 34.0f && rawError < 24.0f;
      const float alpha = filterReady
                              ? (rocketFast ? 0.70f
                                            : quietMeasurement ? 0.24f : 0.42f)
                              : 1.0f;
      const float velocityAlpha = rocketFast ? 0.58f
                                              : quietMeasurement ? 0.16f : 0.30f;
      if (lastDynamicsAtMs != 0 && target.receivedAtMs > lastDynamicsAtMs) {
        const float visionDt = clampFloat(
            (target.receivedAtMs - lastDynamicsAtMs) / 1000.0f, 0.015f,
            0.120f);
        const float rawAX = clampFloat(
            (target.velocityX - previousVisionVX) / visionDt, -5000.0f,
            5000.0f);
        const float rawAY = clampFloat(
            (target.velocityY - previousVisionVY) / visionDt, -5000.0f,
            5000.0f);
        const float accelerationAlpha = rocketFast ? 0.28f : 0.15f;
        filteredAX += accelerationAlpha * (rawAX - filteredAX);
        filteredAY += accelerationAlpha * (rawAY - filteredAY);
      }
      filteredX += alpha * (target.x - filteredX);
      filteredY += alpha * (target.y - filteredY);
      filteredVX += velocityAlpha * (target.velocityX - filteredVX);
      filteredVY += velocityAlpha * (target.velocityY - filteredVY);
      previousVisionVX = target.velocityX;
      previousVisionVY = target.velocityY;
      lastDynamicsAtMs = target.receivedAtMs;
      if (quietMeasurement &&
          fabsf(filteredX - targetCenterX) < Config::START_DEADBAND * 1.35f &&
          fabsf(filteredY - targetCenterY) < Config::START_DEADBAND * 1.35f) {
        filteredVX *= 0.35f;
        filteredVY *= 0.35f;
        filteredAX *= 0.22f;
        filteredAY *= 0.22f;
      }
      filterReady = true;
      lastAppliedTargetSequence = target.sequence;
    }
    lostStartedAtMs = 0;
    searchActive = false;
    const float sizeGain = adaptiveGainFromSize(target);
    const float screenSpeed = hypotf(filteredVX, filteredVY);
    const bool rocketBoost = selectedTrackingMode == "ROCKET" &&
                             (screenSpeed > 80.0f ||
                              fabsf(filteredX - targetCenterX) > 45.0f ||
                              fabsf(filteredY - targetCenterY) > 45.0f);
    const float transportAge = min(age / 1000.0f, 0.08f);
    const float leadSeconds = rocketBoost
                                  ? clampFloat(0.045f + transportAge +
                                                   screenSpeed / 6000.0f,
                                               0.050f, 0.190f)
                                  : clampFloat(0.030f + transportAge, 0.030f,
                                               0.090f);
    const float predictedX = clampFloat(
        filteredX + filteredVX * leadSeconds +
            0.5f * filteredAX * leadSeconds * leadSeconds,
        0.0f, 1000.0f);
    const float predictedY = clampFloat(
        filteredY + filteredVY * leadSeconds +
            0.5f * filteredAY * leadSeconds * leadSeconds,
        0.0f, 1000.0f);
    const float startDeadband = rocketBoost ? Config::FAST_START_DEADBAND
                                            : Config::START_DEADBAND;
    const float stopDeadband = rocketBoost ? Config::FAST_STOP_DEADBAND
                                           : Config::STOP_DEADBAND;
    const float panMax = rocketBoost ? Config::ROCKET_BOOST_PAN_SPEED_DPS
                                     : Config::MAX_PAN_SPEED_DPS;
    const float tiltMax = rocketBoost ? Config::ROCKET_BOOST_TILT_SPEED_DPS
                                      : Config::MAX_TILT_SPEED_DPS;
    const float desiredPan = axisDesiredRate(
        predictedX - targetCenterX, filteredVX, Config::PAN_DIRECTION,
        Config::PAN_GEAR_RATIO, panMax,
        sizeGain, startDeadband, stopDeadband, rocketBoost ? 0.390f : 0.235f,
        rocketBoost ? 0.068f : 0.034f, rocketBoost ? 9.0f : 0.0f,
        panMoving);
    const float desiredTilt = axisDesiredRate(
        predictedY - targetCenterY, filteredVY, Config::TILT_DIRECTION,
        Config::TILT_GEAR_RATIO, tiltMax,
        sizeGain, startDeadband, stopDeadband, rocketBoost ? 0.430f : 0.275f,
        rocketBoost ? 0.074f : 0.041f, rocketBoost ? 10.0f : 0.0f,
        tiltMoving);
    const float panAccel = rocketBoost ? Config::ROCKET_BOOST_PAN_ACCEL_DPS2
                                       : Config::MAX_PAN_ACCEL_DPS2;
    const float tiltAccel = rocketBoost ? Config::ROCKET_BOOST_TILT_ACCEL_DPS2
                                        : Config::MAX_TILT_ACCEL_DPS2;
    const float panLimit = fabsf(desiredPan) < fabsf(panRate)
                               ? Config::MAX_DECEL_DPS2
                               : panAccel;
    const float tiltLimit = fabsf(desiredTilt) < fabsf(tiltRate)
                                 ? Config::MAX_DECEL_DPS2
                                 : tiltAccel;
    panRate = updateJerkLimitedRate(
        panRate, desiredPan, panAcceleration, panLimit,
        Config::MAX_DECEL_DPS2,
        rocketBoost ? Config::ROCKET_BOOST_PAN_JERK_DPS3
                    : Config::MAX_PAN_JERK_DPS3,
        dt);
    tiltRate = updateJerkLimitedRate(
        tiltRate, desiredTilt, tiltAcceleration, tiltLimit,
        Config::MAX_DECEL_DPS2,
        rocketBoost ? Config::ROCKET_BOOST_TILT_JERK_DPS3
                    : Config::MAX_TILT_JERK_DPS3,
        dt);
  } else if (targetLooksLocked) {
    // First confirming frame: hold position instead of starting a search.  A
    // second independent frame will promote it to a real lock.
    searchActive = false;
    holdServos(dt);
    return;
  } else if (weakTrack) {
    if (lostStartedAtMs == 0) lostStartedAtMs = nowMs;
    searchActive = true;
    const float elapsed = (nowMs - lostStartedAtMs) / 1000.0f;
    const bool rocketSearch = selectedTrackingMode == "ROCKET";
    if (hypotf(filteredVX, filteredVY) < 28.0f) {
      searchActive = false;
      holdServos(dt);
      return;
    }
    const float predictionLimit = rocketSearch ? 0.62f : 0.42f;
    const float outputSearchSpeed =
        rocketSearch ? 125.0f : Config::SEARCH_SPEED_LIMIT_DPS;
    const float panSearchSpeed = min(
        outputSearchSpeed * Config::PAN_GEAR_RATIO,
        rocketSearch ? Config::ROCKET_BOOST_PAN_SPEED_DPS
                     : Config::MAX_PAN_SPEED_DPS);
    const float tiltSearchSpeed = min(
        outputSearchSpeed * Config::TILT_GEAR_RATIO,
        rocketSearch ? Config::ROCKET_BOOST_TILT_SPEED_DPS
                     : Config::MAX_TILT_SPEED_DPS);
    const float coastTime = min(elapsed, predictionLimit);
    const float predictedX = filteredX + filteredVX * coastTime +
                             0.5f * filteredAX * coastTime * coastTime;
    const float predictedY = filteredY + filteredVY * coastTime +
                             0.5f * filteredAY * coastTime * coastTime;
    const float desiredPan = clampFloat(
        Config::PAN_DIRECTION * Config::PAN_GEAR_RATIO *
            ((predictedX - targetCenterX) * (rocketSearch ? 0.205f : 0.115f) +
             filteredVX * (rocketSearch ? 0.034f : 0.018f)),
        -panSearchSpeed, panSearchSpeed);
    const float desiredTilt = clampFloat(
        Config::TILT_DIRECTION * Config::TILT_GEAR_RATIO *
            ((predictedY - targetCenterY) * (rocketSearch ? 0.220f : 0.105f) +
             filteredVY * (rocketSearch ? 0.038f : 0.016f)),
        -tiltSearchSpeed, tiltSearchSpeed);
    panRate = updateJerkLimitedRate(
        panRate, desiredPan, panAcceleration,
        rocketSearch ? Config::ROCKET_BOOST_PAN_ACCEL_DPS2 * 0.65f
                     : Config::MAX_PAN_ACCEL_DPS2 * 0.55f,
        Config::MAX_DECEL_DPS2,
        rocketSearch ? Config::ROCKET_BOOST_PAN_JERK_DPS3
                     : Config::MAX_PAN_JERK_DPS3,
        dt);
    tiltRate = updateJerkLimitedRate(
        tiltRate, desiredTilt, tiltAcceleration,
        rocketSearch ? Config::ROCKET_BOOST_TILT_ACCEL_DPS2 * 0.65f
                     : Config::MAX_TILT_ACCEL_DPS2 * 0.55f,
        Config::MAX_DECEL_DPS2,
        rocketSearch ? Config::ROCKET_BOOST_TILT_JERK_DPS3
                     : Config::MAX_TILT_JERK_DPS3,
        dt);
  } else {
    if (lostStartedAtMs == 0) lostStartedAtMs = nowMs;
    if (nowMs - lostStartedAtMs > Config::SEARCH_LIMIT_MS) {
      searchActive = false;
      holdServos(dt);
      return;
    }
    searchActive = filterReady;
    if (filterReady && hypotf(filteredVX, filteredVY) >= 30.0f) {
      const float panSearchSpeed = min(
          Config::SEARCH_SPEED_LIMIT_DPS * Config::PAN_GEAR_RATIO,
          Config::MAX_PAN_SPEED_DPS);
      const float tiltSearchSpeed = min(
          Config::SEARCH_SPEED_LIMIT_DPS * Config::TILT_GEAR_RATIO,
          Config::MAX_TILT_SPEED_DPS);
      const float coastPan = clampFloat(
          Config::PAN_DIRECTION * Config::PAN_GEAR_RATIO * filteredVX * 0.018f,
          -panSearchSpeed, panSearchSpeed);
      const float coastTilt = clampFloat(
          Config::TILT_DIRECTION * Config::TILT_GEAR_RATIO * filteredVY * 0.016f,
          -tiltSearchSpeed, tiltSearchSpeed);
      panRate = updateJerkLimitedRate(
          panRate, coastPan, panAcceleration, Config::MAX_PAN_ACCEL_DPS2 * 0.4f,
          Config::MAX_DECEL_DPS2, Config::MAX_PAN_JERK_DPS3, dt);
      tiltRate = updateJerkLimitedRate(
          tiltRate, coastTilt, tiltAcceleration,
          Config::MAX_TILT_ACCEL_DPS2 * 0.4f, Config::MAX_DECEL_DPS2,
          Config::MAX_TILT_JERK_DPS3, dt);
    } else {
      holdServos(dt);
      return;
    }
  }

  panAngle += panRate * dt;
  tiltAngle += tiltRate * dt;
}

void runServoController() {
  const uint32_t nowUs = micros();
  if (nowUs - lastControlAtUs < Config::CONTROL_PERIOD_US) return;
  const float dt = lastControlAtUs == 0
                       ? 0.02f
                       : clampFloat((nowUs - lastControlAtUs) / 1000000.0f,
                                    0.010f, 0.050f);
  lastControlAtUs = nowUs;
  const uint32_t nowMs = millis();

  TargetPacket target;
  portENTER_CRITICAL(&targetMux);
  target = latestTarget;
  portEXIT_CRITICAL(&targetMux);

  if (homeRequested) {
    runHome(dt);
  } else if (centerCalibrationActive) {
    updateCenterCalibration(dt, target, nowMs);
  } else if (sessionArmed && !enrollmentActive && alignmentReady &&
             target.valid) {
    runTracking(dt, target, nowMs);
  } else {
    holdServos(dt);
  }

  panAngle = clampFloat(panAngle, Config::PAN_MIN_DEG, Config::PAN_MAX_DEG);
  tiltAngle = clampFloat(tiltAngle, Config::TILT_MIN_DEG, Config::TILT_MAX_DEG);
  if ((panAngle <= Config::PAN_MIN_DEG && panRate < 0) ||
      (panAngle >= Config::PAN_MAX_DEG && panRate > 0))
    panRate = 0;
  if ((tiltAngle <= Config::TILT_MIN_DEG && tiltRate < 0) ||
      (tiltAngle >= Config::TILT_MAX_DEG && tiltRate > 0))
    tiltRate = 0;
  writeServos();
}

void updateStatusLed() {
  const uint32_t phase = millis() % 1000;
  TargetPacket target;
  portENTER_CRITICAL(&targetMux);
  target = latestTarget;
  portEXIT_CRITICAL(&targetMux);
  bool on = false;
  if (!sessionArmed) {
    on = phase < 70;
  } else if (alignmentReady && target.valid && acceptedVisionLock &&
             target.state == VISION_LOCKED &&
             target.confidence >= Config::MIN_LOCK_CONFIDENCE) {
    on = true;
  } else if (searchActive) {
    on = phase < 90 || (phase > 180 && phase < 270);
  } else {
    on = phase < 180;
  }
  digitalWrite(Config::STATUS_LED_PIN, on ? HIGH : LOW);
}

void publishTelemetry() {
  // Enrollment/refinement/camera-alignment packets already drive their own UI.
  // Suppressing STATE packets here prevents BLE notification collisions from
  // hiding the candidate boxes that the user must tap on the iPhone.
  if (enrollmentActive || centerCalibrationActive) return;
  const uint32_t now = millis();
  if (now - lastTelemetryAtMs < Config::TELEMETRY_PERIOD_MS) return;
  lastTelemetryAtMs = now;
  TargetPacket target;
  portENTER_CRITICAL(&targetMux);
  target = latestTarget;
  portEXIT_CRITICAL(&targetMux);
  const char *state = "IDLE";
  if (homeRequested)
    state = "HOME";
  else if (centerCalibrationActive)
    state = "CALIBRATE";
  else if (searchActive)
    state = "SEARCH";
  else if (sessionArmed && !enrollmentActive && alignmentReady &&
           acceptedVisionLock &&
           target.state == VISION_LOCKED)
    state = "LOCK";
  else if (sessionArmed)
    state = "ACQUIRE";
  const int alignedX = constrain(
      target.x - static_cast<int>(lroundf(targetCenterX)) + 500, 0, 1000);
  const int alignedY = constrain(
      target.y - static_cast<int>(lroundf(targetCenterY)) + 500, 0, 1000);
  char message[112];
  snprintf(message, sizeof(message),
           "STATE,%s,%d,%d,%d,%.1f,%.1f,%d,%d", state, target.confidence,
           alignedX, alignedY, panAngle, tiltAngle, target.width,
           target.height);
  notifyPhone(message);
  if (now - lastSerialLogAtMs >= 750) {
    lastSerialLogAtMs = now;
    Serial.printf("[CTRL] %s conf=%d xy=%d,%d pan=%.1f tilt=%.1f rate=%.1f,%.1f\n",
                  state, target.confidence, target.x, target.y, panAngle,
                  tiltAngle, panRate, tiltRate);
  }
}

void readUsbConsole() {
  while (Serial.available() > 0) {
    const char command = static_cast<char>(tolower(Serial.read()));
    if (command == 'a') armSession();
    else if (command == 's') stopSession();
    else if (command == 'h') requestHome();
    else if (command == 'p') sendMaixCommand("PING");
  }
}

void updateCharging() {
  if (chargeResumePending &&
      static_cast<int32_t>(millis() - chargeResumeAtMs) >= 0) {
    chargeResumePending = false;
    setPhoneCharging(true);
  }
}

void handlePhoneCommand(String command) {
  command.trim();
  command.toUpperCase();
  if (command.startsWith("MODE,")) {
    selectTrackingMode(command.substring(5));
  } else if (command.startsWith("SELECT,")) {
    const String slotText = command.substring(7);
    const int slot = slotText.toInt();
    if (slot > 0 && slot <= 9 && sessionArmed && enrollmentActive) {
      sendMaixCommand("SELECT", String(slot).c_str());
      notifyPhone(String("SELECTION,") + slot + ",REFINE");
      panRate = tiltRate = 0.0f;
      panMoving = tiltMoving = false;
    }
  } else if (command == "ARM" || command == "TRACKING_STARTED" ||
      command == "RECORDING_STARTED") {
    armSession();
  } else if (command == "STOP" || command == "DISARM" ||
             command == "RECORDING_STOPPED" || command == "SEARCH_STOP") {
    stopSession();
  } else if (command == "HOME" || command == "SERVO_HOME") {
    requestHome();
  } else if (command == "CALIBRATE" || command == "CALIBRATE_CENTER" ||
             command == "ALIGN_CENTER") {
    beginCenterCalibration();
  } else if (command == "PING" || command == "APP_READY") {
    notifyPhone("ESP32,SE_GIMBAL,3.2.1");
    notifyPhone("RIG,GEARED,3.20,1.60,90,30,MAIX_TILT_TOP");
    notifyPhone(String("MODE,") + selectedTrackingMode);
    notifyPhone(String("CALIBRATE,SAVED,") + lroundf(targetCenterX) + "," +
                lroundf(targetCenterY));
    sendMaixCommand("MODE", selectedTrackingMode.c_str());
    sendMaixCommand("PING");
  }
  // Old V/W/T coordinate packets are intentionally ignored. MaixCAM is the
  // only authority allowed to steer the servos.
}

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *) override {
    phoneConnected = true;
    Serial.println("[BLE] iPhone connected");
  }
  void onDisconnect(BLEServer *server) override {
    phoneConnected = false;
    portENTER_CRITICAL(&phoneEventMux);
    phoneEventHead = phoneEventTail = 0;
    portEXIT_CRITICAL(&phoneEventMux);
    Serial.println("[BLE] iPhone disconnected");
    server->startAdvertising();
  }
};

class CommandCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) override {
    const String value = characteristic->getValue().c_str();
    if (!value.isEmpty()) handlePhoneCommand(value);
  }
};

void setupBle() {
  BLEDevice::init(Config::DEVICE_NAME);
  BLEDevice::setMTU(185);
  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  BLEService *service = server->createService(Config::SERVICE_UUID);
  eventCharacteristic = service->createCharacteristic(
      Config::EVENT_UUID, BLECharacteristic::PROPERTY_READ |
                              BLECharacteristic::PROPERTY_NOTIFY);
  eventCharacteristic->addDescriptor(new BLE2902());
  eventCharacteristic->setValue("ESP32,SE_GIMBAL,3.2.1");
  BLECharacteristic *commandCharacteristic = service->createCharacteristic(
      Config::COMMAND_UUID, BLECharacteristic::PROPERTY_WRITE |
                                BLECharacteristic::PROPERTY_WRITE_NR);
  commandCharacteristic->setCallbacks(new CommandCallbacks());
  service->start();
  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(Config::SERVICE_UUID);
  advertising->setScanResponse(true);
  advertising->start();
}

void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println("\nSE AI Tracker ESP32 v3.2.1 (geared 3.20/1.60)");
  Serial.println("USB bench: a=ARM, s=STOP, h=HOME, p=PING");
  pinMode(Config::STATUS_LED_PIN, OUTPUT);
  pinMode(Config::PHONE_CHARGE_RELAY_PIN, OUTPUT);
  calibrationPreferences.begin("se-gimbal", false);
  targetCenterX = clampFloat(
      calibrationPreferences.getUShort("centerX", 500), 200.0f, 800.0f);
  targetCenterY = clampFloat(
      calibrationPreferences.getUShort("centerY", 500), 200.0f, 800.0f);
  Serial.printf("[CALIBRATE] saved center=%.0f,%.0f\n", targetCenterX,
                targetCenterY);
  setPhoneCharging(true);

  ESP32PWM::allocateTimer(0);
  ESP32PWM::allocateTimer(1);
  panServo.setPeriodHertz(50);
  tiltServo.setPeriodHertz(50);
  panServo.attach(Config::PAN_SERVO_PIN, Config::SERVO_MIN_US,
                  Config::SERVO_MAX_US);
  tiltServo.attach(Config::TILT_SERVO_PIN, Config::SERVO_MIN_US,
                   Config::SERVO_MAX_US);
  writeServos(true);

  maixSerial.begin(Config::UART_BAUD, SERIAL_8N1, Config::MAIX_RX_PIN,
                   Config::MAIX_TX_PIN);
  setupBle();
  requestHome();
}

void loop() {
  readUsbConsole();
  readMaixUart();
  monitorMaixLink();
  runServoController();
  updateStatusLed();
  updateCharging();
  publishTelemetry();
  flushPhoneNotifications();
  delay(1);
}

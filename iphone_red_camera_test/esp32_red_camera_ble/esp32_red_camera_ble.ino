#include <Arduino.h>
#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <ESP32Servo.h>

// SE Rocket Tracker v2.1
// MaixCAM = vision authority, ESP32 = deterministic servo controller,
// iPhone = recording/control UI. Do not send AI coordinates from the phone.

namespace Config {
constexpr uint8_t PAN_SERVO_PIN = 19;   // horizontal / left-right axis
constexpr uint8_t TILT_SERVO_PIN = 18;  // vertical / up-down axis
constexpr uint8_t MAIX_RX_PIN = 16;     // <- MaixCAM A19 / UART1_TX
constexpr uint8_t MAIX_TX_PIN = 17;     // -> MaixCAM A18 / UART1_RX
constexpr uint8_t STATUS_LED_PIN = 25;
constexpr uint8_t PHONE_CHARGE_RELAY_PIN = 26;

constexpr uint8_t PHONE_CHARGING_LEVEL = HIGH;
constexpr uint8_t PHONE_CHARGE_CUT_LEVEL = LOW;
constexpr uint32_t CHARGE_RESUME_DELAY_MS = 10000;

constexpr float PAN_HOME_DEG = 90.0f;
constexpr float TILT_HOME_DEG = 90.0f;
constexpr float PAN_MIN_DEG = 15.0f;
constexpr float PAN_MAX_DEG = 165.0f;
constexpr float TILT_MIN_DEG = 35.0f;
constexpr float TILT_MAX_DEG = 145.0f;
constexpr float PAN_DIRECTION = -1.0f;
constexpr float TILT_DIRECTION = 1.0f;
constexpr int SERVO_MIN_US = 900;
constexpr int SERVO_MAX_US = 2100;

constexpr uint32_t UART_BAUD = 115200;
constexpr uint32_t CONTROL_PERIOD_US = 20000;  // MG995: 50 Hz
constexpr uint32_t TARGET_STALE_MS = 180;
constexpr uint32_t COAST_LIMIT_MS = 420;
constexpr uint32_t SEARCH_LIMIT_MS = 850;
constexpr uint32_t TELEMETRY_PERIOD_MS = 150;

constexpr float START_DEADBAND = 13.0f;  // normalized coordinates, center=500
constexpr float STOP_DEADBAND = 6.0f;
constexpr float MAX_PAN_SPEED_DPS = 155.0f;
constexpr float MAX_TILT_SPEED_DPS = 125.0f;
constexpr float MAX_PAN_ACCEL_DPS2 = 760.0f;
constexpr float MAX_TILT_ACCEL_DPS2 = 620.0f;
constexpr float MAX_DECEL_DPS2 = 1050.0f;
constexpr float HOME_SPEED_DPS = 65.0f;
constexpr float SEARCH_SPEED_LIMIT_DPS = 42.0f;

constexpr int MIN_LOCK_CONFIDENCE = 34;
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
BLECharacteristic *eventCharacteristic = nullptr;
HardwareSerial maixSerial(2);

portMUX_TYPE targetMux = portMUX_INITIALIZER_UNLOCKED;
TargetPacket latestTarget;

volatile bool phoneConnected = false;
bool sessionArmed = false;
bool homeRequested = true;
String selectedTrackingMode = "ROCKET";
bool searchActive = false;
bool panMoving = false;
bool tiltMoving = false;
bool chargeResumePending = false;
bool phoneChargeCut = false;

float panAngle = Config::PAN_HOME_DEG;
float tiltAngle = Config::TILT_HOME_DEG;
float panRate = 0.0f;
float tiltRate = 0.0f;
float filteredX = 500.0f;
float filteredY = 500.0f;
float filteredVX = 0.0f;
float filteredVY = 0.0f;
bool filterReady = false;
uint8_t consistentLockCount = 0;
int previousLockX = 500;
int previousLockY = 500;
int lastPanPulse = -1;
int lastTiltPulse = -1;
uint16_t commandSequence = 0;
uint32_t lostStartedAtMs = 0;
uint32_t lastControlAtUs = 0;
uint32_t lastTelemetryAtMs = 0;
uint32_t lastSerialLogAtMs = 0;
uint32_t chargeResumeAtMs = 0;

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
  eventCharacteristic->setValue(message.c_str());
  eventCharacteristic->notify();
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
  filterReady = false;
  consistentLockCount = 0;
  previousLockX = previousLockY = 500;
  panRate = tiltRate = 0.0f;
  panMoving = tiltMoving = false;
  searchActive = false;
  lostStartedAtMs = 0;
}

void armSession() {
  resetTrackingFilter();
  sessionArmed = true;
  homeRequested = false;
  setPhoneCharging(false);
  chargeResumePending = false;
  sendMaixCommand("MODE", selectedTrackingMode.c_str());
  sendMaixCommand("ARM");
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
  resetTrackingFilter();
  sendMaixCommand("MODE", selectedTrackingMode.c_str());
  notifyPhone(String("MODE,") + selectedTrackingMode);
  notifyPhone(sessionArmed ? "STATE,ACQUIRE,0" : "STATE,IDLE,0");
  Serial.printf("[MODE] %s\n", selectedTrackingMode.c_str());
}

void stopSession() {
  sessionArmed = false;
  resetTrackingFilter();
  sendMaixCommand("DISARM");
  chargeResumePending = true;
  chargeResumeAtMs = millis() + Config::CHARGE_RESUME_DELAY_MS;
  notifyPhone("STATE,IDLE,0");
  Serial.println("[SESSION] STOPPED");
}

void requestHome() {
  sessionArmed = false;
  resetTrackingFilter();
  homeRequested = true;
  sendMaixCommand("HOME");
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

bool lockPacketIsConsistent(const TargetPacket &target) {
  if (target.state != VISION_LOCKED ||
      target.confidence < Config::MIN_LOCK_CONFIDENCE) {
    consistentLockCount = 0;
    return false;
  }
  if (consistentLockCount == 0 ||
      (abs(target.x - previousLockX) <= Config::MAX_LOCK_JUMP &&
       abs(target.y - previousLockY) <= Config::MAX_LOCK_JUMP)) {
    consistentLockCount = min<uint8_t>(consistentLockCount + 1, 20);
  } else {
    consistentLockCount = 1;
  }
  previousLockX = target.x;
  previousLockY = target.y;
  return consistentLockCount >= Config::CONSISTENT_LOCK_PACKETS;
}

float adaptiveGainFromSize(const TargetPacket &target) {
  const float largest = max(target.width, target.height);
  // Very tiny targets are noisier; keep strong response but avoid violent jumps.
  return clampFloat(0.72f + largest / 900.0f, 0.72f, 1.08f);
}

float axisDesiredRate(float error, float velocity, float direction,
                      float maxSpeed, float sizeGain, bool &moving) {
  const float absoluteError = fabsf(error);
  if (moving) {
    if (absoluteError <= Config::STOP_DEADBAND) moving = false;
  } else if (absoluteError >= Config::START_DEADBAND) {
    moving = true;
  }
  if (!moving) return 0.0f;

  const float proportional = error * 0.205f;
  const float feedForward = velocity * 0.028f;
  float desired = direction * (proportional + feedForward) * sizeGain;
  if (absoluteError > 32.0f && fabsf(desired) < 9.0f) {
    desired = copysignf(9.0f, desired);
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
  panRate = moveToward(panRate, desiredPan, Config::MAX_DECEL_DPS2 * dt);
  tiltRate = moveToward(tiltRate, desiredTilt, Config::MAX_DECEL_DPS2 * dt);
  panAngle += panRate * dt;
  tiltAngle += tiltRate * dt;
  if (fabsf(panError) < 0.20f && fabsf(tiltError) < 0.20f &&
      fabsf(panRate) < 0.5f && fabsf(tiltRate) < 0.5f) {
    panAngle = Config::PAN_HOME_DEG;
    tiltAngle = Config::TILT_HOME_DEG;
    panRate = tiltRate = 0.0f;
    homeRequested = false;
    notifyPhone("STATE,HOME_DONE,0");
  }
}

void holdServos(float dt) {
  panRate = moveToward(panRate, 0.0f, Config::MAX_DECEL_DPS2 * dt);
  tiltRate = moveToward(tiltRate, 0.0f, Config::MAX_DECEL_DPS2 * dt);
  panAngle += panRate * dt;
  tiltAngle += tiltRate * dt;
  panMoving = tiltMoving = false;
}

void runTracking(float dt, const TargetPacket &target, uint32_t nowMs) {
  const uint32_t age = nowMs - target.receivedAtMs;
  const bool strongLock = age <= Config::TARGET_STALE_MS &&
                          lockPacketIsConsistent(target);
  const bool weakTrack = age <= Config::COAST_LIMIT_MS &&
                         target.state == VISION_WEAK &&
                         target.confidence >= Config::MIN_WEAK_CONFIDENCE &&
                         filterReady;

  if (strongLock) {
    const float alpha = filterReady ? 0.58f : 1.0f;
    filteredX += alpha * (target.x - filteredX);
    filteredY += alpha * (target.y - filteredY);
    filteredVX += 0.42f * (target.velocityX - filteredVX);
    filteredVY += 0.42f * (target.velocityY - filteredVY);
    filterReady = true;
    lostStartedAtMs = 0;
    searchActive = false;
    const float sizeGain = adaptiveGainFromSize(target);
    const float desiredPan = axisDesiredRate(
        filteredX - 500.0f, filteredVX, Config::PAN_DIRECTION,
        Config::MAX_PAN_SPEED_DPS, sizeGain, panMoving);
    const float desiredTilt = axisDesiredRate(
        filteredY - 500.0f, filteredVY, Config::TILT_DIRECTION,
        Config::MAX_TILT_SPEED_DPS, sizeGain, tiltMoving);
    const float panLimit = fabsf(desiredPan) < fabsf(panRate)
                               ? Config::MAX_DECEL_DPS2
                               : Config::MAX_PAN_ACCEL_DPS2;
    const float tiltLimit = fabsf(desiredTilt) < fabsf(tiltRate)
                                ? Config::MAX_DECEL_DPS2
                                : Config::MAX_TILT_ACCEL_DPS2;
    panRate = moveToward(panRate, desiredPan, panLimit * dt);
    tiltRate = moveToward(tiltRate, desiredTilt, tiltLimit * dt);
  } else if (weakTrack) {
    if (lostStartedAtMs == 0) lostStartedAtMs = nowMs;
    searchActive = true;
    const float elapsed = (nowMs - lostStartedAtMs) / 1000.0f;
    const float predictedX = filteredX + filteredVX * min(elapsed, 0.42f);
    const float predictedY = filteredY + filteredVY * min(elapsed, 0.42f);
    const float desiredPan = clampFloat(
        Config::PAN_DIRECTION * ((predictedX - 500.0f) * 0.085f +
                                 filteredVX * 0.018f),
        -Config::SEARCH_SPEED_LIMIT_DPS, Config::SEARCH_SPEED_LIMIT_DPS);
    const float desiredTilt = clampFloat(
        Config::TILT_DIRECTION * ((predictedY - 500.0f) * 0.075f +
                                  filteredVY * 0.016f),
        -Config::SEARCH_SPEED_LIMIT_DPS, Config::SEARCH_SPEED_LIMIT_DPS);
    panRate = moveToward(panRate, desiredPan,
                         Config::MAX_PAN_ACCEL_DPS2 * 0.55f * dt);
    tiltRate = moveToward(tiltRate, desiredTilt,
                          Config::MAX_TILT_ACCEL_DPS2 * 0.55f * dt);
  } else {
    if (lostStartedAtMs == 0) lostStartedAtMs = nowMs;
    if (nowMs - lostStartedAtMs > Config::SEARCH_LIMIT_MS) {
      searchActive = false;
      holdServos(dt);
      return;
    }
    searchActive = filterReady;
    if (filterReady) {
      panRate = moveToward(
          panRate,
          clampFloat(Config::PAN_DIRECTION * filteredVX * 0.018f,
                     -Config::SEARCH_SPEED_LIMIT_DPS,
                     Config::SEARCH_SPEED_LIMIT_DPS),
          Config::MAX_PAN_ACCEL_DPS2 * 0.4f * dt);
      tiltRate = moveToward(
          tiltRate,
          clampFloat(Config::TILT_DIRECTION * filteredVY * 0.016f,
                     -Config::SEARCH_SPEED_LIMIT_DPS,
                     Config::SEARCH_SPEED_LIMIT_DPS),
          Config::MAX_TILT_ACCEL_DPS2 * 0.4f * dt);
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
  } else if (sessionArmed && target.valid) {
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
  } else if (target.valid && target.state == VISION_LOCKED &&
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
  else if (searchActive)
    state = "SEARCH";
  else if (sessionArmed && target.state == VISION_LOCKED)
    state = "LOCK";
  else if (sessionArmed)
    state = "ACQUIRE";
  char message[96];
  snprintf(message, sizeof(message), "STATE,%s,%d,%d,%d,%.1f,%.1f", state,
           target.confidence, target.x, target.y, panAngle, tiltAngle);
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
  } else if (command == "ARM" || command == "TRACKING_STARTED" ||
      command == "RECORDING_STARTED") {
    armSession();
  } else if (command == "STOP" || command == "DISARM" ||
             command == "RECORDING_STOPPED" || command == "SEARCH_STOP") {
    stopSession();
  } else if (command == "HOME" || command == "SERVO_HOME") {
    requestHome();
  } else if (command == "PING" || command == "APP_READY") {
    notifyPhone("ESP32,SE_GIMBAL,2.2.0");
    notifyPhone(String("MODE,") + selectedTrackingMode);
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
  eventCharacteristic->setValue("ESP32,SE_GIMBAL,2.2.0");
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
  Serial.println("\nSE AI Tracker ESP32 v2.2.0");
  Serial.println("USB bench: a=ARM, s=STOP, h=HOME, p=PING");
  pinMode(Config::STATUS_LED_PIN, OUTPUT);
  pinMode(Config::PHONE_CHARGE_RELAY_PIN, OUTPUT);
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
  runServoController();
  updateStatusLed();
  updateCharging();
  publishTelemetry();
  delay(1);
}

#include <Arduino.h>
#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <ESP32Servo.h>

// ======================= CHÂN KẾT NỐI =======================
// Servo PAN quay trái/phải; servo TILT quay lên/xuống.
constexpr uint8_t PAN_SERVO_PIN = 18;
constexpr uint8_t TILT_SERVO_PIN = 19;
constexpr uint8_t STATUS_LED_PIN = 25;
constexpr uint8_t PHONE_CHARGE_RELAY_PIN = 26;

// LED ngoài: GPIO25 -> điện trở 220–330 ohm -> chân dài LED; chân ngắn -> GND.
// Relay 5 V kích mức thấp, dùng COM + NC:
//   HIGH = relay nhả, iPhone được sạc.
//   LOW  = relay hút, ngắt sạc iPhone.
constexpr uint8_t PHONE_CHARGING_LEVEL = HIGH;
constexpr uint8_t PHONE_CHARGE_CUT_LEVEL = LOW;
constexpr uint32_t CHARGE_RESUME_DELAY_MS = 10000;

// CẤP NGUỒN SERVO BẰNG NGUỒN 5–6 V RIÊNG, KHÔNG LẤY TỪ CHÂN 3V3.
// Bắt buộc nối chung GND nguồn servo với GND ESP32.

// ======================== CÂN CHỈNH SERVO ========================
constexpr float PAN_CENTER_DEG = 90.0f;
constexpr float TILT_CENTER_DEG = 90.0f;

// Giới hạn giúp giá đỡ không xoắn dây hoặc đập vào khung.
constexpr float PAN_MIN_DEG = 15.0f;
constexpr float PAN_MAX_DEG = 165.0f;
constexpr float TILT_MIN_DEG = 35.0f;
constexpr float TILT_MAX_DEG = 145.0f;

// Nếu servo chạy ngược hướng, đổi 1.0f thành -1.0f ở đúng trục.
constexpr float PAN_DIRECTION = 1.0f;
constexpr float TILT_DIRECTION = 1.0f;

// Giới hạn xung hẹp hơn để tránh MG995 ép vào điểm dừng cơ khí.
constexpr int SERVO_MIN_US = 900;
constexpr int SERVO_MAX_US = 2100;

// ======================== THUẬT TOÁN BÁM ========================
// App gửi x/y từ 000...999; tâm ảnh là 500/500.
constexpr int IMAGE_CENTER = 500;
// Vùng chống rung rất nhỏ quanh tâm (455...545). Ra khỏi vùng này là bám ngay.
constexpr int CENTER_ZONE_HALF = 45;
constexpr int STILL_VELOCITY = 4;
constexpr int ACTIVE_TRACK_CONFIDENCE = 60;  // Sau khi khóa, giữ bám từ 60%.
constexpr int INITIAL_LOCK_CONFIDENCE = 70;  // Khóa mới cần ít nhất 70%.
constexpr int REACQUIRE_CONFIDENCE = 75;  // 00...99.
constexpr uint32_t TRACK_TIMEOUT_MS = 220;
constexpr uint32_t CONTROL_PERIOD_MS = 20;  // Bằng chu kỳ PWM servo 50 Hz.

// Bám đủ nhanh về tâm nhưng vẫn tăng tốc theo ramp để không giật cụm điện thoại.
constexpr float PAN_MAX_SPEED_DPS = 95.0f;
constexpr float TILT_MAX_SPEED_DPS = 75.0f;
constexpr float PAN_MAX_ACCEL_DPS2 = 190.0f;
constexpr float TILT_MAX_ACCEL_DPS2 = 150.0f;
constexpr float VELOCITY_FEEDFORWARD = 0.55f;

// Khi mất mục tiêu, đi tiếp theo vector bay cuối trong 0,9 giây. Nếu vẫn chưa
// thấy, chỉ rà một dải hẹp dọc theo chính quỹ đạo đó, không quét ngẫu nhiên.
constexpr uint32_t TRAJECTORY_LEAD_MS = 600;
constexpr float TRAJECTORY_MAX_PAN_SPEED_DPS = 45.0f;
constexpr float TRAJECTORY_MAX_TILT_SPEED_DPS = 35.0f;
constexpr float SEARCH_ALONG_SPAN_DEG = 8.0f;
constexpr float SEARCH_CROSS_SPAN_DEG = 3.0f;
constexpr float SEARCH_PHASE_SPEED = 1.6f;

constexpr char DEVICE_NAME[] = "RocketTracker-Test";
constexpr char SERVICE_UUID[] = "7E57A000-8E3A-4D6A-9B2B-13B10A000001";
constexpr char EVENT_CHARACTERISTIC_UUID[] =
    "7E57A001-8E3A-4D6A-9B2B-13B10A000001";  // ESP32 -> iPhone
constexpr char STATUS_CHARACTERISTIC_UUID[] =
    "7E57A002-8E3A-4D6A-9B2B-13B10A000001";  // iPhone -> ESP32

Servo panServo;
Servo tiltServo;
BLECharacteristic *eventCharacteristic = nullptr;

volatile bool phoneConnected = false;

portMUX_TYPE trackingMux = portMUX_INITIALIZER_UNLOCKED;
int latestTargetX = IMAGE_CENTER;
int latestTargetY = IMAGE_CENTER;
int latestConfidence = 0;
int latestVelocityX = 0;
int latestVelocityY = 0;
uint32_t latestTargetAtMs = 0;
bool targetAvailable = false;
volatile bool searchMode = false;
volatile bool trackingSessionActive = false;
volatile bool recordingActive = false;
volatile bool targetLockConfirmed = false;

bool phoneChargeIsCut = false;
bool chargeResumePending = false;
uint32_t chargeResumeAtMs = 0;

float panAngleDeg = PAN_CENTER_DEG;
float tiltAngleDeg = TILT_CENTER_DEG;
float panRateDps = 0.0f;
float tiltRateDps = 0.0f;
float searchOriginPanDeg = PAN_CENTER_DEG;
float searchOriginTiltDeg = TILT_CENTER_DEG;
float searchDirectionPan = 0.0f;
float searchDirectionTilt = 0.0f;
float searchPanSpeedDps = 0.0f;
float searchTiltSpeedDps = 0.0f;
float searchPhase = 0.0f;
uint32_t searchStartedAtMs = 0;
uint32_t lastControlAtMs = 0;
uint32_t lastTelemetryPrintAtMs = 0;

float clampFloat(float value, float minimum, float maximum) {
  if (value < minimum) return minimum;
  if (value > maximum) return maximum;
  return value;
}

float approachFloat(float current, float target, float maximumDelta) {
  if (current < target) return min(current + maximumDelta, target);
  if (current > target) return max(current - maximumDelta, target);
  return current;
}

void writeServoAngles() {
  panServo.write(static_cast<int>(lroundf(panAngleDeg)));
  tiltServo.write(static_cast<int>(lroundf(tiltAngleDeg)));
}

void centerServos() {
  panRateDps = 0.0f;
  tiltRateDps = 0.0f;
  panAngleDeg = PAN_CENTER_DEG;
  tiltAngleDeg = TILT_CENTER_DEG;
  writeServoAngles();
  Serial.println("[SERVO] Da dua PAN/TILT ve tam 90/90 do.");
}

void stopTrackingTarget() {
  portENTER_CRITICAL(&trackingMux);
  targetAvailable = false;
  latestConfidence = 0;
  latestVelocityX = 0;
  latestVelocityY = 0;
  portEXIT_CRITICAL(&trackingMux);
  panRateDps = 0.0f;
  tiltRateDps = 0.0f;
}

void startTrajectorySearch(int predictedX, int predictedY, int velocityX,
                           int velocityY) {
  if (targetLockConfirmed) {
    Serial.println("[SEARCH] Bo goi tim cu: muc tieu da khoa.");
    return;
  }
  if (searchMode) return;  // Gói nhắc lại không được đặt lại quỹ đạo từ đầu.
  stopTrackingTarget();
  searchOriginPanDeg = panAngleDeg;
  searchOriginTiltDeg = tiltAngleDeg;
  float directionX = clampFloat(velocityX / 99.0f, -1.0f, 1.0f);
  float directionY = clampFloat(velocityY / 99.0f, -1.0f, 1.0f);
  float magnitude = sqrtf(directionX * directionX + directionY * directionY);

  // Nếu vận tốc cuối quá nhỏ, dùng phía mà mục tiêu vừa lệch khỏi tâm.
  if (magnitude < 0.08f) {
    directionX = clampFloat((predictedX - IMAGE_CENTER) / 500.0f, -1.0f, 1.0f);
    directionY = clampFloat((predictedY - IMAGE_CENTER) / 500.0f, -1.0f, 1.0f);
    magnitude = sqrtf(directionX * directionX + directionY * directionY);
  }
  if (magnitude >= 0.02f) {
    directionX /= magnitude;
    directionY /= magnitude;
  } else {
    directionX = 0.0f;
    directionY = 0.0f;
  }

  searchDirectionPan = PAN_DIRECTION * directionX;
  searchDirectionTilt = TILT_DIRECTION * directionY;
  const float speedFactor = clampFloat(magnitude, 0.20f, 1.0f);
  searchPanSpeedDps = searchDirectionPan * TRAJECTORY_MAX_PAN_SPEED_DPS * speedFactor;
  searchTiltSpeedDps = searchDirectionTilt * TRAJECTORY_MAX_TILT_SPEED_DPS * speedFactor;
  searchPhase = 0.0f;
  searchStartedAtMs = millis();
  searchMode = true;
  Serial.printf(
      "[SEARCH] Theo quy dao x=%d y=%d vx=%d vy=%d | huong %.2f/%.2f\n",
      predictedX, predictedY, velocityX, velocityY, searchDirectionPan,
      searchDirectionTilt);
}

void startSearchPattern() {
  startTrajectorySearch(latestTargetX, latestTargetY, 0, 0);
}

void stopSearchPattern() {
  if (searchMode) Serial.println("[SEARCH] Da tim thay muc tieu, dung quet.");
  searchMode = false;
}

void setPhoneCharging(bool enabled) {
  digitalWrite(PHONE_CHARGE_RELAY_PIN,
               enabled ? PHONE_CHARGING_LEVEL : PHONE_CHARGE_CUT_LEVEL);
  phoneChargeIsCut = !enabled;
  Serial.printf("[SAC] iPhone: %s\n", enabled ? "BAT" : "NGAT");
}

void cutPhoneChargingForRecording() {
  chargeResumePending = false;
  if (!phoneChargeIsCut) setPhoneCharging(false);
}

void schedulePhoneChargingResume() {
  if (!phoneChargeIsCut) return;
  chargeResumeAtMs = millis() + CHARGE_RESUME_DELAY_MS;
  chargeResumePending = true;
  Serial.println("[SAC] Se bat lai sau 10 giay.");
}

void updatePhoneCharging() {
  if (!chargeResumePending) return;
  if (static_cast<int32_t>(millis() - chargeResumeAtMs) < 0) return;
  chargeResumePending = false;
  if (!recordingActive) setPhoneCharging(true);
}

void updateStatusLed() {
  const uint32_t now = millis();

  // Chưa kết nối: chớp ngắn mỗi 2 giây để báo ESP32 đang có nguồn.
  if (!phoneConnected) {
    digitalWrite(STATUS_LED_PIN, (now % 2000U) < 90U ? HIGH : LOW);
    return;
  }

  // Đang tìm lại mục tiêu: nhấp nháy rất nhanh.
  if (searchMode) {
    digitalWrite(STATUS_LED_PIN, ((now / 120U) & 1U) ? HIGH : LOW);
    return;
  }

  bool freshTarget = false;
  portENTER_CRITICAL(&trackingMux);
  freshTarget = targetAvailable && latestConfidence >= ACTIVE_TRACK_CONFIDENCE &&
                now - latestTargetAtMs <= TRACK_TIMEOUT_MS;
  portEXIT_CRITICAL(&trackingMux);

  // Đang bám đúng mục tiêu: sáng liên tục.
  if (trackingSessionActive && freshTarget) {
    digitalWrite(STATUS_LED_PIN, HIGH);
    return;
  }

  // Đã kết nối nhưng đang chờ: nhấp nháy chậm.
  digitalWrite(STATUS_LED_PIN, ((now / 600U) & 1U) ? HIGH : LOW);
}

// Chỉ bỏ qua sai số rất nhỏ quanh tâm để MG995 không rung liên tục.
float shapedAxisError(int error) {
  const int magnitude = abs(error);
  if (magnitude <= CENTER_ZONE_HALF) return 0.0f;

  const float normalized =
      static_cast<float>(magnitude - CENTER_ZONE_HALF) /
      static_cast<float>(IMAGE_CENTER - CENTER_ZONE_HALF);
  // Khởi động nhẹ tại mép vùng giữ rồi tăng dần khi mục tiêu đi xa hơn.
  const float responsive = 0.08f + 0.92f * powf(
      clampFloat(normalized, 0.0f, 1.0f), 0.85f);
  return (error < 0 ? -1.0f : 1.0f) * clampFloat(responsive, 0.0f, 1.0f);
}

void updateServosFromTarget() {
  const uint32_t now = millis();
  if (now - lastControlAtMs < CONTROL_PERIOD_MS) return;

  float deltaSeconds = (now - lastControlAtMs) / 1000.0f;
  lastControlAtMs = now;
  deltaSeconds = clampFloat(deltaSeconds, 0.001f, 0.050f);

  if (phoneConnected && searchMode) {
    const uint32_t searchAgeMs = now - searchStartedAtMs;
    const float leadSeconds =
        min(searchAgeMs, TRAJECTORY_LEAD_MS) / 1000.0f;
    const float predictedPan =
        searchOriginPanDeg + searchPanSpeedDps * leadSeconds;
    const float predictedTilt =
        searchOriginTiltDeg + searchTiltSpeedDps * leadSeconds;

    if (searchAgeMs <= TRAJECTORY_LEAD_MS) {
      panAngleDeg = predictedPan;
      tiltAngleDeg = predictedTilt;
    } else {
      // Rà dọc quỹ đạo; phương vuông góc chỉ lệch rất nhỏ để bù sai số dự đoán.
      searchPhase += SEARCH_PHASE_SPEED * deltaSeconds;
      const float along = SEARCH_ALONG_SPAN_DEG * sinf(searchPhase);
      const float cross = SEARCH_CROSS_SPAN_DEG * sinf(searchPhase * 0.53f);
      panAngleDeg = predictedPan + searchDirectionPan * along -
                    searchDirectionTilt * cross;
      tiltAngleDeg = predictedTilt + searchDirectionTilt * along +
                     searchDirectionPan * cross;
    }
    panAngleDeg = clampFloat(panAngleDeg, PAN_MIN_DEG, PAN_MAX_DEG);
    tiltAngleDeg = clampFloat(tiltAngleDeg, TILT_MIN_DEG, TILT_MAX_DEG);
    writeServoAngles();
    return;
  }

  int targetX;
  int targetY;
  int confidence;
  int velocityX;
  int velocityY;
  uint32_t receivedAt;
  bool available;

  portENTER_CRITICAL(&trackingMux);
  targetX = latestTargetX;
  targetY = latestTargetY;
  confidence = latestConfidence;
  velocityX = latestVelocityX;
  velocityY = latestVelocityY;
  receivedAt = latestTargetAtMs;
  available = targetAvailable;
  portEXIT_CRITICAL(&trackingMux);

  // Mất BLE, độ tin cậy thấp hoặc gói tọa độ quá cũ: giữ nguyên góc hiện tại.
  if (!phoneConnected || !available || confidence < ACTIVE_TRACK_CONFIDENCE ||
      now - receivedAt > TRACK_TIMEOUT_MS) {
    return;
  }

  const int panOffset = targetX - IMAGE_CENTER;
  const int tiltOffset = targetY - IMAGE_CENTER;
  const bool panOutside = abs(panOffset) > CENTER_ZONE_HALF;
  const bool tiltOutside = abs(tiltOffset) > CENTER_ZONE_HALF;

  // Chỉ giữ khi mục tiêu đã gần đúng tâm; ra khỏi vòng tâm là bám ngay.
  if (!panOutside && !tiltOutside) {
    panRateDps = 0.0f;
    tiltRateDps = 0.0f;
    return;
  }

  const float panError = panOutside ? shapedAxisError(panOffset) : 0.0f;
  const float tiltError = tiltOutside ? shapedAxisError(tiltOffset) : 0.0f;
  const float panVelocity =
      panOutside && abs(velocityX) > STILL_VELOCITY
          ? clampFloat(velocityX / 99.0f, -1.0f, 1.0f)
          : 0.0f;
  const float tiltVelocity =
      tiltOutside && abs(velocityY) > STILL_VELOCITY
          ? clampFloat(velocityY / 99.0f, -1.0f, 1.0f)
          : 0.0f;

  const float panCommand = clampFloat(
      panError + panVelocity * VELOCITY_FEEDFORWARD, -1.0f, 1.0f);
  const float tiltCommand = clampFloat(
      tiltError + tiltVelocity * VELOCITY_FEEDFORWARD, -1.0f, 1.0f);

  const float requestedPanRate =
      panOutside ? PAN_DIRECTION * panCommand * PAN_MAX_SPEED_DPS : 0.0f;
  const float requestedTiltRate =
      tiltOutside ? TILT_DIRECTION * tiltCommand * TILT_MAX_SPEED_DPS : 0.0f;

  // Ramp gia tốc để MG995 không giật cụm iPhone khi vừa ra khỏi vùng giữ.
  panRateDps = panOutside
                   ? approachFloat(panRateDps, requestedPanRate,
                                   PAN_MAX_ACCEL_DPS2 * deltaSeconds)
                   : 0.0f;
  tiltRateDps = tiltOutside
                    ? approachFloat(tiltRateDps, requestedTiltRate,
                                    TILT_MAX_ACCEL_DPS2 * deltaSeconds)
                    : 0.0f;

  panAngleDeg += panRateDps * deltaSeconds;
  tiltAngleDeg += tiltRateDps * deltaSeconds;

  panAngleDeg = clampFloat(panAngleDeg, PAN_MIN_DEG, PAN_MAX_DEG);
  tiltAngleDeg = clampFloat(tiltAngleDeg, TILT_MIN_DEG, TILT_MAX_DEG);
  writeServoAngles();
}

void acceptTrackingPacket(int x, int y, int confidence, int velocityX = 0,
                          int velocityY = 0) {
  x = constrain(x, 0, 999);
  y = constrain(y, 0, 999);
  confidence = constrain(confidence, 0, 99);
  velocityX = constrain(velocityX, -99, 99);
  velocityY = constrain(velocityY, -99, 99);

  const int requiredConfidence = searchMode
                                     ? REACQUIRE_CONFIDENCE
                                     : (targetLockConfirmed
                                            ? ACTIVE_TRACK_CONFIDENCE
                                            : INITIAL_LOCK_CONFIDENCE);
  // Khóa đầu cần 70%, tìm lại cần 75%; đã khóa thì tiếp tục bám từ 60%.
  if (confidence < requiredConfidence) {
    if (millis() - lastTelemetryPrintAtMs >= 250) {
      lastTelemetryPrintAtMs = millis();
        Serial.printf("[TRACK] Bo goi %d%% (<%d%%); giu quy dao.\n",
                      confidence, requiredConfidence);
    }
    return;
  }
  stopSearchPattern();
  if (confidence >= INITIAL_LOCK_CONFIDENCE) targetLockConfirmed = true;

  portENTER_CRITICAL(&trackingMux);
  latestTargetX = x;
  latestTargetY = y;
  latestConfidence = confidence;
  latestVelocityX = velocityX;
  latestVelocityY = velocityY;
  latestTargetAtMs = millis();
  targetAvailable = true;
  portEXIT_CRITICAL(&trackingMux);

  const uint32_t now = millis();
  if (now - lastTelemetryPrintAtMs >= 250) {
    lastTelemetryPrintAtMs = now;
    Serial.printf(
        "[TRACK] x=%d y=%d vx=%d vy=%d tin-cay=%d | PAN=%.1f TILT=%.1f\n",
        x,
        y,
        velocityX,
        velocityY,
        confidence,
        panAngleDeg,
        tiltAngleDeg);
  }
}

void handlePhoneMessage(String value) {
  value.trim();
  if (value.length() == 0) return;

  if (value.startsWith("S,")) {
    if (!trackingSessionActive) {
      Serial.println("[SEARCH] Bo goi tim cu vi phien tracking da dung.");
      return;
    }
    if (targetLockConfirmed) {
      Serial.println("[SEARCH] Bo goi tim cu vi muc tieu da khoa >=70%.");
      return;
    }
    int x = IMAGE_CENTER;
    int y = IMAGE_CENTER;
    int velocityX = 0;
    int velocityY = 0;
    if (sscanf(value.c_str(), "S,%d,%d,%d,%d", &x, &y, &velocityX,
               &velocityY) == 4) {
      startTrajectorySearch(constrain(x, 0, 999), constrain(y, 0, 999),
                            constrain(velocityX, -99, 99),
                            constrain(velocityY, -99, 99));
    }
    return;
  }

  if (value.startsWith("T,")) {
    if (!trackingSessionActive) return;
    int x = 0;
    int y = 0;
    int confidence = 0;
    if (sscanf(value.c_str(), "T,%d,%d,%d", &x, &y, &confidence) == 3) {
      acceptTrackingPacket(x, y, confidence);
    }
    return;
  }

  // Gói mới 15 byte từ iPhone: Vxxxyyyccvvvwww. Không có dấu phẩy để luôn
  // vừa payload BLE 20 byte; vẫn giữ nhánh T phía trên cho app cũ.
  if (value.length() == 15 && value.startsWith("V")) {
    if (!trackingSessionActive) return;
    int x = 0;
    int y = 0;
    int confidence = 0;
    int velocityX = 0;
    int velocityY = 0;
    if (sscanf(value.c_str(), "V%3d%3d%2d%3d%3d", &x, &y, &confidence,
               &velocityX, &velocityY) == 5) {
      acceptTrackingPacket(x, y, confidence, velocityX, velocityY);
    }
    return;
  }

  if (value == "TRACKING_STARTED") {
    trackingSessionActive = true;
    targetLockConfirmed = false;
    stopSearchPattern();
    stopTrackingTarget();
  } else if (value == "RECORDING_STARTED") {
    // Không xóa khóa mục tiêu khi camera bắt đầu ghi; tránh servo tìm lại vô cớ.
    trackingSessionActive = true;
    recordingActive = true;
    cutPhoneChargingForRecording();
  } else if (value == "SEARCH_START" || value == "TARGET_LOST") {
    if (!trackingSessionActive) return;
    targetLockConfirmed = false;
    startSearchPattern();
  } else if (value == "TARGET_LOCKED") {
    trackingSessionActive = true;
    targetLockConfirmed = true;
    stopSearchPattern();
    panRateDps = 0.0f;
    tiltRateDps = 0.0f;
  } else if (value == "SEARCH_STOP" || value == "RECORDING_STOPPED" ||
             value == "APP_BACKGROUND" || value == "PROFILE_RESET" ||
             value == "SCAN_CANCELLED") {
    trackingSessionActive = false;
    targetLockConfirmed = false;
    stopSearchPattern();
    stopTrackingTarget();
    if (value == "RECORDING_STOPPED" || value == "APP_BACKGROUND") {
      recordingActive = false;
      schedulePhoneChargingResume();
    }
  }

  Serial.printf("[iPhone -> ESP32] %s\n", value.c_str());
}

class TrackerServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *server) override {
    phoneConnected = true;
    Serial.println("[BLE] iPhone da ket noi; cho lenh tu app SE.");
  }

  void onDisconnect(BLEServer *server) override {
    phoneConnected = false;
    trackingSessionActive = false;
    recordingActive = false;
    targetLockConfirmed = false;
    searchMode = false;
    stopTrackingTarget();
    schedulePhoneChargingResume();
    Serial.println("[BLE] iPhone da ngat; servo giu nguyen goc, dang quang ba lai...");
    BLEDevice::startAdvertising();
  }
};

class PhoneStatusCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) override {
    String value = characteristic->getValue().c_str();
    handlePhoneMessage(value);
  }
};

void setupServos() {
  panServo.setPeriodHertz(50);
  tiltServo.setPeriodHertz(50);
  panServo.attach(PAN_SERVO_PIN, SERVO_MIN_US, SERVO_MAX_US);
  tiltServo.attach(TILT_SERVO_PIN, SERVO_MIN_US, SERVO_MAX_US);
  centerServos();
}

void setupBluetooth() {
  BLEDevice::init(DEVICE_NAME);
  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new TrackerServerCallbacks());

  BLEService *service = server->createService(SERVICE_UUID);

  eventCharacteristic = service->createCharacteristic(
      EVENT_CHARACTERISTIC_UUID,
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  eventCharacteristic->setValue("BOOT");
  eventCharacteristic->addDescriptor(new BLE2902());

  BLECharacteristic *statusCharacteristic = service->createCharacteristic(
      STATUS_CHARACTERISTIC_UUID,
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_WRITE |
          BLECharacteristic::PROPERTY_WRITE_NR);
  statusCharacteristic->setValue("WAITING");
  statusCharacteristic->setCallbacks(new PhoneStatusCallbacks());

  service->start();

  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->setScanResponse(true);
  advertising->setMinPreferred(0x06);
  advertising->setMaxPreferred(0x12);
  BLEDevice::startAdvertising();
}

void setup() {
  Serial.begin(115200);
  pinMode(STATUS_LED_PIN, OUTPUT);
  digitalWrite(STATUS_LED_PIN, LOW);
  pinMode(PHONE_CHARGE_RELAY_PIN, OUTPUT);
  setPhoneCharging(true);

  setupServos();
  setupBluetooth();
  lastControlAtMs = millis();

  Serial.println();
  Serial.println("=== RocketTracker BLE + 2 servo PAN/TILT ===");
  Serial.printf("PAN GPIO %u | TILT GPIO %u | LED GPIO %u | relay sac GPIO %u\n",
                PAN_SERVO_PIN,
                TILT_SERVO_PIN,
                STATUS_LED_PIN,
                PHONE_CHARGE_RELAY_PIN);
  Serial.println("Khong dung nut ARM. Bam bat/dung tren app SE.");
  Serial.println("Lenh Serial: c = dua hai servo ve tam.");
}

void loop() {
  if (Serial.available()) {
    const char command = Serial.read();
    if (command == 'c' || command == 'C') centerServos();
  }

  updatePhoneCharging();
  updateStatusLed();
  updateServosFromTarget();
  delay(2);
}

#include <Arduino.h>
#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <ESP32Servo.h>

#ifndef LED_BUILTIN
#define LED_BUILTIN 2
#endif

// ======================= CHÂN KẾT NỐI =======================
// Servo PAN quay trái/phải; servo TILT quay lên/xuống.
constexpr uint8_t PAN_SERVO_PIN = 18;
constexpr uint8_t TILT_SERVO_PIN = 19;
constexpr uint8_t ARM_BUTTON_PIN = 25;  // Nút nhấn nối GPIO25 với GND.

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

// Servo 50 Hz; giới hạn xung an toàn ban đầu. Chỉ mở rộng khi đã thử cơ khí.
constexpr int SERVO_MIN_US = 600;
constexpr int SERVO_MAX_US = 2400;

// ======================== THUẬT TOÁN BÁM ========================
// App gửi x/y từ 000...999; tâm ảnh là 500/500.
constexpr int IMAGE_CENTER = 500;
constexpr int DEAD_ZONE = 35;          // 3,5% quanh tâm: servo đứng yên để khỏi rung.
// App dùng ngưỡng 60%. Chỉ gói T có confidence >= 60 mới được phép dừng tìm
// và điều khiển servo; gói yếu hơn không được làm mất vector tìm cuối.
constexpr int LOCK_CONFIDENCE = 60;    // 00...99.
constexpr uint32_t TRACK_TIMEOUT_MS = 300;
constexpr uint32_t CONTROL_PERIOD_MS = 20;  // Điều khiển servo 50 lần/giây.

// Tốc độ góc tối đa; giảm nếu giá điện thoại rung, tăng nếu servo đủ khỏe.
constexpr float PAN_MAX_SPEED_DPS = 120.0f;
constexpr float TILT_MAX_SPEED_DPS = 100.0f;

// Khi mất mục tiêu, đi tiếp theo vector bay cuối trong 0,65 giây. Nếu vẫn chưa
// thấy, chỉ rà một dải hẹp dọc theo chính quỹ đạo đó, không quét ngẫu nhiên.
constexpr uint32_t TRAJECTORY_LEAD_MS = 650;
constexpr float TRAJECTORY_MAX_PAN_SPEED_DPS = 85.0f;
constexpr float TRAJECTORY_MAX_TILT_SPEED_DPS = 70.0f;
constexpr float SEARCH_ALONG_SPAN_DEG = 10.0f;
constexpr float SEARCH_CROSS_SPAN_DEG = 2.5f;
constexpr float SEARCH_PHASE_SPEED = 3.0f;

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
volatile bool autoArmPending = false;
volatile uint32_t connectedAtMs = 0;

portMUX_TYPE trackingMux = portMUX_INITIALIZER_UNLOCKED;
int latestTargetX = IMAGE_CENTER;
int latestTargetY = IMAGE_CENTER;
int latestConfidence = 0;
uint32_t latestTargetAtMs = 0;
bool targetAvailable = false;
volatile bool searchMode = false;
volatile bool trackingSessionActive = false;

float panAngleDeg = PAN_CENTER_DEG;
float tiltAngleDeg = TILT_CENTER_DEG;
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

uint32_t lastButtonChangeMs = 0;
bool lastButtonReading = HIGH;
bool stableButtonState = HIGH;

float clampFloat(float value, float minimum, float maximum) {
  if (value < minimum) return minimum;
  if (value > maximum) return maximum;
  return value;
}

void writeServoAngles() {
  panServo.write(static_cast<int>(lroundf(panAngleDeg)));
  tiltServo.write(static_cast<int>(lroundf(tiltAngleDeg)));
}

void centerServos() {
  panAngleDeg = PAN_CENTER_DEG;
  tiltAngleDeg = TILT_CENTER_DEG;
  writeServoAngles();
  Serial.println("[SERVO] Da dua PAN/TILT ve tam 90/90 do.");
}

void stopTrackingTarget() {
  portENTER_CRITICAL(&trackingMux);
  targetAvailable = false;
  latestConfidence = 0;
  portEXIT_CRITICAL(&trackingMux);
}

void startTrajectorySearch(int predictedX, int predictedY, int velocityX,
                           int velocityY) {
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

void sendEvent(const char *message) {
  if (!phoneConnected || eventCharacteristic == nullptr) {
    Serial.printf("[BLE] Chua co iPhone, khong gui duoc: %s\n", message);
    return;
  }

  eventCharacteristic->setValue(message);
  eventCharacteristic->notify();
  Serial.printf("[ESP32 -> iPhone] %s\n", message);
}

// Bỏ vùng chết, sau đó chuẩn hóa sai số về -1...1.
float shapedAxisError(int error) {
  const int magnitude = abs(error);
  if (magnitude <= DEAD_ZONE) return 0.0f;

  const float normalized =
      static_cast<float>(magnitude - DEAD_ZONE) /
      static_cast<float>(IMAGE_CENTER - DEAD_ZONE);
  return (error < 0 ? -1.0f : 1.0f) * clampFloat(normalized, 0.0f, 1.0f);
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
  uint32_t receivedAt;
  bool available;

  portENTER_CRITICAL(&trackingMux);
  targetX = latestTargetX;
  targetY = latestTargetY;
  confidence = latestConfidence;
  receivedAt = latestTargetAtMs;
  available = targetAvailable;
  portEXIT_CRITICAL(&trackingMux);

  // Mất BLE, độ tin cậy thấp hoặc gói tọa độ quá cũ: giữ nguyên góc hiện tại.
  if (!phoneConnected || !available || confidence < LOCK_CONFIDENCE ||
      now - receivedAt > TRACK_TIMEOUT_MS) {
    return;
  }

  const float panError = shapedAxisError(targetX - IMAGE_CENTER);
  const float tiltError = shapedAxisError(targetY - IMAGE_CENTER);

  panAngleDeg +=
      PAN_DIRECTION * panError * PAN_MAX_SPEED_DPS * deltaSeconds;
  tiltAngleDeg +=
      TILT_DIRECTION * tiltError * TILT_MAX_SPEED_DPS * deltaSeconds;

  panAngleDeg = clampFloat(panAngleDeg, PAN_MIN_DEG, PAN_MAX_DEG);
  tiltAngleDeg = clampFloat(tiltAngleDeg, TILT_MIN_DEG, TILT_MAX_DEG);
  writeServoAngles();
}

void acceptTrackingPacket(int x, int y, int confidence) {
  x = constrain(x, 0, 999);
  y = constrain(y, 0, 999);
  confidence = constrain(confidence, 0, 99);

  // Điều kiện ưu tiên cao nhất: thấy đúng >=60% thì dừng chuyển động tìm ngay.
  // Nếu confidence thấp hơn, giữ nguyên searchMode và quỹ đạo trước đó.
  if (confidence < LOCK_CONFIDENCE) {
    if (millis() - lastTelemetryPrintAtMs >= 250) {
      lastTelemetryPrintAtMs = millis();
      Serial.printf("[TRACK] Bo goi yeu %d%%; tiep tuc tim theo quy dao.\n",
                    confidence);
    }
    return;
  }
  stopSearchPattern();

  portENTER_CRITICAL(&trackingMux);
  latestTargetX = x;
  latestTargetY = y;
  latestConfidence = confidence;
  latestTargetAtMs = millis();
  targetAvailable = true;
  portEXIT_CRITICAL(&trackingMux);

  const uint32_t now = millis();
  if (now - lastTelemetryPrintAtMs >= 250) {
    lastTelemetryPrintAtMs = now;
    Serial.printf(
        "[TRACK] x=%d y=%d tin-cay=%d | PAN=%.1f TILT=%.1f\n",
        x,
        y,
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

  if (value == "TRACKING_STARTED" || value == "RECORDING_STARTED") {
    trackingSessionActive = true;
    stopSearchPattern();
    stopTrackingTarget();
  } else if (value == "SEARCH_START" || value == "TARGET_LOST") {
    if (!trackingSessionActive) return;
    startSearchPattern();
  } else if (value == "TARGET_LOCKED") {
    trackingSessionActive = true;
    stopSearchPattern();
    stopTrackingTarget();
  } else if (value == "SEARCH_STOP" || value == "RECORDING_STOPPED" ||
             value == "PROFILE_RESET" || value == "SCAN_CANCELLED") {
    trackingSessionActive = false;
    stopSearchPattern();
    stopTrackingTarget();
  }

  Serial.printf("[iPhone -> ESP32] %s\n", value.c_str());
}

class TrackerServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *server) override {
    phoneConnected = true;
    autoArmPending = true;
    connectedAtMs = millis();
    digitalWrite(LED_BUILTIN, HIGH);
    Serial.println("[BLE] iPhone da ket noi. Se gui ARM sau 1,2 giay.");
  }

  void onDisconnect(BLEServer *server) override {
    phoneConnected = false;
    autoArmPending = false;
    trackingSessionActive = false;
    searchMode = false;
    stopTrackingTarget();
    digitalWrite(LED_BUILTIN, LOW);
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
  pinMode(LED_BUILTIN, OUTPUT);
  digitalWrite(LED_BUILTIN, LOW);
  pinMode(ARM_BUTTON_PIN, INPUT_PULLUP);

  setupServos();
  setupBluetooth();
  lastControlAtMs = millis();

  Serial.println();
  Serial.println("=== RocketTracker BLE + 2 servo PAN/TILT ===");
  Serial.printf("PAN GPIO %u | TILT GPIO %u | nut ARM GPIO %u-GND\n",
                PAN_SERVO_PIN,
                TILT_SERVO_PIN,
                ARM_BUTTON_PIN);
  Serial.println("Lenh Serial: a = ARM, c = dua hai servo ve tam.");
}

void loop() {
  if (phoneConnected && autoArmPending && millis() - connectedAtMs >= 1200) {
    autoArmPending = false;
    sendEvent("ARM");
  }

  const bool buttonReading = digitalRead(ARM_BUTTON_PIN);
  if (buttonReading != lastButtonReading) {
    lastButtonChangeMs = millis();
    lastButtonReading = buttonReading;
  }

  if (millis() - lastButtonChangeMs > 30 &&
      buttonReading != stableButtonState) {
    stableButtonState = buttonReading;
    if (stableButtonState == LOW) sendEvent("ARM");
  }

  if (Serial.available()) {
    const char command = Serial.read();
    if (command == 'a' || command == 'A') sendEvent("ARM");
    if (command == 'c' || command == 'C') centerServos();
  }

  updateServosFromTarget();
  delay(2);
}

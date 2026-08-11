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
constexpr int MIN_CONFIDENCE = 12;     // 00...99.
constexpr uint32_t TRACK_TIMEOUT_MS = 300;
constexpr uint32_t CONTROL_PERIOD_MS = 20;  // Điều khiển servo 50 lần/giây.

// Tốc độ góc tối đa; giảm nếu giá điện thoại rung, tăng nếu servo đủ khỏe.
constexpr float PAN_MAX_SPEED_DPS = 120.0f;
constexpr float TILT_MAX_SPEED_DPS = 100.0f;

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

float panAngleDeg = PAN_CENTER_DEG;
float tiltAngleDeg = TILT_CENTER_DEG;
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
  if (!phoneConnected || !available || confidence < MIN_CONFIDENCE ||
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

  portENTER_CRITICAL(&trackingMux);
  latestTargetX = x;
  latestTargetY = y;
  latestConfidence = confidence;
  latestTargetAtMs = millis();
  targetAvailable = confidence >= MIN_CONFIDENCE;
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

  if (value.startsWith("T,")) {
    int x = 0;
    int y = 0;
    int confidence = 0;
    if (sscanf(value.c_str(), "T,%d,%d,%d", &x, &y, &confidence) == 3) {
      acceptTrackingPacket(x, y, confidence);
    }
    return;
  }

  if (value == "TARGET_LOST" || value == "RECORDING_STOPPED") {
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

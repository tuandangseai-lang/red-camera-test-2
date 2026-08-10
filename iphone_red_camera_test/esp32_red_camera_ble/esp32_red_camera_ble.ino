#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>

#ifndef LED_BUILTIN
#define LED_BUILTIN 2
#endif

// Có thể nối một nút nhấn giữa GPIO 25 và GND để gửi lại lệnh ARM.
// Không nối nút vẫn dùng được: ESP32 tự gửi ARM sau khi iPhone kết nối.
constexpr uint8_t ARM_BUTTON_PIN = 25;

constexpr char DEVICE_NAME[] = "RocketTracker-Test";
constexpr char SERVICE_UUID[] = "7E57A000-8E3A-4D6A-9B2B-13B10A000001";
constexpr char EVENT_CHARACTERISTIC_UUID[] =
    "7E57A001-8E3A-4D6A-9B2B-13B10A000001";  // ESP32 -> iPhone
constexpr char STATUS_CHARACTERISTIC_UUID[] =
    "7E57A002-8E3A-4D6A-9B2B-13B10A000001";  // iPhone -> ESP32

BLECharacteristic *eventCharacteristic = nullptr;

volatile bool phoneConnected = false;
volatile bool autoArmPending = false;
volatile unsigned long connectedAtMs = 0;
unsigned long lastButtonChangeMs = 0;
bool lastButtonReading = HIGH;
bool stableButtonState = HIGH;

void sendEvent(const char *message) {
  if (!phoneConnected || eventCharacteristic == nullptr) {
    Serial.printf("[BLE] Chua co iPhone, khong gui duoc: %s\n", message);
    return;
  }

  eventCharacteristic->setValue(message);
  eventCharacteristic->notify();
  Serial.printf("[ESP32 -> iPhone] %s\n", message);
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
    digitalWrite(LED_BUILTIN, LOW);
    Serial.println("[BLE] iPhone da ngat ket noi, dang quang ba lai...");
    BLEDevice::startAdvertising();
  }
};

class PhoneStatusCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) override {
    String value = characteristic->getValue().c_str();
    value.trim();
    if (value.length() == 0) return;

    Serial.printf("[iPhone -> ESP32] %s\n", value.c_str());

    // Nháy LED ngắn để nhìn thấy iPhone đang phản hồi trạng thái qua BLE.
    digitalWrite(LED_BUILTIN, LOW);
    delay(35);
    digitalWrite(LED_BUILTIN, phoneConnected ? HIGH : LOW);
  }
};

void setup() {
  Serial.begin(115200);
  pinMode(LED_BUILTIN, OUTPUT);
  digitalWrite(LED_BUILTIN, LOW);
  pinMode(ARM_BUTTON_PIN, INPUT_PULLUP);

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
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_WRITE);
  statusCharacteristic->setValue("WAITING");
  statusCharacteristic->setCallbacks(new PhoneStatusCallbacks());

  service->start();

  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->setScanResponse(true);
  advertising->setMinPreferred(0x06);
  advertising->setMaxPreferred(0x12);
  BLEDevice::startAdvertising();

  Serial.println();
  Serial.println("=== RocketTracker BLE camera test ===");
  Serial.println("Ten BLE: RocketTracker-Test");
  Serial.println("Mo app iPhone. ESP32 se tu gui ARM khi ket noi.");
  Serial.println("Co the nhan nut GPIO25-GND hoac go 'a' trong Serial Monitor de gui ARM lai.");
}

void loop() {
  if (phoneConnected && autoArmPending && millis() - connectedAtMs >= 1200) {
    autoArmPending = false;
    sendEvent("ARM");
  }

  bool buttonReading = digitalRead(ARM_BUTTON_PIN);
  if (buttonReading != lastButtonReading) {
    lastButtonChangeMs = millis();
    lastButtonReading = buttonReading;
  }

  if (millis() - lastButtonChangeMs > 30 && buttonReading != stableButtonState) {
    stableButtonState = buttonReading;
    if (stableButtonState == LOW) sendEvent("ARM");
  }

  if (Serial.available()) {
    char command = Serial.read();
    if (command == 'a' || command == 'A') sendEvent("ARM");
  }

  delay(5);
}

# Bản thử ESP32 + iPhone nhận màu đỏ, quay và zoom

## Bản thử này làm gì?

1. ESP32 phát BLE với tên `RocketTracker-Test`.
2. App iPhone tự tìm và kết nối ESP32, không cần ghép đôi trong phần Cài đặt Bluetooth.
3. Sau khi kết nối, ESP32 gửi lệnh `ARM` để app bắt đầu tìm màu đỏ.
4. Khi màu đỏ chiếm ít nhất khoảng 2,5% vùng hình trong 4 khung phân tích liên tiếp, app bắt đầu quay.
5. Video giữ 1× trong 5 giây, zoom dần 1× → 2× trong 2,5 giây, rồi 2× → 1× trong 2,5 giây.
6. Nhấn **Dừng và lưu video** để lưu vào ứng dụng Ảnh.
7. App gửi các trạng thái quay/zoom ngược lại ESP32; có thể xem ở Serial Monitor.

ESP32 không nhìn được màu đỏ vì bản thân nó không có camera. Việc nhận màu đỏ và điều khiển camera chạy trong app iPhone; ESP32 đảm nhiệm lệnh bật nhận diện và nhận phản hồi qua BLE.

## 1. Nạp ESP32

Yêu cầu:

- ESP32 DevKit/NodeMCU ESP32 loại thường.
- Arduino IDE 2.x.
- Cài gói bo mạch **esp32 by Espressif Systems** trong Boards Manager.
- Không cần mua hoặc cài mô-đun Bluetooth rời.

Các bước:

1. Mở file `esp32_red_camera_ble/esp32_red_camera_ble.ino` bằng Arduino IDE.
2. Chọn bo **DOIT ESP32 DEVKIT V1**; nếu không có thì chọn **ESP32 Dev Module**.
3. Chọn đúng cổng COM và nhấn Upload.
4. Mở Serial Monitor ở `115200 baud`.

Không cần nối thêm linh kiện để chạy thử. Nếu muốn có nút gửi lại lệnh `ARM`, nối một nút nhấn giữa `GPIO 25` và `GND`. Cũng có thể gõ chữ `a` trong Serial Monitor.

## 2. Cài app lên iPhone 15

iOS không cho firmware ESP32 tự điều khiển đầy đủ app Camera mặc định. Vì vậy thư mục `ios/RedCameraTest` là một app camera riêng.

- Nếu bạn chỉ có Windows: mở `HUONG_DAN_WINDOWS.md`. GitHub Actions sẽ dùng một máy Mac trực tuyến để tạo IPA, sau đó Sideloadly cài IPA từ Windows.
- Nếu bạn có máy Mac: làm trực tiếp bằng Xcode theo phần dưới đây.

Cách nhanh bằng XcodeGen trên máy Mac:

```bash
brew install xcodegen
cd RedCameraTest
xcodegen generate
open RedCameraTest.xcodeproj
```

Trong Xcode:

1. Chọn target **RedCameraTest** → **Signing & Capabilities** → chọn Apple ID/Team của bạn.
2. Nếu bundle ID bị trùng, đổi `vn.rockettracker.RedCameraTest` thành một tên riêng.
3. Cắm iPhone 15 bằng USB-C, mở khóa máy và bấm **Trust** nếu được hỏi.
4. Chọn iPhone 15 làm thiết bị chạy rồi bấm **Run**.
5. Nếu iPhone yêu cầu, bật **Developer Mode** trong *Cài đặt → Quyền riêng tư & Bảo mật*.
6. Cấp quyền Camera, Microphone, Bluetooth và Thêm vào Ảnh cho app.

Nếu không muốn cài XcodeGen, tạo một project iOS App tên `RedCameraTest` trong Xcode, chọn SwiftUI + Swift, rồi kéo 5 file `.swift` và `Info.plist` trong thư mục `RedCameraTest/RedCameraTest` vào project.

## 3. Trình tự thử

1. Cấp nguồn ESP32 trước và mở Serial Monitor nếu muốn xem log.
2. Mở app **Red Camera Test** trên iPhone; không vào Cài đặt Bluetooth để ghép đôi.
3. Đợi màn hình báo **ESP32 đã bật nhận diện màu đỏ**.
4. Đưa một tấm đỏ tươi đủ lớn vào khung hình, nên chiếm khoảng 5–10% hình và có ánh sáng tốt.
5. Khi app báo đang quay, bỏ tấm đỏ ra và chờ hết chu kỳ 10 giây để nhìn rõ zoom.
6. Nhấn **Dừng và lưu video**, sau đó kiểm tra trong ứng dụng Ảnh.
7. Nhấn **Thử lại** để chạy lượt mới.

Nếu chưa có ESP32 bên cạnh, nút **Bật nhận diện thủ công** vẫn cho phép kiểm tra riêng app iPhone.

## Chỉnh độ nhạy màu đỏ

Trong `CameraController.swift`:

- `ratio >= 0.025`: màu đỏ cần chiếm 2,5% số điểm ảnh được lấy mẫu. Giảm xuống `0.015` nếu vật đỏ nhỏ; tăng lên `0.04` nếu app quay nhầm.
- `consecutiveRedFrames >= 4`: số khung hình đỏ liên tiếp trước khi quay.
- `red >= 150` và các tỷ lệ RGB ngay phía trên quyết định màu nào được tính là đỏ đậm.

Đây là bản kiểm tra quay/zoom/BLE đầu tiên, chưa có servo bám mục tiêu. Sau khi phần này chạy ổn mới nên thêm thuật toán lấy tâm vật đỏ và gửi sai lệch trái/phải, lên/xuống cho hai servo.

# Nối ESP32 với hai servo PAN/TILT

Firmware: `esp32_red_camera_ble/esp32_red_camera_ble.ino`

## Nối dây

| Chức năng | ESP32 / nguồn |
|---|---|
| Dây tín hiệu servo PAN (trái/phải) | GPIO 18 |
| Dây tín hiệu servo TILT (lên/xuống) | GPIO 19 |
| Nút ARM | GPIO 25 nối với GND khi nhấn |
| Dây đỏ của hai servo | Nguồn rời 5–6 V |
| Dây nâu/đen của hai servo | GND nguồn rời |
| GND nguồn servo | Phải nối chung với GND ESP32 |

Không cấp servo từ chân `3V3`. Với hai servo mang iPhone, nên dùng bộ hạ áp 5–6 V chịu được ít nhất khoảng 3 A dòng đỉnh và gắn tụ 1000–2200 µF gần đầu nguồn servo. Hãy tháo điện thoại ra khi thử lần đầu.

## Chuẩn bị Arduino IDE

1. Cài board **esp32 by Espressif Systems**.
2. Trong Library Manager, cài **ESP32Servo** của Kevin Harrington / John K. Bennett.
3. Mở file `.ino`, chọn **ESP32 Dev Module** hoặc **DOIT ESP32 DEVKIT V1**.
4. Chọn đúng COM và Upload.
5. Mở Serial Monitor ở `115200 baud`.

## Cân chỉnh

Các thông số nằm ở đầu file `.ino`:

- `PAN_DIRECTION` hoặc `TILT_DIRECTION`: nếu trục chạy ngược, đổi `1.0f` thành `-1.0f`.
- `PAN_MIN_DEG`, `PAN_MAX_DEG`, `TILT_MIN_DEG`, `TILT_MAX_DEG`: giới hạn cơ khí.
- `PAN_CENTER_DEG`, `TILT_CENTER_DEG`: góc nhìn thẳng ban đầu.
- `DEAD_ZONE`: tăng nếu servo rung quanh tâm.
- `PAN_MAX_SPEED_DPS`, `TILT_MAX_SPEED_DPS`: giảm nếu giá rung; tăng nếu servo theo không kịp.

Gõ `c` trong Serial Monitor để đưa hai servo về tâm; gõ `a` để ESP32 gửi lệnh ARM cho app.

## Cách hoạt động

App iPhone gửi gói `T,xxx,yyy,cc` qua BLE. `xxx/yyy` là tâm mục tiêu từ `000...999`, còn `cc` là độ tin cậy. ESP32 chạy bộ điều khiển vận tốc có vùng chết 50 lần/giây. Nếu mất BLE, độ tin cậy thấp hoặc quá 300 ms không có tọa độ mới, servo giữ nguyên góc thay vì chạy lung tung.

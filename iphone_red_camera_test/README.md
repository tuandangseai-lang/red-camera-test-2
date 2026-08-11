# Rocket Tracker — iPhone 15 + ESP32

Đây là bản thử dùng camera iPhone 15 để **học đúng chiếc tên lửa nước đang chuẩn bị phóng**, khóa mục tiêu, bám theo bằng Apple Vision, quay video và điều khiển zoom. Tên lửa có thể mang bất kỳ màu nào; app không còn dùng điều kiện “màu đỏ”.

## App làm được gì?

1. Quét gần 5 giây để ghi nhớ chi tiết thân tên lửa.
2. Quét xa 5 giây để lấy mẫu khi tên lửa nhỏ hơn trong ảnh.
3. Quét xung quanh 8 giây để lấy thêm nhiều góc nhìn.
4. So hình trong khung với các mẫu đã quét rồi khóa đúng mục tiêu.
5. Dùng `VNTrackObjectRequest` để cập nhật khung và tâm mục tiêu theo từng frame.
6. Quay 1080p 60 fps bằng camera kép: bắt đầu ở camera siêu rộng 0,5×, sau 5 giây chỉ chuyển dần sang camera thường 1× khi mục tiêu vẫn nằm trong vùng an toàn ở giữa ảnh.
7. Gửi tâm mục tiêu về ESP32 bằng BLE theo dạng `T,xxx,yyy,cc` để dùng cho hai servo ở bước tiếp theo.
8. Dùng logo trong `Assets.xcassets/AppIcon.appiconset` làm icon iPhone.
9. Báo bằng giọng Việt và rung nhẹ khi quét xong, sẵn sàng, bắt đầu quay, mất mục tiêu và lưu video.

`xxx` và `yyy` chạy từ `000...999`; `cc` là độ tin cậy từ `00...99`. Firmware ESP32 dùng dữ liệu này để điều khiển servo PAN/TILT và đồng thời in trạng thái ra Serial Monitor.

Giọng báo được bật mặc định. Có thể tắt bằng công tắc **Giọng báo tiếng Việt** trên màn hình. Câu “Bắt đầu quay” có thể được micro ghi vào đầu video; hãy tắt công tắc nếu muốn video hoàn toàn không có lời báo từ điện thoại.

## Cách học một tên lửa

1. Mở app, chờ camera sẵn sàng.
2. Đặt tên lửa gần camera, kéo thanh chỉnh để khung vàng ôm sát thân tên lửa, bấm **Quét gần 5 giây** và xoay nhẹ.
3. Lùi tên lửa ra xa, chỉnh khung nhỏ lại cho ôm sát tên lửa, bấm **Quét xa 5 giây**.
4. Thay đổi góc nhìn hoặc xoay chậm tên lửa, bấm **Quét xung quanh 8 giây**.
5. Trước khi phóng, đặt tên lửa vừa trong khung và bấm **Khóa, bám và bắt đầu quay**. ESP32 cũng có thể gửi lệnh `ARM` để làm bước này.
6. Khi quay xong, bấm **Dừng và lưu video**.

Nên bấm bắt đầu quay khoảng 3 giây trước khi phóng. Như vậy app đã khóa mục tiêu và đang ghi hình trước lúc tên lửa tăng tốc.

Mẫu chỉ được giữ trong bộ nhớ khi app đang mở. Nếu đóng hẳn app hoặc đổi sang chiếc tên lửa khác, bấm **Học lại** và quét lại ba lượt.

## Mẹo để bám tốt hơn

- Khung quét phải ôm sát tên lửa, hạn chế lấy quá nhiều nền trời/tường.
- Quét trong ánh sáng gần giống lúc phóng.
- Khi quét xung quanh, xoay chậm và cho app thấy cả phần mũi, thân, cánh và tem đặc trưng.
- Nên dán một họa tiết tương phản hoặc mã hình học lên thân nếu nhiều tên lửa có hình dáng giống nhau.
- Đặt iPhone đủ xa và dùng khung rộng lúc khóa để tên lửa không thoát khỏi ảnh ngay ở các frame đầu.
- Trong đoạn tăng tốc đầu tiên, camera giữ góc siêu rộng 0,5×. Nếu mất mục tiêu, app tự trở lại 0,5× thay vì tiếp tục phóng lớn sai hướng.

Đây là nhận dạng theo mẫu hình ảnh trong phiên chạy, không phải mô hình Core ML đã được huấn luyện bằng hàng trăm ảnh. Nó phù hợp để thử nhanh; tốc độ phóng quá cao, rung mạnh, vật bị che khuất hoặc nền quá giống nhau vẫn có thể làm mất mục tiêu.

## Nạp ESP32

1. Mở `esp32_red_camera_ble/esp32_red_camera_ble.ino` bằng Arduino IDE 2.x.
2. Cài gói bo **esp32 by Espressif Systems**.
3. Chọn **DOIT ESP32 DEVKIT V1** hoặc **ESP32 Dev Module**, chọn đúng cổng COM và Upload.
4. Mở Serial Monitor ở `115200 baud`.

Không cần mô-đun Bluetooth rời vì ESP32 có BLE sẵn. Có thể nối nút giữa `GPIO 25` và `GND` để gửi `ARM`, hoặc gõ `a` trong Serial Monitor.

Firmware hiện đã điều khiển hai servo PAN/TILT: PAN ở `GPIO 18`, TILT ở `GPIO 19`. Xem sơ đồ nguồn, cách đổi chiều và giới hạn góc trong `HUONG_DAN_2_SERVO.md`.

## Build app trên Windows

Xem `HUONG_DAN_WINDOWS.md`. Quy trình là:

`GitHub Actions build IPA trên máy Mac → tải IPA về Windows → Sideloadly cài lên iPhone 15`

App cần được cấp quyền Camera, Microphone, Bluetooth và thêm video vào Ảnh. Nếu dùng Apple ID miễn phí, chữ ký cài thử thường phải được làm mới định kỳ.

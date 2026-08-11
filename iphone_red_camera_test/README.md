# Rocket Tracker — iPhone 15 + ESP32

Đây là bản thử dùng camera iPhone 15 để **học đúng chiếc tên lửa nước đang chuẩn bị phóng**, khóa mục tiêu, bám theo bằng Apple Vision, quay video và điều khiển zoom. Tên lửa có thể mang bất kỳ màu nào; app không còn dùng điều kiện “màu đỏ”.

## Bản 2.4 — YOLO + tracker + Kalman

- App tự nạp `WaterRocketDetector.mlpackage` khi model đã được huấn luyện.
- YOLO hiệu chỉnh danh tính/vị trí định kỳ; Vision tracker bám các frame xen giữa.
- Một kết quả AI đơn lẻ không được phép đổi mục tiêu. Mục tiêu ở xa quỹ đạo phải
  được xác nhận liên tiếp trước khi tracker chuyển sang.
- Bộ lọc alpha-beta/Kalman làm mượt tọa độ và dự đoán trước tối đa 180 ms để bù
  độ trễ Bluetooth và servo.
- Khi chưa có model, app hiện rõ `Vision dự phòng` và chỉ dùng ứng viên đạt đủ
  phiếu đa góc; đã bỏ bước tách nền không xác thực mỗi 10 frame gây nhảy mục tiêu.
- Công cụ tạo dataset và huấn luyện YOLO26n nằm trong `ai_training/`.

## App làm được gì?

1. Chỉ dùng một lượt **Quét hình dạng**; không còn chia gần, xa và đa hướng.
2. Apple Vision tách vật thể khỏi nền rồi phủ dần lưới tinh thể tam giác lên hình dạng nhìn thấy.
3. Khi các tam giác liên kết và phủ khoảng 80%, app tự hoàn tất việc học.
4. So hình trong khung với các mẫu đã quét rồi khóa đúng mục tiêu.
5. Dùng `VNTrackObjectRequest` để cập nhật khung và tâm mục tiêu theo từng frame.
6. Ưu tiên quay 4K 60 fps bằng camera siêu rộng 0,5×; zoom số mượt tới tối đa 0,98× nhưng không vượt ngưỡng đổi sang camera thường.
7. Gửi tâm mục tiêu về ESP32 bằng BLE theo dạng `T,xxx,yyy,cc` để dùng cho hai servo ở bước tiếp theo.
8. Dùng logo trong `Assets.xcassets/AppIcon.appiconset` làm icon iPhone.
9. Báo bằng giọng Việt và rung nhẹ khi quét xong, sẵn sàng, bắt đầu quay, mất mục tiêu và lưu video.

`xxx` và `yyy` chạy từ `000...999`; `cc` là độ tin cậy từ `00...99`. Firmware ESP32 dùng dữ liệu này để điều khiển servo PAN/TILT và đồng thời in trạng thái ra Serial Monitor.

Giọng báo được bật mặc định. Có thể tắt bằng công tắc **Giọng báo tiếng Việt** trên màn hình. Câu “Bắt đầu quay” có thể được micro ghi vào đầu video; hãy tắt công tắc nếu muốn video hoàn toàn không có lời báo từ điện thoại.

Bản 1.1 (build 3) kiểm tra phiên bản trước khi dùng `displayVideoZoomFactorMultiplier`, nhờ đó biên dịch được với deployment target iOS 17 và vẫn tận dụng hệ số zoom hệ thống trên iOS 18 trở lên.

## Quét hình dạng bằng tinh thể tam giác (bản 1.6)

- Chỉ còn một nút **Quét hình dạng tới 80%**.
- `VNGenerateForegroundInstanceMaskRequest` tách vật thể nổi bật trong khung khỏi nền.
- Các ô tam giác xanh lam–lục xuất hiện liền nhau từ giữa vật thể ra ngoài.
- Tiến độ dựa trên phần hình dạng đã được phủ; không yêu cầu số góc cố định và không hết giờ.
- Khi đạt khoảng 80%, vòng chuyển xanh, hiện dấu kiểm và chữ **ĐÃ PHỦ**.
- Giao diện trên/dưới đã được rút gọn để dành phần lớn màn hình cho hình camera.

Nếu Vision chưa tách được biên rõ, app dùng hình tên lửa gần đúng nằm trong khung để tiến độ không bị đứng mãi. Đây là mặt nạ 2D phục vụ phản hồi và nhận dạng, không phải quét 3D thật.

## Zoom mượt và chất lượng hình (bản 1.3)

- Zoom tối đa 0,98× để không chạm ngưỡng chuyển ống kính ở 1×.
- Ưu tiên định dạng 4K 60 fps; tự lùi về 1080p 60 fps nếu định dạng 4K không khả dụng.
- Bật lấy nét, phơi sáng và cân bằng trắng liên tục khi camera hỗ trợ.
- Vì 0,98× vẫn là phóng lớn kỹ thuật số từ camera siêu rộng, nên cần quay ngoài trời đủ sáng để có chi tiết tốt nhất.

## Cách học một tên lửa

1. Mở app, chờ camera sẵn sàng.
2. Đặt tên lửa trong khung vàng và kéo thanh chỉnh để khung ôm sát vật thể.
3. Bấm **Quét hình dạng tới 80%**, giữ trong khung và có thể xoay nhẹ.
4. Quan sát các tinh thể tam giác nối dần trên hình dạng; app tự báo khi đạt 80%.
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

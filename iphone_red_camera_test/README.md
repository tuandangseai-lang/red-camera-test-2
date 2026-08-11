# Rocket Tracker — iPhone 15 + ESP32

Đây là bản thử dùng camera iPhone 15 để **học đúng chiếc tên lửa nước đang chuẩn bị phóng**, khóa mục tiêu, bám theo bằng Apple Vision, quay video và điều khiển zoom. Tên lửa có thể mang bất kỳ màu nào; app không còn dùng điều kiện “màu đỏ”.

## App làm được gì?

1. Quét gần không giới hạn thời gian để ghi nhớ chi tiết thân tên lửa.
2. Quét xa không giới hạn thời gian để lấy mẫu khi tên lửa nhỏ hơn trong ảnh.
3. Quét xung quanh theo từng chỉ dẫn để lấy thêm nhiều góc nhìn.
4. So hình trong khung với các mẫu đã quét rồi khóa đúng mục tiêu.
5. Dùng `VNTrackObjectRequest` để cập nhật khung và tâm mục tiêu theo từng frame.
6. Ưu tiên quay 4K 60 fps bằng camera siêu rộng 0,5×; zoom số mượt tới tối đa 0,98× nhưng không vượt ngưỡng đổi sang camera thường.
7. Gửi tâm mục tiêu về ESP32 bằng BLE theo dạng `T,xxx,yyy,cc` để dùng cho hai servo ở bước tiếp theo.
8. Dùng logo trong `Assets.xcassets/AppIcon.appiconset` làm icon iPhone.
9. Báo bằng giọng Việt và rung nhẹ khi quét xong, sẵn sàng, bắt đầu quay, mất mục tiêu và lưu video.

`xxx` và `yyy` chạy từ `000...999`; `cc` là độ tin cậy từ `00...99`. Firmware ESP32 dùng dữ liệu này để điều khiển servo PAN/TILT và đồng thời in trạng thái ra Serial Monitor.

Giọng báo được bật mặc định. Có thể tắt bằng công tắc **Giọng báo tiếng Việt** trên màn hình. Câu “Bắt đầu quay” có thể được micro ghi vào đầu video; hãy tắt công tắc nếu muốn video hoàn toàn không có lời báo từ điện thoại.

Bản 1.1 (build 3) kiểm tra phiên bản trước khi dùng `displayVideoZoomFactorMultiplier`, nhờ đó biên dịch được với deployment target iOS 17 và vẫn tận dụng hệ số zoom hệ thống trên iOS 18 trở lên.

## Quét có chỉ dẫn, không hết giờ (bản 1.5)

- Quét gần cần 5 góc tương đối khác nhau, quét xa cần 5 góc và quét xung quanh cần 6 góc.
- Không còn bộ đếm thời gian. App tiếp tục chờ cho tới khi đủ mẫu rồi tự chuyển bước.
- Dòng hướng dẫn lần lượt yêu cầu đưa gần/xa, xoay trái/phải và nghiêng lên/xuống.
- Vòng vàng hiển thị phần trăm và chữ **CHƯA ĐỦ** trong lúc lấy mẫu.
- Khi đạt yêu cầu, vòng chuyển xanh, hiện dấu kiểm và chữ **ĐÃ ĐỦ**.
- Giao diện trên/dưới đã được rút gọn để dành phần lớn màn hình cho hình camera.

Bản 1.5 vẫn dùng `VNFeaturePrintObservation` để tránh cộng liên tục một hình đứng yên, nhưng ngưỡng khác biệt đã được nới vừa phải. Khi ảnh còn quá giống, app giữ nguyên tiến độ và chỉ rõ hướng nên di chuyển tiếp; không còn báo hết thời gian.

## Zoom mượt và chất lượng hình (bản 1.3)

- Zoom tối đa 0,98× để không chạm ngưỡng chuyển ống kính ở 1×.
- Ưu tiên định dạng 4K 60 fps; tự lùi về 1080p 60 fps nếu định dạng 4K không khả dụng.
- Bật lấy nét, phơi sáng và cân bằng trắng liên tục khi camera hỗ trợ.
- Vì 0,98× vẫn là phóng lớn kỹ thuật số từ camera siêu rộng, nên cần quay ngoài trời đủ sáng để có chi tiết tốt nhất.

## Cách học một tên lửa

1. Mở app, chờ camera sẵn sàng.
2. Đặt tên lửa gần camera, kéo thanh chỉnh để khung vàng ôm sát thân tên lửa, bấm **Bắt đầu quét gần** và làm theo chỉ dẫn.
3. Lùi tên lửa ra xa, chỉnh khung nhỏ lại cho ôm sát tên lửa, bấm **Bắt đầu quét xa** và làm theo chỉ dẫn.
4. Bấm **Quét các mặt xung quanh**, rồi xoay chậm theo từng hướng hiện trên màn hình.
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

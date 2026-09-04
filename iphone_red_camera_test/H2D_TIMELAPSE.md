# SE Timelapse cho Bambu Lab H2D

Kiến trúc mới không dùng MaixCAM:

`H2D -> Wi-Fi LAN/MQTT TLS -> ESP32 -> Bluetooth LE -> iPhone SE`

ESP32 chỉ đọc trạng thái máy in. Firmware không gửi lệnh di chuyển, gia nhiệt,
tạm dừng hay dừng máy in.

## Chuẩn bị H2D

1. Trên màn hình H2D, mở **Cài đặt > Mạng**.
2. Bật **LAN Only** và **Developer Mode**.
3. Ghi lại IP, Serial và Access Code của máy in.
4. H2D và ESP32 phải dùng cùng mạng Wi-Fi.

## Nạp ESP32

Mở file:

`esp32_h2d_timelapse_ble/esp32_h2d_timelapse_ble.ino`

Chọn board **ESP32 Dev Module**, đặt **Partition Scheme = Huge APP (3MB No
OTA/1MB SPIFFS)**, cài thư viện **PubSubClient**, sau đó nạp qua USB. Firmware
dùng LED trạng thái ở GPIO 25 và không sử dụng servo.

Firmware v1.1 gửi xác nhận riêng cho từng trường cấu hình. Nếu Bluetooth hụt
một gói, app tự gửi lại tối đa hai lần và báo rõ bước lỗi thay vì chờ vô hạn.

## Dùng app SE

1. Mở SE; ứng dụng đi thẳng vào màn hình **Timelapse H2D**.
2. Căn khung hình iPhone khi màn hình xem trước còn sáng.
3. Nhập Wi-Fi, IP, Serial và Access Code; bấm **Lưu cấu hình vào ESP32**.
4. Khi báo H2D sẵn sàng, bấm **Bật chờ H2D và làm tối màn hình**.
5. Không khóa iPhone và giữ SE ở màn hình trước.
6. Sau khi H2D báo hoàn tất, SE tự ghép ảnh theo số lớp và lưu video vào Ảnh.

Camera iPhone chỉ chạy ngắn ở thời điểm chụp rồi ngủ lại, nên nhẹ và mát hơn
việc quay video liên tục. Nếu cần đầu in đứng cùng một chỗ trong từng ảnh, bật
chế độ timelapse **Smooth** trong Bambu Studio; đổi lại máy in sẽ có thêm chuyển
động đỗ đầu in/prime tower theo thiết lập của Bambu.

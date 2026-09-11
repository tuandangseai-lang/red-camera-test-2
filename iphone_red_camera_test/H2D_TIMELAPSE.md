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
OTA/1MB SPIFFS)**, cài các thư viện **PubSubClient**, **NimBLE-Arduino 2.5.1**
và **Adafruit NeoPixel**, sau đó nạp qua USB. Firmware không sử dụng servo.

## Đấu cụm điều khiển vật lý

- WS2812B: DIN vào **GPIO5** qua điện trở 330 ohm. Firmware gửi đủ 8 vị trí
  nhưng chỉ cho phép 4 LED đầu hoạt động; LED số 5–8 luôn bị ép tắt. Cấp 5V
  riêng cho dải LED và nối chung GND với ESP32.
- Nút nhấn giữ: một chân vào **GPIO27**, chân còn lại vào GND.
- Công tắc xoay 3 nấc: chân chung vào GND; tiếp điểm bên phải vào **GPIO25**,
  tiếp điểm bên trái vào **GPIO26**. Nấc giữa không nối chân nào.
- Biến trở: hai chân ngoài vào 3V3 và GND, chân giữa vào **GPIO34**. Nếu xoay
  theo chiều tăng mà độ sáng lại giảm, đổi chéo hai chân ngoài của biến trở.
  Biến trở luôn hoạt động ở cả ba nấc -1, 0 và +1; vị trí công tắc không khóa
  chức năng chỉnh độ sáng LED và âm lượng cảnh báo trên iPhone.
  Firmware lấy trung vị 15 mẫu ADC rồi kiểm tra thêm cửa sổ 21 lần đọc. Giá trị
  nhiễu rộng sẽ bị bỏ qua và LED giữ mức hợp lệ gần nhất thay vì tắt toàn bộ.
  Biến trở dùng toàn dải và
  có vùng hiệu chỉnh ở hai đầu: vặn hết
  trái là LED tắt và âm lượng 0%; vặn hết phải là độ sáng WS2812B 255/255 và
  âm lượng cảnh báo iPhone 100%, kể cả khi ADC thực tế không đạt đúng 0/4095.

Nấc giữa là chế độ điều khiển bình thường: dải LED luôn bám trạng thái thật của
máy in và iPhone (vàng khi chờ/chuẩn bị, xanh lá theo tiến trình khi đang in,
xanh biển lúc chụp và đỏ khi dừng/lỗi). Nấc phải sáng đỏ tối đa đúng 1 giây rồi kích hoạt
timelapse; ba LED hiệu ứng tăng sáng mượt lần lượt theo tiến trình xanh.
Nấc trái bật đèn flash iPhone liên tục và giữ dải LED màu vàng. Giữ nút GPIO27
để đèn flash iPhone nhấp nháy như cửa trập phim, nhưng cả 4 LED WS2812B vẫn
giữ vàng liên tục. Biến trở đồng thời điều chỉnh
độ sáng dải WS2812B và âm lượng cảnh báo trên iPhone. Khi máy in có lỗi nghiêm
trọng, cả 4 LED nhấp nháy đỏ nhanh; đây là trạng thái duy nhất làm dải LED chớp.

Trong dải 4 LED, LED đầu tiên luôn sáng ổn định theo màu trạng thái hiện tại.
Ba LED sau (số 2–4) tăng sáng lần lượt theo tiến trình xanh khi in. Chờ/chuẩn
bị giữ vàng liên tục; đổi nhựa giữa bản in vẫn giữ tiến trình xanh.

Ở nấc giữa, vẫn có thể bấm nút trên màn hình iPhone để bắt đầu/dừng timelapse
thủ công. Nấc giữa là trung tính nên không tự thoát phiên chụp thủ công. Nếu
nấc phải đã tự mở phiên chụp, gạt trở lại nấc giữa sẽ chỉ kết thúc phiên do
công tắc mở.

Firmware v1.1 gửi xác nhận riêng cho từng trường cấu hình. Nếu Bluetooth hụt
một gói, app tự gửi lại tối đa hai lần và báo rõ bước lỗi thay vì chờ vô hạn.

## Dùng app SE

1. Mở SE; ứng dụng đi thẳng vào màn hình **Timelapse H2D**.
2. Căn khung hình iPhone khi màn hình xem trước còn sáng.
3. Nhập Wi-Fi, IP, Serial và Access Code; bấm **Lưu cấu hình vào ESP32**.
4. Khi báo H2D sẵn sàng, bấm **Bật chờ H2D và làm tối màn hình**.
5. Không khóa iPhone và giữ SE ở màn hình trước.
6. Sau khi H2D báo hoàn tất, SE tự ghép ảnh theo số lớp và lưu video vào Ảnh.

Camera iPhone được giữ sẵn trong phiên timelapse để không trễ khung hình. Nếu
cần đầu in đứng cùng một chỗ trong từng ảnh, bật chế độ timelapse **Smooth**
trong Bambu Studio; đổi lại máy in sẽ có thêm chuyển động đỗ đầu in/prime tower
theo thiết lập của Bambu.

# Cài app lên iPhone 15 chỉ bằng Windows

Bạn không cần có máy Mac. GitHub sẽ cho mượn một máy Mac trực tuyến để biên dịch, còn Windows sẽ cài app vào iPhone bằng Sideloadly.

Quy trình chỉ gồm hai phần:

`GitHub tạo file IPA → Sideloadly cài IPA vào iPhone 15`

## Phần A — Lấy file IPA từ GitHub

### A1. Tạo tài khoản và kho chứa

1. Mở <https://github.com> và đăng ký/đăng nhập.
2. Bấm dấu **+** ở góc trên bên phải → **New repository**.
3. Repository name nhập `red-camera-test`.
4. Chọn **Private** để mã nguồn không công khai.
5. Bấm **Create repository**.

### A2. Đưa bộ mã nguồn lên

1. Giải nén file ZIP mà bạn nhận từ tôi.
2. Trong trang repository mới, bấm **uploading an existing file**. Nếu không thấy, chọn **Add file → Upload files**.
3. Mở thư mục `iphone_red_camera_test` vừa giải nén.
4. Kéo **toàn bộ nội dung bên trong thư mục** vào trang GitHub. Phải có các mục `.github`, `ios`, `esp32_red_camera_ble` và các file hướng dẫn.
5. Chờ tải xong rồi bấm **Commit changes**.

Quan trọng: không chỉ tải riêng thư mục `ios`; GitHub cần file `.github/workflows/build-iphone-app.yml` để hiện nút tạo IPA.

### A3. Bấm tạo IPA

1. Mở thẻ **Actions** ở đầu trang repository.
2. Nếu GitHub hỏi xác nhận, bấm **I understand my workflows, go ahead and enable them**.
3. Ở cột bên trái chọn **Tao file IPA cho iPhone 15**.
4. Bấm **Run workflow** bên phải → bấm nút xanh **Run workflow** lần nữa.
5. Đợi khoảng 3–10 phút. Lần chạy thành công sẽ có dấu tích màu xanh.
6. Bấm vào lần chạy có dấu tích xanh.
7. Kéo xuống phần **Artifacts**, bấm `RedCameraTest-unsigned-ipa` để tải xuống.
8. Giải nén file vừa tải. Bên trong có `RedCameraTest-unsigned.ipa`.

Nếu thấy dấu X đỏ, mở lần chạy đó, bấm vào `Build RedCameraTest` rồi chụp phần chữ đỏ gửi cho tôi; không cần tự sửa.

## Phần B — Cài IPA từ Windows vào iPhone 15

### B1. Cài Sideloadly

1. Tải Sideloadly cho Windows tại <https://sideloadly.io/>.
2. Theo yêu cầu hiện tại của Sideloadly, Windows cần bản iTunes và iCloud tải từ trang Apple, không dùng bản Microsoft Store. Các liên kết nằm ngay cuối trang tải Sideloadly.
3. Cài và mở Sideloadly.

Sideloadly là công cụ bên thứ ba, không phải của Apple. Nếu không muốn nhập Apple ID chính vào công cụ này, hãy tạo một Apple ID phụ chỉ dùng để cài app thử nghiệm.

### B2. Kết nối và cài app

1. Cắm iPhone 15 vào Windows bằng cáp USB-C **có truyền dữ liệu**.
2. Mở khóa iPhone và bấm **Tin cậy/Trust** khi máy hỏi.
3. Trong Sideloadly, kiểm tra iPhone đã xuất hiện trong ô thiết bị.
4. Kéo file `RedCameraTest-unsigned.ipa` vào cửa sổ Sideloadly.
5. Nhập Apple ID dùng để ký app rồi bấm **Start**.
6. Làm theo yêu cầu xác minh hai bước nếu xuất hiện.
7. Đợi Sideloadly báo cài đặt hoàn tất.

Tuyệt đối không gửi mật khẩu hoặc mã xác minh Apple ID cho tôi hay người khác.

### B3. Cho phép app chạy trên iPhone

Nếu app chưa mở được:

1. Vào **Cài đặt → Quyền riêng tư & Bảo mật → Chế độ nhà phát triển**.
2. Bật chế độ này, khởi động lại iPhone và xác nhận bật.
3. Vào **Cài đặt → Cài đặt chung → VPN & Quản lý thiết bị**.
4. Chọn Apple ID dùng để ký app → bấm **Tin cậy**.
5. Mở app **Rocket Tracker**.
6. Cho phép Camera, Microphone, Bluetooth và quyền thêm video vào Ảnh.

## Phần C — Thử với ESP32

1. Nạp file `esp32_red_camera_ble/esp32_red_camera_ble.ino` cho ESP32 trên Windows.
2. Cấp nguồn ESP32.
3. Mở app **Rocket Tracker** trên iPhone 15; không ghép đôi ESP32 trong Cài đặt Bluetooth.
4. App tự tìm thiết bị `RocketTracker-Test`.
5. Quét chính chiếc tên lửa sẽ phóng theo ba lượt: **gần 5 giây → xa 5 giây → xung quanh 8 giây**. Tên lửa có thể là bất kỳ màu nào.
6. Trước khi phóng, căn tên lửa vào khung và bấm **Khóa, bám và bắt đầu quay**; hoặc nhấn nút `GPIO 25` để ESP32 gửi `ARM`.
7. App khóa mục tiêu và bắt đầu quay; sau 5 giây sẽ zoom 1× → 2× → 1×.
8. Bấm **Dừng và lưu video**. Serial Monitor sẽ thấy dữ liệu tâm mục tiêu dạng `T,xxx,yyy,cc`.

## App hết hạn sau 7 ngày thì sao?

Apple ID miễn phí chỉ ký app thử nghiệm trong 7 ngày. Hãy mở Sideloadly trên Windows và cắm/kết nối lại iPhone để Sideloadly làm mới chữ ký. Không cần build lại IPA nếu mã nguồn không thay đổi.

## Ba lỗi thường gặp

- **GitHub không có thẻ Actions:** kiểm tra đã tải lên thư mục `.github/workflows` hay chưa.
- **Sideloadly không thấy iPhone:** đổi cáp USB-C truyền dữ liệu, mở khóa và bấm Trust; kiểm tra iTunes/iCloud bản tải từ Apple.
- **App cài rồi nhưng không mở:** bật Developer Mode và Trust Apple ID trong VPN & Quản lý thiết bị.

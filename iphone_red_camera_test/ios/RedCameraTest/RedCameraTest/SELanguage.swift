import Foundation

enum SEAppLanguage: String, CaseIterable, Identifiable {
    case vietnamese = "vi"
    case english = "en"

    var id: String { rawValue }
    var shortTitle: String { self == .vietnamese ? "TV" : "EN" }
    var locale: Locale { Locale(identifier: rawValue) }
}

/// Translates status sentences that arrive as runtime data from ESP32 or from
/// the camera manager. Literal SwiftUI labels are handled by Localizable.strings;
/// these replacements cover values that cannot be localized by SwiftUI after
/// they have already been assembled into a String.
enum SEStatusCopy {
    static func render(_ source: String, languageCode: String) -> String {
        guard languageCode == SEAppLanguage.english.rawValue else { return source }
        var result = source
        for (vietnamese, english) in replacements {
            result = result.replacingOccurrences(of: vietnamese, with: english)
        }
        return result
    }

    private static let replacements: [(String, String)] = [
        ("Đang tính thời gian còn lại", "Calculating remaining time"),
        ("Thời gian còn lại: dưới 1 phút", "Time remaining: under 1 minute"),
        ("Thời gian còn lại:", "Time remaining:"),
        ("Hoàn thành lúc", "Finishes at"),
        ("đang tự kết nối lại", "is reconnecting automatically"),
        ("không phản hồi • kiểm tra nguồn và IP LAN", "is not responding • check power and LAN IP"),
        ("báo lỗi máy in", "printer error"),
        ("đang có lỗi", "has an error"),
        (" • CÓ LỖI", " • ERROR"),
        (" • CHƯA BẮT ĐẦU", " • NOT STARTED"),
        (" • ĐÃ IN XONG", " • PRINT COMPLETE"),
        (" • ĐANG CHỤP ẢNH", " • CAPTURING"),
        (" • ĐANG DỪNG", " • STOPPING"),
        (" • ĐANG TẠM DỪNG", " • PAUSED"),
        (" • ĐANG IN ", " • PRINTING "),
        ("ESP32 • ĐANG KẾT NỐI", "ESP32 • CONNECTING TO"),
        ("ESP32 • MẤT KẾT NỐI", "ESP32 • DISCONNECTED"),
        ("xem màn hình máy in", "check the printer display"),
        ("có lưu ý HMS", "has an HMS notice"),
        ("đang đồng bộ dữ liệu thời gian thực từ", "Syncing live data from"),
        ("đang đồng bộ trạng thái hiện tại từ", "Syncing current status from"),
        ("Đang xác thực", "Authenticating"),
        ("Đang kết nối", "Connecting to"),
        ("Đã kết nối ESP32", "ESP32 connected"),
        ("Đã kết nối", "Connected to"),
        ("Đang chuyển ESP32 sang", "Switching ESP32 to"),
        ("đang chuyển sang", "switching to"),
        ("Đang chuyển sang", "Switching to"),
        ("Đang chuẩn bị hồ sơ", "Preparing profile"),
        ("Đang gửi hồ sơ", "Sending profile"),
        ("Đã nhận hồ sơ", "Profile received"),
        ("Đã chọn", "Selected"),
        ("đang kiểm tra serial", "checking serial"),
        ("đang nhận dữ liệu máy in", "receiving printer data"),
        ("đang chờ MQTT sẵn sàng", "waiting for MQTT"),
        ("đang xác thực LAN", "authenticating on LAN"),
        ("Đang bật Bluetooth", "Turning on Bluetooth"),
        ("Đang tìm ESP32 Bambu", "Searching for Bambu ESP32"),
        ("Đã thấy ESP32, đang kết nối", "ESP32 found, connecting"),
        ("Đã nối BLE • đang mở kênh Bambu", "BLE connected • opening Bambu channel"),
        ("ESP32 đã ngắt • đang kết nối lại", "ESP32 disconnected • reconnecting"),
        ("ESP32 đã ngắt, đang kết nối lại", "ESP32 disconnected, reconnecting"),
        ("Kết nối lỗi, đang thử lại", "Connection failed, retrying"),
        ("Mạng đã thấy máy in • đang thử kết nối lại", "Printer found on network • retrying"),
        ("ESP32 đang kết nối Wi-Fi", "ESP32 is connecting to Wi-Fi"),
        ("ESP32 đang khởi động", "ESP32 is starting"),
        ("Chưa nhận dữ liệu máy in", "No printer data yet"),
        ("Chưa có cấu hình máy in", "No printer profile"),
        ("iPhone đang chụp ảnh", "iPhone is capturing"),
        ("Chế độ chụp đang hoạt động", "Capture mode is active"),
        ("ESP32 đã nhận chụp • đã lưu", "ESP32 capture armed • saved"),
        ("Đang đồng bộ ESP32 • đã lưu", "Syncing ESP32 • saved"),
        ("chưa bắt đầu • đang theo dõi", "not started • monitoring"),
        ("đã sẵn sàng gửi dữ liệu lớp", "is ready to send layer data"),
        ("đang in lớp", "printing layer"),
        ("Đang in lớp", "Printing layer"),
        ("đang dừng bản in", "is stopping the print"),
        ("đang dừng chụp và ghép ảnh", "stopping capture and rendering"),
        ("đang tạm dừng", "is paused"),
        ("đã in xong", "finished printing"),
        ("Đang chuẩn bị vật liệu", "Preparing material"),
        ("Đang chuẩn bị đầu phun", "Preparing nozzle"),
        ("Đang hiệu chỉnh dòng nhựa", "Calibrating filament flow"),
        ("Đang làm sạch đầu phun", "Cleaning nozzle"),
        ("Đang ổn định nhiệt độ", "Stabilizing temperature"),
        ("Đang làm nóng bàn in", "Heating build plate"),
        ("Đang cân bàn", "Leveling build plate"),
        ("Đang kiểm tra chuyển động", "Checking motion"),
        ("Đang kiểm tra bàn in", "Checking build plate"),
        ("Đang hiệu chỉnh cảm biến", "Calibrating sensors"),
        ("Đang đưa đầu in về gốc", "Homing toolhead"),
        ("Đang hiệu chỉnh động cơ", "Calibrating motors"),
        ("Đang điều hòa buồng in", "Conditioning chamber"),
        ("Đang hiệu chỉnh máy in", "Calibrating printer"),
        ("Đang chuẩn bị in", "Preparing print"),
        ("Đang chuẩn bị", "Preparing"),
        ("Đang tạm dừng", "Paused"),
        ("Đang chọn ảnh lớp", "Selecting frame for layer"),
        ("đang chọn khung không bị đầu in che", "selecting an unobstructed frame"),
        ("camera đang lấy khung hình", "camera is collecting frames"),
        ("Đã lưu ảnh • camera sẵn sàng cho lần chụp kế tiếp", "Photo saved • camera ready for the next capture"),
        ("Chụp ảnh lỗi • chờ tín hiệu tiếp theo", "Capture failed • waiting for the next signal"),
        ("Đang lọc rung và đầu in khỏi video", "Removing shake and toolhead intrusions"),
        ("Đang ghép video", "Rendering video"),
        ("Đang ghép", "Rendering"),
        ("lớp thành video", "layers into a video"),
        ("Đã ghép và lưu timelapse vào Ảnh", "Timelapse rendered and saved to Photos"),
        ("Chế độ timelapse tiết kiệm pin", "Power-saving timelapse mode"),
        ("Camera chưa phát hình • đang thử mở lại", "No camera image • reopening camera"),
        ("Camera đã sẵn sàng • căn khung hình rồi bật chờ máy in", "Camera ready • frame the shot, then arm printer monitoring"),
        ("Căn khung hình rồi bật chờ máy in", "Frame the shot, then arm printer monitoring"),
        ("Đã bật chụp theo lớp • đang chờ", "Layer capture armed • waiting for"),
        ("Đã bật chụp • chờ ESP32 nối lại để đồng bộ", "Capture armed • waiting for ESP32 to reconnect"),
        ("Đã đồng bộ lại chế độ chụp theo lớp", "Layer capture mode resynchronized"),
        ("Đã dừng chụp theo lớp", "Layer capture stopped"),
        ("Đã dừng chờ máy in", "Printer monitoring stopped"),
        ("Đã dừng và xóa ảnh của lần chụp này", "Capture stopped and session photos deleted"),
        ("Đã dừng chụp • đang ghép các ảnh đã có", "Capture stopped • rendering existing photos"),
        ("Máy in đã in xong • đang hoàn tất ảnh cuối", "Print finished • finalizing the last frame"),
        ("Máy in đã xong nhưng chưa có ảnh để ghép", "Print finished, but there are no frames to render"),
        ("Không thể chụp vì SE chưa có quyền Camera", "SE cannot capture without Camera permission"),
        ("Hãy cấp quyền Camera cho SE", "Allow Camera access for SE"),
        ("Hãy cấp quyền thêm video vào Ảnh", "Allow SE to add videos to Photos"),
        ("Không bật được đèn flash của iPhone", "Could not enable iPhone flash"),
        ("Không lưu được video vào Ảnh", "Could not save video to Photos"),
        ("Ghép video chưa thành công", "Video rendering failed"),
        ("Không tạo được video timelapse", "Could not create timelapse video"),
        ("Không đọc được ảnh timelapse", "Could not read timelapse frame"),
        ("Không mở được camera sau của iPhone", "Could not open the rear iPhone camera"),
        ("Không tạo được thư mục ảnh timelapse", "Could not create timelapse frame folder"),
        (" ảnh", " photos"),
        (" phút", " min"),
        (" giờ", " hr")
    ]
}

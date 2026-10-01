import Foundation

// Compare against tag 101, including overlapping phrases and both language
// directions. No timing threshold: shared CI load must not make tests flaky.
let probes = [
    "", "H2D đang in • 38%", "P2S đang in lớp 91/242",
    "H2D đang tạm dừng", "Đang kiểm tra bàn in", "Đang làm nóng bàn in",
    "Máy in đã in xong • đang hoàn tất ảnh cuối",
    "Camera máy in đang phát trực tiếp", "Camera máy in đang tắt",
    "Chạm nút camera để xem máy in trực tiếp", "Camera iPhone",
    "Thiếu IP, serial hoặc Access Code của máy in",
    "MQTT đã nhận gói lệnh • chờ máy in xác nhận",
    "Gia nhiệt đầu trái tới 250°C", "Đã đùn nhựa • Tiếp tục",
    "Đã rút xong • Tiếp tục", "Cảm biến: đã có nhựa", "Cảm biến: chưa có nhựa",
    "Điều khiển", "Giờ in SE tự theo dõi", "Tốc độ in %",
    "Đèn máy in", "Trạng thái bản in", "Nạp đầu trái", "Rút nhựa đầu trái",
    "Đang gửi trực tiếp:", "Chế độ chụp đang hoạt động", "Thử lại",
    "Unknown printer status 0x07FEC00A", "PETG", "753.2 h"
]
var comparisons = 0
for index in 0..<24 {
    for source in probes {
        for language in ["en", "vi"] {
            let decorated = index == 0 ? source : "\(source) • \(index)%"
            let expected = SEBaselineStatusCopy.render(decorated, languageCode: language)
            let actual = SEStatusCopy.render(decorated, languageCode: language)
            precondition(actual == expected, "Localization changed: \(source) / \(language)")
            comparisons += 1
        }
    }
}

func measure(_ render: (String, String) -> String) -> TimeInterval {
    let started = ProcessInfo.processInfo.systemUptime
    var total = 0
    for index in 0..<2_000 {
        total += render(probes[index % 5], "en").count
    }
    precondition(total > 0)
    return ProcessInfo.processInfo.systemUptime - started
}
let referenceTime = measure { SEBaselineStatusCopy.render($0, languageCode: $1) }
let cachedTime = measure { SEStatusCopy.render($0, languageCode: $1) }
print("PASS: \(comparisons) English/Vietnamese results match baseline 101.")
print(String(format: "Repeated status rendering: baseline %.4fs, optimized %.4fs.", referenceTime, cachedTime))

# Huấn luyện AI tên lửa nước

App đã có sẵn đường chạy `YOLO Core ML → Vision tracker → Kalman → ESP32`.
Model Core ML không được tạo giả từ vài ảnh: phải huấn luyện bằng video thật để
không nhận nhầm chai nước, tay người, mây hoặc vật cùng màu.

## 1. Chuẩn bị ảnh trên Windows

```powershell
cd ai_training
py -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r requirements.txt
python extract_video_frames.py D:\rocket-videos --samples-per-second 10
```

Nên quay ít nhất 8-12 video: cầm trên tay, ở bệ, vừa rời bệ, bay trên trời,
xa/gần, nhiều nền và nhiều màu. Giữ lại cả frame nhòe chuyển động.

## 2. Gán nhãn

Dùng CVAT, Roboflow hoặc Ultralytics Platform vẽ **một hộp thật sát tên lửa** và
đặt class `water_rocket`. Chia video theo nhóm vào train/val/test; không chia
ngẫu nhiên các frame kề nhau của cùng một video sang cả train lẫn val vì kết quả
đánh giá sẽ đẹp giả.

Thư mục sau khi xuất YOLO:

```text
dataset/
  images/train, images/val, images/test
  labels/train, labels/val, labels/test
```

Ảnh không có tên lửa vẫn đưa vào `images/train` nhưng không cần file nhãn. Chúng
rất quan trọng: tay người, chai nhựa, bệ phóng, vật đỏ/trắng, mây, chim và cây.

## 3. Huấn luyện

```powershell
python train_water_rocket.py --data water_rocket.yaml --device 0
```

Nếu tên lửa thường rất nhỏ trong ảnh, thử thêm `--p2` sau khi bản nano thường đã
có kết quả chuẩn. Không bật P2 ngay với dataset quá nhỏ.

## 4. Xuất Core ML và đưa vào app

Ultralytics hỗ trợ xuất Core ML trên macOS hoặc Linux x86. Trên Colab/GitHub
runner chạy:

```bash
python train_water_rocket.py \
  --data water_rocket.yaml \
  --export-coreml \
  --app-source ../ios/RedCameraTest/RedCameraTest
```

Tên cuối cùng bắt buộc là:

```text
ios/RedCameraTest/RedCameraTest/WaterRocketDetector.mlpackage
```

XcodeGen sẽ đưa model vào app. Khi app thấy model, dòng trạng thái đổi sang
`YOLO Core ML`; nếu chưa có, app công khai chạy `Vision dự phòng`.

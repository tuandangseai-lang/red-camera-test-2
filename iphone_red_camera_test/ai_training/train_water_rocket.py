"""Huấn luyện detector một lớp và xuất model Core ML cho Rocket Tracker."""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

from ultralytics import YOLO


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", type=Path, default=Path("water_rocket.yaml"))
    parser.add_argument("--epochs", type=int, default=140)
    parser.add_argument("--imgsz", type=int, default=640)
    parser.add_argument("--batch", type=int, default=-1)
    parser.add_argument("--device", default=None, help="0 cho GPU, cpu hoặc để trống")
    parser.add_argument(
        "--p2",
        action="store_true",
        help="Dùng đầu P2 cho tên lửa rất nhỏ; cần nhiều dữ liệu hơn",
    )
    parser.add_argument(
        "--export-coreml",
        action="store_true",
        help="Xuất .mlpackage (chạy trên macOS hoặc Linux x86)",
    )
    parser.add_argument(
        "--app-source",
        type=Path,
        default=None,
        help="Nếu có, chép model vào thư mục RedCameraTest source",
    )
    return parser.parse_args()


def validate_dataset(data_file: Path) -> None:
    if not data_file.exists():
        raise SystemExit(f"Không thấy dataset YAML: {data_file}")
    label_files = list(data_file.parent.rglob("labels/**/*.txt"))
    if len(label_files) < 40:
        raise SystemExit(
            "Dataset còn quá ít nhãn. Cần tối thiểu khoảng 40 file để test; "
            "bản dùng thật nên có hàng trăm frame đa dạng."
        )


def main() -> None:
    args = parse_args()
    data_file = args.data.resolve()
    validate_dataset(data_file)

    if args.p2:
        model = YOLO("yolo26n-p2.yaml").load("yolo26n.pt")
    else:
        model = YOLO("yolo26n.pt")

    train_options = dict(
        data=str(data_file),
        epochs=args.epochs,
        imgsz=args.imgsz,
        batch=args.batch,
        project="runs/water_rocket",
        name="yolo26n_p2" if args.p2 else "yolo26n",
        patience=35,
        close_mosaic=15,
        degrees=18.0,
        translate=0.12,
        scale=0.55,
        fliplr=0.5,
        flipud=0.15,
        hsv_h=0.025,
        hsv_s=0.55,
        hsv_v=0.38,
        cache=True,
        plots=True,
    )
    if args.device:
        train_options["device"] = args.device

    results = model.train(**train_options)
    best = Path(results.save_dir) / "weights" / "best.pt"
    if not best.exists():
        raise SystemExit(f"Không tìm thấy best.pt tại {best}")
    print(f"MODEL TỐT NHẤT: {best.resolve()}")

    if not args.export_coreml:
        return

    exported = Path(
        YOLO(str(best)).export(
            format="coreml",
            imgsz=args.imgsz,
            quantize=8,
            end2end=False,
            nms=True,
        )
    )
    destination = exported.with_name("WaterRocketDetector.mlpackage")
    if destination.exists():
        shutil.rmtree(destination)
    exported.rename(destination)
    print(f"CORE ML: {destination.resolve()}")

    if args.app_source:
        app_destination = args.app_source.resolve() / destination.name
        if app_destination.exists():
            shutil.rmtree(app_destination)
        shutil.copytree(destination, app_destination)
        print(f"ĐÃ CHÉP VÀO APP: {app_destination}")


if __name__ == "__main__":
    main()

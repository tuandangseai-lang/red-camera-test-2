"""Fine-tune detector một lớp cho iPhone và MaixCAM Rocket Tracker."""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

import yaml
from ultralytics import YOLO


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", type=Path, default=Path("water_rocket.yaml"))
    parser.add_argument("--epochs", type=int, default=140)
    parser.add_argument("--imgsz", type=int, default=640)
    parser.add_argument("--batch", type=int, default=-1)
    parser.add_argument("--device", default=None, help="0 cho GPU, cpu hoặc để trống")
    parser.add_argument(
        "--model",
        default="weights/water_rocket_yolo11n_v3.pt",
        help="Checkpoint YOLO11 để fine-tune; nếu không có sẽ dùng yolo11n.pt",
    )
    parser.add_argument("--workers", type=int, default=6)
    parser.add_argument("--name", default="yolo11n_v4")
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
    configuration = yaml.safe_load(data_file.read_text(encoding="utf-8")) or {}
    dataset_root = Path(configuration.get("path", data_file.parent))
    if not dataset_root.is_absolute():
        dataset_root = (data_file.parent / dataset_root).resolve()
    label_files = list((dataset_root / "labels").rglob("*.txt"))
    if len(label_files) < 40:
        raise SystemExit(
            "Dataset còn quá ít nhãn. Cần tối thiểu khoảng 40 file để test; "
            "bản dùng thật nên có hàng trăm frame đa dạng."
        )


def main() -> None:
    args = parse_args()
    data_file = args.data.resolve()
    validate_dataset(data_file)

    model_path = Path(args.model)
    model = YOLO(str(model_path) if model_path.exists() else "yolo11n.pt")

    train_options = dict(
        data=str(data_file),
        epochs=args.epochs,
        imgsz=args.imgsz,
        batch=args.batch,
        project="runs/water_rocket",
        name=args.name,
        patience=35,
        close_mosaic=6,
        degrees=38.0,
        translate=0.10,
        scale=0.44,
        fliplr=0.5,
        flipud=0.5,
        hsv_h=0.018,
        hsv_s=0.34,
        hsv_v=0.28,
        mosaic=0.42,
        mixup=0.0,
        erasing=0.08,
        optimizer="AdamW",
        lr0=0.00018,
        lrf=0.12,
        freeze=5,
        cos_lr=True,
        amp=True,
        cache="disk",
        workers=args.workers,
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

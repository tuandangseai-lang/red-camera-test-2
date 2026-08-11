"""Trích frame từ video thật để gán nhãn tên lửa nước.

Ví dụ trên Windows:
    python extract_video_frames.py D:\rocket-videos --output dataset/images/unlabelled
"""

from __future__ import annotations

import argparse
from pathlib import Path

import cv2


VIDEO_SUFFIXES = {".mov", ".mp4", ".m4v", ".avi"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path, help="Một video hoặc thư mục chứa video")
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("dataset/images/unlabelled"),
        help="Thư mục chứa JPG được trích",
    )
    parser.add_argument(
        "--samples-per-second",
        type=float,
        default=8.0,
        help="Số frame lấy mỗi giây; đoạn phóng nên dùng 8-15",
    )
    parser.add_argument("--jpeg-quality", type=int, default=92)
    parser.add_argument("--maximum-per-video", type=int, default=0)
    return parser.parse_args()


def videos_at(path: Path) -> list[Path]:
    if path.is_file():
        return [path]
    return sorted(
        item for item in path.rglob("*") if item.suffix.lower() in VIDEO_SUFFIXES
    )


def extract(video: Path, output: Path, args: argparse.Namespace) -> int:
    capture = cv2.VideoCapture(str(video))
    if not capture.isOpened():
        print(f"BỎ QUA: không mở được {video}")
        return 0

    fps = capture.get(cv2.CAP_PROP_FPS)
    if not fps or fps <= 0:
        fps = 30.0
    stride = max(1, round(fps / max(0.1, args.samples_per_second)))
    stem = "".join(character if character.isalnum() else "_" for character in video.stem)
    saved = 0
    frame_index = 0

    while True:
        ok, frame = capture.read()
        if not ok:
            break
        if frame_index % stride == 0:
            filename = output / f"{stem}_{frame_index:07d}.jpg"
            cv2.imwrite(
                str(filename),
                frame,
                [cv2.IMWRITE_JPEG_QUALITY, max(60, min(100, args.jpeg_quality))],
            )
            saved += 1
            if args.maximum_per_video and saved >= args.maximum_per_video:
                break
        frame_index += 1

    capture.release()
    print(f"{video.name}: {saved} ảnh")
    return saved


def main() -> None:
    args = parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    videos = videos_at(args.input)
    if not videos:
        raise SystemExit("Không tìm thấy video .mov/.mp4/.m4v/.avi")
    total = sum(extract(video, args.output, args) for video in videos)
    print(f"HOÀN TẤT: {total} ảnh tại {args.output.resolve()}")


if __name__ == "__main__":
    main()

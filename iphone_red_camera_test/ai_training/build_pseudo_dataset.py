"""Build a reviewable water-rocket YOLO dataset from real and open images.

Two independent detectors must normally agree before a user/video frame is
labelled: the existing closed-set SE detector and YOLOE prompted with bottle
rocket terms.  This is intentionally conservative.  The output includes
contact sheets and a JSONL decision log so uncertain labels can be corrected
instead of silently teaching false positives to the next model.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import shutil
from dataclasses import dataclass
from pathlib import Path

import cv2
from ultralytics import YOLO, YOLOE


IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp"}
ROCKET_PROMPTS = ["plastic bottle rocket", "water rocket", "bottle rocket"]
NEGATIVE_PROMPTS = [
    "smartphone", "human hand", "person", "PVC pipe", "plumbing fitting",
    "pressure gauge", "rocket launcher", "water bottle", "plastic bottle",
    "computer screen", "technical drawing", "machine part", "potted plant",
]
ALL_PROMPTS = ROCKET_PROMPTS + NEGATIVE_PROMPTS
SUPPRESSION_PROMPTS = {
    "smartphone", "human hand", "person", "PVC pipe", "plumbing fitting",
    "pressure gauge", "computer screen", "technical drawing", "machine part",
    "potted plant",
}
SUPPRESSION_CLASSES = {
    len(ROCKET_PROMPTS) + index
    for index, prompt in enumerate(NEGATIVE_PROMPTS)
    if prompt in SUPPRESSION_PROMPTS
}


@dataclass
class Box:
    x1: float
    y1: float
    x2: float
    y2: float
    score: float
    source: str

    @property
    def area(self) -> float:
        return max(0.0, self.x2 - self.x1) * max(0.0, self.y2 - self.y1)

    @property
    def center(self) -> tuple[float, float]:
        return (self.x1 + self.x2) * 0.5, (self.y1 + self.y2) * 0.5


def iou(first: Box, second: Box) -> float:
    left = max(first.x1, second.x1)
    top = max(first.y1, second.y1)
    right = min(first.x2, second.x2)
    bottom = min(first.y2, second.y2)
    overlap = max(0.0, right - left) * max(0.0, bottom - top)
    union = first.area + second.area - overlap
    return overlap / union if union > 0.0 else 0.0


def compatible(first: Box, second: Box) -> bool:
    if iou(first, second) >= 0.18:
        return True
    first_cx, first_cy = first.center
    second_cx, second_cy = second.center
    distance = math.hypot(first_cx - second_cx, first_cy - second_cy)
    scale = max(
        12.0,
        first.x2 - first.x1,
        first.y2 - first.y1,
        second.x2 - second.x1,
        second.y2 - second.y1,
    )
    return distance <= scale * 0.36


def nms(boxes: list[Box], threshold: float = 0.50) -> list[Box]:
    kept: list[Box] = []
    for candidate in sorted(boxes, key=lambda item: item.score, reverse=True):
        if all(iou(candidate, previous) < threshold for previous in kept):
            kept.append(candidate)
    return kept


def suppress_competing_prompts(rockets: list[Box], negatives: list[Box]) -> list[Box]:
    """Reject a rocket prompt when a competing ordinary-object prompt wins."""
    kept: list[Box] = []
    for rocket in rockets:
        competitor = max(
            (item.score for item in negatives if compatible(rocket, item)),
            default=0.0,
        )
        # Require a useful margin because transparent bottles and launch pipes
        # are extremely easy for a generic open-vocabulary model to confuse.
        if competitor < max(0.08, rocket.score * 0.72):
            kept.append(rocket)
    return kept


def result_boxes(
    result, source: str, minimum: float, allowed_classes: set[int] | None = None
) -> list[Box]:
    output: list[Box] = []
    if result.boxes is None:
        return output
    for coordinates, confidence, class_id in zip(
        result.boxes.xyxy, result.boxes.conf, result.boxes.cls
    ):
        score = float(confidence)
        if score < minimum or (
            allowed_classes is not None and int(class_id) not in allowed_classes
        ):
            continue
        x1, y1, x2, y2 = (float(value) for value in coordinates)
        output.append(Box(x1, y1, x2, y2, score, source))
    return nms(output)


def clean(box: Box, width: int, height: int) -> Box | None:
    box = Box(
        max(0.0, min(width - 1.0, box.x1)),
        max(0.0, min(height - 1.0, box.y1)),
        max(1.0, min(float(width), box.x2)),
        max(1.0, min(float(height), box.y2)),
        box.score,
        box.source,
    )
    side_x = box.x2 - box.x1
    side_y = box.y2 - box.y1
    area_ratio = box.area / max(1.0, width * height)
    if side_x < 7 or side_y < 7 or area_ratio > 0.91:
        return None
    return box


def fuse(existing: Box, prompted: Box) -> Box:
    existing_weight = max(0.10, existing.score)
    prompted_weight = max(0.10, prompted.score)
    total = existing_weight + prompted_weight
    return Box(
        (existing.x1 * existing_weight + prompted.x1 * prompted_weight) / total,
        (existing.y1 * existing_weight + prompted.y1 * prompted_weight) / total,
        (existing.x2 * existing_weight + prompted.x2 * prompted_weight) / total,
        (existing.y2 * existing_weight + prompted.y2 * prompted_weight) / total,
        min(1.0, existing.score * 0.58 + prompted.score * 0.72 + 0.08),
        "ensemble",
    )


def choose_labels(
    existing: list[Box], prompted: list[Box], *, commons: bool,
    known_positive: bool, video: bool,
) -> tuple[list[Box], str]:
    selected: list[Box] = []
    used_prompted: set[int] = set()
    for old in existing:
        match_index = -1
        match_score = 0.0
        for index, new in enumerate(prompted):
            agreement = iou(old, new)
            if compatible(old, new) and agreement + new.score > match_score:
                match_index = index
                match_score = agreement + new.score
        if match_index >= 0:
            selected.append(fuse(old, prompted[match_index]))
            used_prompted.add(match_index)
        elif old.score >= (0.18 if known_positive else 0.58):
            selected.append(old)

    for index, new in enumerate(prompted):
        if index in used_prompted:
            continue
        threshold = 0.075 if commons else (0.095 if known_positive else 0.35)
        if new.score >= threshold:
            selected.append(new)

    selected = nms(selected, 0.44)
    if video and not known_positive:
        # A single open-vocabulary match was responsible for most of the bad
        # labels (PVC launchers, boats, phones and reflections).  Motion video
        # is only admitted when both independent detectors agree, or when the
        # existing task-specific model is exceptionally confident.
        selected = [
            item for item in selected
            if item.source == "ensemble"
            or (item.source == "closed" and item.score >= 0.78)
        ]
    if not selected:
        return [], "no_consensus"
    return selected[:3], "accepted"


def known_positive(path: Path) -> bool:
    names = {
        "DSC00301.JPG", "DSC00434.JPG", "DSC02123-min.JPG", "DSC04497.JPG",
        "Screenshot 2025-10-14 194916.png", "Screenshot 2025-10-26 161030.png",
        "Screenshot 2025-10-26 164411.png", "Screenshot 2025-10-26 165158.png",
        "Screenshot 2026-01-11 151234.png", "Screenshot 2026-01-11 153639.png",
        "Screenshot 2026-01-12 073401.png", "Screenshot 2026-01-12 073407.png",
        "Screenshot 2026-03-07 125736.png",
    }
    return path.name in names


def excluded_source(path: Path, source_type: str) -> bool:
    if source_type == "user":
        return not known_positive(path)
    if source_type != "video":
        return False
    lowered = path.name.lower()
    # These two source videos document CAD/launcher construction; their pipes,
    # phones and diagrams were the exact hard false positives we want to reject.
    return lowered.startswith("phần_mềm_thiết_kế_") or lowered.startswith("bệ_bắn_")


def split_for(path: Path) -> str:
    # Stable source-level split. Nearby frames from one video share the same
    # prefix and therefore cannot leak into validation as near duplicates.
    stem = path.stem
    group = stem.rsplit("_", 1)[0] if stem.rsplit("_", 1)[-1].isdigit() else stem
    value = int(hashlib.sha1(group.encode("utf-8")).hexdigest()[:8], 16) % 100
    return "train" if value < 78 else "val" if value < 90 else "test"


def write_label(path: Path, boxes: list[Box], width: int, height: int) -> None:
    lines = []
    for box in boxes:
        cx = (box.x1 + box.x2) * 0.5 / width
        cy = (box.y1 + box.y2) * 0.5 / height
        bw = (box.x2 - box.x1) / width
        bh = (box.y2 - box.y1) / height
        lines.append(f"0 {cx:.7f} {cy:.7f} {bw:.7f} {bh:.7f}")
    path.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")


def preview_tile(image, boxes: list[Box], title: str, size: tuple[int, int] = (320, 240)):
    canvas = image.copy()
    for box in boxes:
        colour = (0, 220, 0) if box.source == "ensemble" else (0, 170, 255)
        cv2.rectangle(canvas, (round(box.x1), round(box.y1)),
                      (round(box.x2), round(box.y2)), colour, 4)
        cv2.putText(canvas, f"{box.source}:{box.score:.2f}",
                    (round(box.x1), max(25, round(box.y1) - 8)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.7, colour, 2, cv2.LINE_AA)
    canvas = cv2.resize(canvas, size, interpolation=cv2.INTER_AREA)
    cv2.putText(canvas, title[:42], (6, 22), cv2.FONT_HERSHEY_SIMPLEX,
                0.48, (255, 255, 255), 2, cv2.LINE_AA)
    cv2.putText(canvas, title[:42], (6, 22), cv2.FONT_HERSHEY_SIMPLEX,
                0.48, (0, 0, 0), 1, cv2.LINE_AA)
    return canvas


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--existing-model", type=Path, required=True)
    parser.add_argument("--yoloe-model", type=Path, required=True)
    parser.add_argument("--user-images", type=Path, required=True)
    parser.add_argument("--video-frames", type=Path, required=True)
    parser.add_argument("--commons-images", type=Path, required=True)
    parser.add_argument("--negative-images", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--device", default="0")
    parser.add_argument("--imgsz", type=int, default=640)
    args = parser.parse_args()

    output = args.output.resolve()
    review = output / "review"
    review.mkdir(parents=True, exist_ok=True)
    old_model = YOLO(str(args.existing_model))
    prompt_model = YOLOE(str(args.yoloe_model))
    prompt_model.set_classes(ALL_PROMPTS)

    sources: list[tuple[Path, str]] = []
    for root, source_type in (
        (args.user_images, "user"),
        (args.video_frames, "video"),
        (args.commons_images, "commons"),
    ):
        sources.extend((path, source_type) for path in sorted(root.rglob("*"))
                       if path.suffix.lower() in IMAGE_SUFFIXES)

    logs = []
    tiles = []
    accepted = 0
    for index, (path, source_type) in enumerate(sources, 1):
        if excluded_source(path, source_type):
            continue
        image = cv2.imread(str(path))
        if image is None:
            continue
        height, width = image.shape[:2]
        old_result = old_model.predict(
            image, imgsz=args.imgsz, conf=0.05, iou=0.45,
            device=args.device, verbose=False,
        )[0]
        prompted_result = prompt_model.predict(
            image, imgsz=args.imgsz, conf=0.035, iou=0.40,
            device=args.device, verbose=False, agnostic_nms=True,
        )[0]
        existing = [item for item in
                    (clean(box, width, height) for box in
                     result_boxes(old_result, "closed", 0.055)) if item]
        prompted = [item for item in
                    (clean(box, width, height) for box in
                     result_boxes(
                         prompted_result, "open", 0.035,
                         set(range(len(ROCKET_PROMPTS))),
                     )) if item]
        negative_prompts = [item for item in
                            (clean(box, width, height) for box in
                             result_boxes(
                                 prompted_result, "negative", 0.035,
                                 SUPPRESSION_CLASSES,
                             )) if item]
        existing = suppress_competing_prompts(existing, negative_prompts)
        prompted = suppress_competing_prompts(prompted, negative_prompts)
        labels, decision = choose_labels(
            existing, prompted, commons=source_type == "commons",
            known_positive=known_positive(path),
            video=source_type == "video",
        )
        if labels:
            split = split_for(path)
            digest = hashlib.sha1(str(path).encode("utf-8")).hexdigest()[:12]
            name = f"{source_type}_{digest}{path.suffix.lower()}"
            image_destination = output / "images" / split / name
            label_destination = output / "labels" / split / f"{Path(name).stem}.txt"
            image_destination.parent.mkdir(parents=True, exist_ok=True)
            label_destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, image_destination)
            write_label(label_destination, labels, width, height)
            accepted += 1
            tiles.append(preview_tile(image, labels, path.name))
        logs.append({
            "path": str(path), "source": source_type, "decision": decision,
            "closed": [box.__dict__ for box in existing],
            "open": [box.__dict__ for box in prompted],
            "negative_prompts": [box.__dict__ for box in negative_prompts],
            "labels": [box.__dict__ for box in labels],
        })
        if index % 25 == 0:
            print(f"{index}/{len(sources)} accepted={accepted}", flush=True)

    # Safe negatives: COCO128 has ordinary objects but no water rockets. Empty
    # label files teach the detector not to call a bottle/person/appliance a
    # rocket. Keep every negative in train to preserve clean evaluation sets.
    negative_count = 0
    for path in sorted(args.negative_images.rglob("*")):
        if path.suffix.lower() not in IMAGE_SUFFIXES:
            continue
        digest = hashlib.sha1(str(path).encode("utf-8")).hexdigest()[:12]
        name = f"negative_{digest}{path.suffix.lower()}"
        destination = output / "images" / "train" / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, destination)
        label = output / "labels" / "train" / f"{Path(name).stem}.txt"
        label.parent.mkdir(parents=True, exist_ok=True)
        label.write_text("", encoding="utf-8")
        negative_count += 1

    for start in range(0, len(tiles), 20):
        page_tiles = tiles[start:start + 20]
        blank = page_tiles[0] * 0
        while len(page_tiles) < 20:
            page_tiles.append(blank)
        rows = [cv2.hconcat(page_tiles[row:row + 4]) for row in range(0, 20, 4)]
        sheet = cv2.vconcat(rows)
        cv2.imwrite(str(review / f"labels_{start // 20:03d}.jpg"), sheet,
                    [cv2.IMWRITE_JPEG_QUALITY, 88])

    with (output / "decisions.jsonl").open("w", encoding="utf-8") as handle:
        for row in logs:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    print(f"DONE accepted={accepted} negatives={negative_count} output={output}")


if __name__ == "__main__":
    main()

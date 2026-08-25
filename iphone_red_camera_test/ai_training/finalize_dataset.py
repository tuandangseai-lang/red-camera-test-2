"""Repartition a reviewed pseudo-labelled dataset without temporal leakage.

The source-level split keeps adjacent video frames together.  Day launch
footage is validation, independent Wikimedia images are test, and the night,
beach and user-selected flight sequences are training material.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from pathlib import Path


def source_split(row: dict) -> str:
    path = Path(row["path"])
    if row["source"] == "commons":
        return "test"
    if path.stem.startswith("0605__2_"):
        return "val"
    return "train"


def find_by_stem(root: Path, stem: str, kind: str) -> Path:
    matches = list((root / kind).glob(f"*/{stem}.*"))
    if len(matches) != 1:
        raise RuntimeError(f"Expected one {kind} file for {stem}, got {matches}")
    return matches[0]


def copy_pair(source: Path, destination: Path, image: Path, label: Path) -> None:
    image_target = destination / "images" / source.name / image.name
    label_target = destination / "labels" / source.name / label.name
    image_target.parent.mkdir(parents=True, exist_ok=True)
    label_target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(image, image_target)
    shutil.copy2(label, label_target)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    source = args.input.resolve()
    output = args.output.resolve()

    counts = {"train": 0, "val": 0, "test": 0}
    with (source / "decisions.jsonl").open(encoding="utf-8") as handle:
        for line in handle:
            row = json.loads(line)
            if not row.get("labels"):
                continue
            digest = hashlib.sha1(row["path"].encode("utf-8")).hexdigest()[:12]
            stem = f"{row['source']}_{digest}"
            image = find_by_stem(source, stem, "images")
            label = find_by_stem(source, stem, "labels")
            split = source_split(row)
            copy_pair(Path(split), output, image, label)
            counts[split] += 1

    negatives = sorted((source / "images" / "train").glob("negative_*"))
    for index, image in enumerate(negatives):
        split = "train" if index % 10 < 8 else "val" if index % 10 == 8 else "test"
        label = source / "labels" / "train" / f"{image.stem}.txt"
        copy_pair(Path(split), output, image, label)
        counts[split] += 1

    print(" ".join(f"{name}={count}" for name, count in counts.items()))


if __name__ == "__main__":
    main()
